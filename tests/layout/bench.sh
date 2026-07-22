#!/usr/bin/env bash
set -euo pipefail

# Machine-independent renderer complexity check. Wall time is deliberately absent: the contract is
# the work performed, not how busy the machine was while performing it.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt-tests
tests=$(lake -q query lean-fmt-tests --text)

output=$("$tests" doc-step-counts)
printf '%s\n' "$output"

# shellcheck source=tests/performance/gates.sh
source "$repo_root/tests/performance/gates.sh"
scratch=$(mktemp)
trap 'rm -f "$scratch"' EXIT
printf '%s\n' "$output" >"$scratch"

if gate_doc_steps_linear "$scratch"; then
  printf 'tests/layout bench: ok (steps = nodes + marks in all 8 rows)\n'
else
  printf 'tests/layout bench: FAIL renderer work is nonlinear or the report is incomplete\n' >&2
  exit 1
fi
