#!/usr/bin/env bash
set -euo pipefail

# Production admission: a candidate is canonical only after a fresh frontend, structural comparison,
# logical-comment comparison, complete source maps, and a byte-identical second rendering.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests FormatterAdapterFixtures
application=$(lake -q query lean-fmt --text)
tests=$(lake -q query lean-fmt-tests --text)

cat >"$work/Accepted.lean" <<'LEAN'
module

import AdapterSyntax

open AdapterSyntax

-- custom lead
explicit_command selectedName -- custom trail
LEAN
LEAN_NUM_THREADS=1 lake setup-file "$work/Accepted.lean" >"$work/accepted-setup.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/accepted-setup.json" "$work/Accepted.lean" Accepted.lean 8589934592 4:80 \
  >"$work/accepted.json"
python3 - "$work/accepted.json" <<'PY'
import json, sys
envelope = json.load(open(sys.argv[1]))
assert not envelope["diagnostics"] and envelope.get("validationFailure") is None, envelope
assert envelope.get("formatDraft") is None, "unvalidated draft escaped validated operation"
canonical = envelope["canonical"]
assert canonical["metrics"]["frontendRuns"] == 2, canonical
assert canonical["validation"] == {
    "frontendRuns": 2, "renders": 2, "structuralComparisons": 1, "idempotencePasses": 1
}, canonical
source = output = 0
for mark in canonical["sourceMap"]:
    assert mark["source"]["start"] == source and mark["output"]["start"] == output, mark
    source, output = mark["source"]["stop"], mark["output"]["stop"]
assert output == len(canonical["text"].encode()), canonical
assert canonical["text"].count("custom lead") == canonical["text"].count("custom trail") == 1
print("  ok   core/custom/comment candidate admitted after exactly two frontend renders")
PY

validate_mutation() {
  local fixture=$1 mode=$2 expected=$3
  cp "tests/formatter/fixtures/$fixture" "$work/source.lean"
  LEAN_NUM_THREADS=1 lake setup-file "$work/source.lean" >"$work/setup.json"
  python3 tests/formatter/candidate.py "$mode" <"$work/source.lean" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["formatted"], end="")' \
      >"$work/candidate.lean"
  LEAN_NUM_THREADS=1 lake env "$application" __validate-candidate \
    "$work/setup.json" "$work/source.lean" "$work/candidate.lean" source.lean 8589934592 100 \
    >"$work/result.json"
  MODE=$mode EXPECTED=$expected python3 - "$work/result.json" <<'PY'
import json, os, sys
result = json.load(open(sys.argv[1]))
assert result.get("canonical") is None, (os.environ["MODE"], result)
failure = result["failure"]
assert failure["gate"] == os.environ["EXPECTED"], (os.environ["MODE"], failure)
PY
  printf '  ok   %-24s rejected by %s\n' "$mode" "$expected"
}

validate_mutation Contract.lean drop-block-comment comments
validate_mutation Contract.lean move-trailing-comment comments
validate_mutation Contract.lean duplicate-doc-comment structure
validate_mutation TermParentage.lean term-reassociate structure
validate_mutation TacticParentage.lean tactic-reassociate structure
validate_mutation Contract.lean change-imports header
validate_mutation Contract.lean move-terminal terminal
validate_mutation Contract.lean second-pass-drift idempotence

printf 'module\n\ndef broken :=\n' >"$work/candidate.lean"
cp tests/formatter/fixtures/Contract.lean "$work/source.lean"
LEAN_NUM_THREADS=1 lake setup-file "$work/source.lean" >"$work/setup.json"
LEAN_NUM_THREADS=1 lake env "$application" __validate-candidate \
  "$work/setup.json" "$work/source.lean" "$work/candidate.lean" source.lean 8589934592 100 \
  >"$work/diagnostics.json"
python3 - "$work/diagnostics.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["failure"]["gate"] == "diagnostics"
print("  ok   malformed candidate rejected by diagnostics")
PY

cat >"$work/Throwing.lean" <<'LEAN'
module

import AdapterSyntax

open AdapterSyntax

throwing_command
LEAN
LEAN_NUM_THREADS=1 lake setup-file "$work/Throwing.lean" >"$work/throwing-setup.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/throwing-setup.json" "$work/Throwing.lean" Throwing.lean 8589934592 4 \
  >"$work/throwing.json"
python3 - "$work/throwing.json" <<'PY'
import json, sys
envelope = json.load(open(sys.argv[1]))
assert envelope.get("canonical") is None
assert envelope["formatFailure"]["detail"] == "adapter fixture formatter failure"
print("  ok   formatter exception remains a typed refusal")
PY

"$tests" validator-map-negative | grep -q 'cases=4'
printf '  ok   incomplete, overlapping, inverted, and short output maps rejected by sourceMap\n'
printf 'tests/validator: ok\n'
