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
    assert canonical["metrics"]["coreRegistryDocuments"] == 0, canonical["metrics"]
    assert canonical["metrics"]["registryDocuments"] == 0, canonical["metrics"]
    assert canonical["metrics"]["structuralDocuments"] > 0, canonical["metrics"]
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
        "let some value := input",
        "let some value ← input",
        "long guarded let",
        "long guarded bind",
        "total ←",
        "have positive",
        "for value in values do",
        "continue",
        "break",
        "while total <",
        "let rec count",
        "else if value.isNone then",
        "unless flag do",
        "repeat",
        "until flag",
        "let value ←",
        "{\n",
        "1;",
        "try",
        "catch _ =>",
        "catch\n",
        "finally",
        "dbg_trace",
        "assert!",
        "debug_assert!",
        "Id.run",
        "where",
    ):
        assert required in text, (width, required, text)
    assert text.count("/- between focused goals -/") == 1, text
    assert text.count("/- match-arm comment -/") == 1, text
    assert text.count("/- long guarded let -/") == 1, text
    assert text.count("/- long guarded bind -/") == 1, text
    assert text.index("let first") < text.index("let second") < text.index("pure second"), text

narrow = texts[20]
assert "by\n    constructor\n    ·" in narrow, narrow
assert "first\n    | exact proof\n    | assumption" in narrow, narrow
assert "do\n    let first ←" in narrow, narrow
assert "Id.run\n    do" in narrow, narrow
assert "do\n    {" in narrow, narrow
assert narrow.index("| 0 =>") < narrow.index("| _ =>"), narrow
assert texts[20] != texts[40] != texts[80], "block registry ignored configured width"
print("  ok   tactic, do, control, match, and where roots compose structurally at four widths")
print("  ok   binds, fallback arms, loops, try/catch/finally, bracketed blocks, and comments survive")
print("  ok   both frontend renders are idempotent with zero core registry command ancestors")
PY

printf 'tests/block-formatter: ok\n'
