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
import re
import sys

root = pathlib.Path(sys.argv[1])
texts = {}
for width in (20, 40, 80, 100):
    report = json.loads((root / f"{width}.json").read_text())
    assert report.get("validationFailure") is None and report.get("canonical") is not None, report
    canonical = report["canonical"]
    assert canonical["validation"]["idempotencePasses"] == 1, canonical
    metrics = canonical["metrics"]
    assert metrics["nativeDocuments"] == metrics["commands"], metrics
    assert metrics["alignedTokens"] > metrics["commands"], metrics
    assert metrics["offsideConstraints"] >= 1, metrics
    text = canonical["text"]
    texts[width] = text
    arms = [re.search(pattern, text).start() for pattern in
            (r"\|\s*0\s*=>\s*alpha", r"\|\s*1\s*=>\s*beta", r"\|\s*_\s*=>\s*gamma")]
    assert arms == sorted(arms), text
    assert "custom{alpha}" in text, text
    left = re.search(r"def\s+leftAssociative", text).start()
    right = re.search(r"def\s+rightAssociative", text).start()
    assert left < right, text

narrow = texts[20]
for broken in (
    r"\(alpha,\s*beta,\s*\n\s*gamma,\s*delta\)",
    r"\[alpha,\s*beta,\s*\n\s*gamma,\s*delta,\s*\n\s*epsilon\]",
    r"#\[alpha,\s*beta,\s*\n\s*gamma,\s*delta,\s*\n\s*epsilon\]",
    r"⟨alpha,\s*beta,\s*\n\s*gamma⟩",
):
    assert re.search(broken, narrow), (broken, narrow)
assert re.search(r"gamma,\s*\]", narrow), "trailing list separator was lost"
assert re.search(
    r"\{\s*first\s*:=\s*alpha,\s*second\s*:=\s*beta,\s*third\s*:=\s*gamma\s*\}",
    narrow,
), narrow
assert re.search(
    r"\{\s*packet\s+with\s*\n\s*first\s*:=\s*alpha,\s*second\s*:=\s*beta\s*\}",
    narrow,
), narrow
assert re.search(r"\{\s*first\s*:=\s*alpha\s+second\s*:=\s*beta\s+third\s*:=\s*gamma\s*\}",
                 narrow), narrow
assert re.search(r"alpha\s*\+\s*beta\s*\+\s*gamma\s*\+\s*delta", narrow), narrow
assert re.search(r"alpha\s*\^\s*beta\s*\^\s*gamma", narrow), narrow
assert re.search(r"Nat\s*→\s*Nat\s*→\s*Nat", narrow), narrow
assert re.search(r"\[\s*custom\{alpha\},", narrow), narrow

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
):
    assert flat in wide, (flat, wide)
assert re.search(r"\{\s*packet\s+with\s*\n\s*first\s*:=\s*alpha,\s*second\s*:=\s*beta\s*\}",
                 wide), wide
assert texts[20] != texts[40] != texts[80], "collection groups ignored configured width"
print("  ok   tuples, lists, arrays, and trailing separators use native flat/broken documents")
print("  ok   comma-bearing, update, and layout-separated records preserve their parser contracts")
print("  ok   actual operator association controls left-, right-, and arrow-chain reflow")
print("  ok   project-defined entries remain opaque while their collection ancestor reflows")
PY

printf 'tests/collection-formatter: ok\n'
