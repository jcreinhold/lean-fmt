#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)

analyze() {
  local fixture=$1 width=$2 output=$3
  LEAN_NUM_THREADS=1 lake setup-file "$fixture" >"$work/setup.json"
  "$application" __analyze-exact "$work/setup.json" "$fixture" "$(basename "$fixture")" \
    8589934592 "4:$width" >"$output"
}

for width in 24 60 100; do
  analyze tests/declaration-formatter/Families.lean "$width" "$work/families-$width.json"
done
analyze tests/declaration-formatter/Comments.lean 60 "$work/comments.json"

python3 - "$work" <<'PY'
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
texts = {}
for width in (24, 60, 100):
    report = json.loads((root / f"families-{width}.json").read_text())
    assert report.get("validationFailure") is None and report.get("canonical") is not None, report
    canonical = report["canonical"]
    assert canonical["validation"]["idempotencePasses"] == 1, canonical
    text = canonical["text"]
    texts[width] = text
    for required in (
        "abbrev VeryLongAliasName", "opaque opaqueValue", "axiom assumedValue",
        "@[inline] private def modifiedValue", "def «name with spaces»",
        "instance", "structure Packet", "class HasValue", "inductive Choice",
        "mutual", "def isEven", "def isOdd", "def withLocal", "where",
    ):
        assert required in text, (width, required, text)
    assert text.index("first : α") < text.index("second : α") < text.index("count : Nat"), text
    assert text.index("| neither") < text.index("| left") < text.index("| right"), text
    assert text.index("def isEven") < text.index("def isOdd"), text

narrow = texts[24]
assert "  opaque opaqueValue\n    (first second : Nat) :\n    Nat :=\n    first + second" in narrow, narrow
assert texts[24] != texts[100], "declaration groups ignored width"

report = json.loads((root / "comments.json").read_text())
assert report.get("validationFailure") is None and report.get("canonical") is not None, report
text = report["canonical"]["text"]
for payload in (
    "/-- The declaration payload is exact. -/",
    "-- trailing body payload",
    "/-- The field payload is exact. -/",
):
    assert text.count(payload) == 1, (payload, text)
print("  ok   shared declaration headers use two-space hanging groups at widths 24/60/100")
print("  ok   members, constructors, deriving, mutual, where, comments, and custom terms preserve order")
PY

printf 'tests/declaration-formatter: ok\n'
