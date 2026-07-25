#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests
application=$(lake -q query lean-fmt --text)
tests=$(lake -q query lean-fmt-tests --text)
LEAN_NUM_THREADS=1 lake setup-file tests/check/Clean.lean >"$work/setup.json"

oracle=(lake env python3 tests/formatter/oracle.py --application "$application" --tests "$tests"
  --setup "$work/setup.json")
candidate=(python3 tests/formatter/candidate.py)

expect_failure() {
  local label=$1 fixture=$2 mode=$3 gate=$4
  set +e
  "${oracle[@]}" --source "tests/formatter/fixtures/$fixture" -- "${candidate[@]}" "$mode" \
    >"$work/$label.json" 2>"$work/$label.stderr"
  local actual=$?
  set -e
  if [[ $actual -ne 1 ]]; then
    printf 'FAIL %-24s expected rejection, exit=%s\n' "$label" "$actual" >&2
    cat "$work/$label.json" "$work/$label.stderr" >&2
    exit 1
  fi
  LABEL="$label" GATE="$gate" python3 - "$work/$label.json" <<'PY'
import json, os, sys
result = json.load(open(sys.argv[1]))
assert result["status"] == "failed", (os.environ["LABEL"], result)
assert result["gate"] == os.environ["GATE"], (os.environ["LABEL"], result)
PY
  printf 'ok   %-24s rejected by %s\n' "$label" "$gate"
}

printf -- '--- injected negative gates ---\n'
expect_failure dropped-block-comment Contract.lean drop-block-comment comments-payload
expect_failure moved-trailing-comment Contract.lean move-trailing-comment comments-ownership
expect_failure duplicated-doc-comment Contract.lean duplicate-doc-comment comments-payload
expect_failure term-reassociation TermParentage.lean term-reassociate structure
expect_failure tactic-reassociation TacticParentage.lean tactic-reassociate structure
expect_failure changed-import-order Contract.lean change-imports imports
expect_failure moved-terminal Contract.lean move-terminal terminal
expect_failure stale-artifact Contract.lean stale-artifact stale-artifact
expect_failure wrong-environment Contract.lean wrong-environment environment
expect_failure second-pass-drift Contract.lean second-pass-drift idempotence
expect_failure unsupported-kind Contract.lean unsupported unsupported
expect_failure cancelled-candidate Contract.lean cancelled cancellation
expect_failure overlapping-map Contract.lean overlap-map source-map

printf -- '--- identity baseline ---\n'
"${oracle[@]}" --source tests/formatter/fixtures/Contract.lean -- "${candidate[@]}" identity \
  >"$work/identity.json"
cat "$work/identity.json"
python3 - "$work/identity.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
assert result["status"] == "ok", result
assert result["changed"] == 0 and result["reflowedUnits"] == 0, result
assert result["nodes"] > 0 and result["tokens"] > 0 and result["comments"] == 3, result
assert result["digest"] == "de426c98ee255b1e5d3b4c030a1d0aa7bcf060a694e456ecc91db6a9556cbc09", result
PY

if [[ $# -gt 0 ]]; then
  printf -- '--- supplied candidate ---\n'
  "${oracle[@]}" --source tests/formatter/fixtures/Contract.lean -- "$@"
fi

printf 'lean-fmt frontend-native formatter contract passed\n'
