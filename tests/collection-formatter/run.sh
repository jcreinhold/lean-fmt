#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)
fixture=tests/collection-formatter/Collections.lean
lake setup-file "$fixture" >"$work/setup.json"

for width in 20 40 80 100; do
  "$application" __analyze-exact "$work/setup.json" "$fixture" Collections.lean \
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
    assert text.index("| 0 => alpha") < text.index("| 1 => beta") < text.index("| _ => gamma"), text
    assert "custom{alpha}" in text, text
    assert text.index("def leftAssociative") < text.index("def rightAssociative"), text

narrow = texts[20]
for broken in (
    """  (
    alpha,
    beta,
    gamma,
    delta
  )""",
    """  [
    alpha,
    beta,
    gamma,
    delta,
    epsilon
  ]""",
    """  #[
    alpha,
    beta,
    gamma,
    delta,
    epsilon
  ]""",
    """  ⟨
    alpha,
    beta,
    gamma
  ⟩""",
):
    assert broken in narrow, narrow
assert "    gamma,\n  ]" in narrow, "trailing list separator was lost"
assert """  { first := alpha,
    second := beta,
    third := gamma }""" in narrow, narrow
assert """  { packet with
    first := alpha,
    second := beta }""" in narrow, narrow
assert """  { first := alpha
    second := beta
    third := gamma }""" in narrow, narrow
assert "alpha + beta +\n    gamma +\n    delta" in narrow, narrow
assert "alpha ^\n    beta ^\n      gamma" in narrow, narrow
assert "Nat →\n    Nat →\n      Nat" in narrow, narrow
assert "[\n    custom{alpha}," in narrow, narrow

wide = texts[80]
for flat in (
    "(alpha, beta, gamma, delta)",
    "[alpha, beta, gamma, delta, epsilon]",
    "#[alpha, beta, gamma, delta, epsilon]",
    "⟨alpha, beta, gamma⟩",
    "{ first := alpha, second := beta, third := gamma }",
    "{ first, second, third }",
    "{ first := alpha, second := beta, third := gamma : Packet }",
    "{ first := alpha, second := 0, third := 0, .. }",
    "{ packet with first := alpha, second := beta }",
):
    assert flat in wide, (flat, wide)
assert texts[20] != texts[40] != texts[80], "collection groups ignored configured width"
print("  ok   tuples, lists, arrays, and trailing separators use structural flat/broken documents")
print("  ok   comma-bearing, update, and layout-separated records preserve their parser contracts")
print("  ok   actual operator association controls left-, right-, and arrow-chain reflow")
print("  ok   project-defined entries remain opaque while their collection ancestor reflows")
PY

printf 'tests/collection-formatter: ok\n'
