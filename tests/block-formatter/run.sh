#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)
fixture=tests/block-formatter/Blocks.lean
lake setup-file "$fixture" >"$work/setup.json"

for width in 20 40 80 100; do
  "$application" __analyze-exact "$work/setup.json" "$fixture" Blocks.lean \
    8589934592 "4:$width" >"$work/$width.json"
done

python3 - "$work" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
texts = {}
for width in (20, 40, 80, 100):
    report = json.loads((root / f"{width}.json").read_text())
    assert report.get("validationFailure") is None and report.get("canonical") is not None, report
    canonical = report["canonical"]
    assert canonical["validation"]["idempotencePasses"] == 1, canonical
    text = canonical["text"]
    texts[width] = text
    for required in (
        "exact proof",
        "constructor",
        "first",
        "| exact proof",
        "constructor <;>",
        "custom_assumption",
        "match value with",
        "Id.run do",
        "where",
    ):
        assert required in text, (width, required, text)
    assert text.count("/- between focused goals -/") == 1, text
    assert text.index("let first") < text.index("let second") < text.index("pure second"), text

narrow = texts[20]
assert "by\n      constructor\n      ·" in narrow, narrow
assert "first\n      | exact proof\n      | assumption" in narrow, narrow
assert "do\n    let first ←" in narrow, narrow
assert narrow.index("| 0 =>") < narrow.index("| _ =>"), narrow
assert texts[20] != texts[40] != texts[80], "block registry ignored configured width"
print("  ok   closed by roots compose actual tactic sequence documents at four widths")
print("  ok   focus, alternatives, combinators, match arms, and item order survive")
print("  ok   only project tactic leaves remain registry-owned; do/where await integration")
PY

printf 'tests/block-formatter: ok\n'
