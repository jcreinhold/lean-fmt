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

for width in 32 60 100; do
  analyze tests/command-formatter/CoreInput.lean "$width" "$work/core-$width.json"
done
analyze tests/command-formatter/Comments.lean 60 "$work/comments.json"
LEAN_NUM_THREADS=1 lake setup-file LeanFmt/Formatter/Command.lean >"$work/self-setup.json"
"$application" __analyze-exact "$work/self-setup.json" LeanFmt/Formatter/Command.lean \
  LeanFmt/Formatter/Command.lean 8589934592 draft:100 >"$work/self.json"

python3 - "$work" <<'PY'
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
texts = {}
for width in (32, 60, 100):
    report = json.loads((root / f"core-{width}.json").read_text())
    assert report.get("validationFailure") is None and report.get("canonical") is not None, report
    canonical = report["canonical"]
    text = canonical["text"]
    texts[width] = text
    assert canonical["validation"] == {
        "frontendRuns": 2, "renders": 2, "structuralComparisons": 1, "idempotencePasses": 1
    }, canonical
    metrics = canonical["metrics"]
    assert metrics["commands"] >= 20 and metrics["nativeDocuments"] == metrics["commands"], metrics
    assert metrics["alignedTokens"] > metrics["commands"], metrics
    assert metrics["descriptorDocuments"] == 1, metrics
    assert text.startswith("module\nimport Lean\n\nnamespace CommandFixture\n"), text
    if width == 32:
        assert "\nuniverse u v\nvariable {α : Type u}\n  (value : α)" in text, text
    else:
        assert "\nuniverse u v\nvariable {α : Type u} (value : α)" in text, text
    assert "\nmacro_rules\n  | `(identity! $term)" in text and "`($term)\n" in text, text
    assert "\nemit_custom generated\n" in text, text
    assert text.endswith("\nend CommandFixture\n"), text
    assert all(not line.endswith((" ", "\t")) for line in text.splitlines()), text

assert texts[32] != texts[100], "width did not affect a breakable nested command"

report = json.loads((root / "comments.json").read_text())
assert report.get("validationFailure") is None and report.get("canonical") is not None, report
text = report["canonical"]["text"]
for payload in (
    "-- trailing setup comment",
    "/-- A declaration doc comment remains before its owner. -/",
):
    assert text.count(payload) == 1, (payload, text)
assert "\nuniverse u\nvariable {α : Type u} -- trailing setup comment\n" in text, text
print("  ok   parsed headers, command boundaries, comments, and custom commands use native layout")
print("  ok   widths 32/60/100 are admitted and byte-idempotent with a descriptor command")
PY

python3 - "$work/self.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
assert report.get("formatFailure") is None and report.get("formatDraft") is not None, report
metrics = report["formatDraft"]["metrics"]
# The floor was 20 while `Formatter/Command.lean` still held the handwritten command grammar. Deleting
# that grammar left the module at exactly 20 commands, so the floor moves down rather than pinning the
# module's current size; what the check is for is that every command in a real commented module is a
# native document, not that this module has a particular length.
assert metrics["commands"] >= 15 and metrics["nativeDocuments"] == metrics["commands"], metrics
assert metrics["alignedTokens"] > metrics["commands"], metrics
print("  ok   lean-fmt's commented command module aligns every command through native layout")
PY

printf 'tests/command-formatter: ok\n'
