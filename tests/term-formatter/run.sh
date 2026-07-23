#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)
fixture=tests/term-formatter/Terms.lean
lake setup-file "$fixture" >"$work/setup.json"

for width in 20 40 80 100; do
  "$application" __analyze-exact "$work/setup.json" "$fixture" Terms.lean \
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
    assert canonical["validation"] == {
        "frontendRuns": 2,
        "renders": 2,
        "structuralComparisons": 1,
        "idempotencePasses": 1,
    }, canonical
    text = canonical["text"]
    texts[width] = text
    for spelling in (
        "alpha + beta",
        "Nat.succ value",
        "pair.1 + pair.2",
        "⊕custom",
        "(value : Nat)",
        "@Nat.succ",
    ):
        assert spelling in text, (width, spelling, text)

application_break = """  consumeFive
    alpha
    beta
    gamma
    delta
    epsilon"""
assert application_break in texts[20], texts[20]
assert application_break in texts[40], texts[40]
assert "consumeFive alpha beta gamma delta epsilon" in texts[80], texts[80]
assert """consumeFive
    (
      alpha ⊕custom
        beta
    )""" in texts[20], texts[20]
assert "fun (first : Nat) (second : Nat) =>" in texts[80], texts[80]
assert "@Nat.succ value" in texts[100], texts[100]
for flat in (
    "alpha + beta * gamma + delta",
    "(f := fun value => value + 1)",
    "`(alpha + beta * gamma)",
):
    assert flat in texts[80], (flat, texts[80])

conditional_break = """  if condition then
    yes
  else
    no"""
assert conditional_break in texts[20], texts[20]
assert "if condition then yes else no" in texts[40], texts[40]
assert "else if second then" in texts[80], texts[80]
assert "let (actual, _) := value" in texts[80], texts[80]
assert "match _h : first, second with" in texts[80], texts[80]
assert texts[20].index("| 0, _ => alpha") < texts[20].index("| _, 1 => beta"), texts[20]
assert "fun first second => first + second" in texts[40], texts[40]
assert "let first := alpha + beta\n  let second := first * gamma" in texts[40], texts[40]

assert texts[20] != texts[40] != texts[80], "term groups ignored configured width"
print("  ok   applications and structural control terms reflow at widths 20/40/80/100")
print("  ok   let continuations, nested conditionals, match discriminants, and arm order survive")
print("  ok   project notation stays registry-driven only at its actual syntax node")
PY

printf 'tests/term-formatter: ok\n'
