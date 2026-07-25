#!/usr/bin/env bash
# Run the whole gate corpus, one suite at a time, with per-suite timing.
#
# Sequential is deliberate, not a missing feature: `tests/modes` fails if a concurrent `lake build`
# changes `.lake` under it, the stream/watch suites are timing-sensitive, and the memory envelope's
# stop rule (8 GiB aggregate) assumes one measured workload at a time. Suites are independent — any
# subset can be named: `tests/run-all.sh check cache` runs only those two.
#
# Every suite's full output lands in a scratch directory the summary prints; the terminal carries
# one line per suite so a 30-minute sweep stays readable. `tests/ci` reads committed state — run it
# after committing, exactly as when it is invoked directly.
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root" || exit 1

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

if [ "$#" -gt 0 ]; then
  suites=("$@")
else
  suites=()
  for run in tests/*/run.sh; do
    suites+=("$(basename "$(dirname "$run")")")
  done
fi

failures=0
declare -a lines
for suite in "${suites[@]}"; do
  run="tests/$suite/run.sh"
  if [ ! -f "$run" ]; then
    printf 'unknown suite: %s (no %s)\n' "$suite" "$run" >&2
    failures=$((failures + 1))
    continue
  fi
  started=$(python3 -c 'import time; print(time.monotonic())')
  if bash "$run" >"$scratch/$suite.log" 2>&1; then
    verdict=PASS
  else
    verdict=FAIL
    failures=$((failures + 1))
  fi
  elapsed=$(python3 -c "import time; print(int(time.monotonic() - $started))")
  printf '%-28s %s  %4ds\n' "$suite" "$verdict" "$elapsed"
  lines+=("$(printf '%10d  %s' "$elapsed" "$suite")")
done

printf -- '\n--- slowest suites ---\n'
printf '%s\n' "${lines[@]}" | sort -rn | head -8 | awk '{printf "%7ds  %s\n", $1, $2}'
if [ "$failures" -gt 0 ]; then
  printf 'logs kept at %s\n' "$scratch" >&2
  printf '%d suite(s) failed\n' "$failures" >&2
  # Keep the logs when there is something to read in them.
  trap - EXIT
  exit 1
fi
printf 'all %d suites passed\n' "${#suites[@]}"
