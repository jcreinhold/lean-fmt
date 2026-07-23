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

for width in 20 40 80 100; do
  analyze tests/declaration-formatter/Families.lean "$width" "$work/families-$width.json"
done
analyze tests/declaration-formatter/Comments.lean 60 "$work/comments.json"

python3 - "$work" <<'PY'
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
texts = {}
for width in (20, 40, 80, 100):
    report = json.loads((root / f"families-{width}.json").read_text())
    assert report.get("validationFailure") is None and report.get("canonical") is not None, report
    canonical = report["canonical"]
    assert canonical["validation"]["idempotencePasses"] == 1, canonical
    metrics = canonical["metrics"]
    assert metrics["coreRegistryDocuments"] == 0, metrics
    assert metrics["structuralDocuments"] == metrics["coreDocuments"], metrics
    text = canonical["text"]
    texts[width] = text
    for required in (
        "abbrev VeryLongAliasName", "opaque opaqueValue", "axiom assumedValue",
        "@[inline] private def modifiedValue", "def «name with spaces»",
        "instance", "structure Packet", "structure ExtendedPacket", "class HasValue",
        "class ExtendedHasValue", "inductive Choice", "coinductive Always",
        "class inductive Classified",
        "mutual", "def isEven", "def isOdd", "def countdown", "termination_by",
        "def withLocal", "where",
    ):
        assert required in text, (width, required, text)
    assert text.index("first : α") < text.index("second : α") < text.index("count : Nat"), text
    assert text.index("| neither") < text.index("| left") < text.index("| right"), text
    assert text.index("def isEven") < text.index("def isOdd"), text
    assert "def isEven" in text and "\n\n    def isOdd" in text, text
    assert all(not line.endswith((" ", "\t")) for line in text.splitlines()), text

narrow = texts[20]
assert "  opaque opaqueValue\n    (first second : Nat) :\n    Nat :=\n    first + second" in narrow, narrow
assert "structure ExtendedPacket\n    (α : Type u)" in narrow, narrow
assert "structure ExtendedPacket (α : Type u) extends Packet α where" in texts[100], texts[100]
assert texts[20] != texts[100], "declaration groups ignored width"

report = json.loads((root / "comments.json").read_text())
assert report.get("validationFailure") is None and report.get("canonical") is not None, report
text = report["canonical"]["text"]
for payload in (
    "/-- The declaration payload is exact. -/",
    "-- trailing body payload",
    "/-- The field payload is exact. -/",
):
    assert text.count(payload) == 1, (payload, text)
print("  ok   declaration families use structural groups at widths 20/40/80/100")
print("  ok   members, constructors, deriving, mutual, where, comments, and custom terms preserve order")
PY

printf 'tests/declaration-formatter: ok\n'
