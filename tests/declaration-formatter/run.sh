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
import json, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
texts = {}
for width in (20, 40, 80, 100):
    report = json.loads((root / f"families-{width}.json").read_text())
    assert report.get("validationFailure") is None and report.get("canonical") is not None, report
    canonical = report["canonical"]
    assert canonical["validation"]["idempotencePasses"] == 1, canonical
    metrics = canonical["metrics"]
    assert metrics["nativeDocuments"] == metrics["commands"], metrics
    assert metrics["alignedTokens"] > metrics["commands"], metrics
    text = canonical["text"]
    texts[width] = text
    for required in (
        r"abbrev\s+VeryLongAliasName", r"opaque\s+opaqueValue", r"axiom\s+assumedValue",
        r"@\[inline\]\s+private\s+def\s+modifiedValue", r"«name with spaces»",
        r"\binstance\b", r"structure\s+Packet", r"structure\s+ExtendedPacket",
        r"class\s+HasValue", r"class\s+ExtendedHasValue", r"inductive\s+Choice",
        r"coinductive\s+Always", r"class\s+inductive\s+Classified",
        r"\bmutual\b", r"def\s+isEven", r"def\s+isOdd", r"def\s+countdown",
        r"termination_by", r"def\s+withLocal", r"\bwhere\b",
    ):
        assert re.search(required, text), (width, required, text)
    assert text.index("first : α") < text.index("second : α") < text.index("count : Nat"), text
    constructors = [re.search(pattern, text).start() for pattern in
                    (r"\|\s+neither", r"\|\s+left", r"\|\s+right")]
    assert constructors == sorted(constructors), text
    is_even = re.search(r"def\s+isEven", text).start()
    is_odd = re.search(r"def\s+isOdd", text).start()
    assert is_even < is_odd, text
    assert all(not line.endswith((" ", "\t")) for line in text.splitlines()), text

narrow = texts[20]
assert re.search(r"opaque\s+opaqueValue\s+\(first\s+second\s*:\s*Nat\)", narrow), narrow
assert re.search(r"structure\s+ExtendedPacket\s+\(α\s*:\s*Type\s+u\)", narrow), narrow
assert re.search(
    r"structure\s+ExtendedPacket\s+\(α\s*:\s*Type\s+u\)\s+extends\s+Packet\s+α\s+where",
    texts[100],
), texts[100]
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
