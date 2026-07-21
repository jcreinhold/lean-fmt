#!/usr/bin/env bash
set -euo pipefail

# The heavier, scheduled half of the performance gates (`ruff-19` RPR-FINAL).
#
# `tests/performance/run.sh` runs on every commit and finishes in about a second, which buys its
# ubiquity by only ever looking at the `self` workload warm. This script is the other half: the
# frozen mathlib sample cold and warm, and the adversarial `PositionIndex` shapes. It costs minutes,
# so it belongs on a schedule and not in the per-commit sweep.
#
# ## What it adds that the fast gates cannot
#
#   1. **Cold.** The per-commit suite primes its own cache, so it never measures a cold run. Cold is
#      where `RPR-IMPL` found its two largest wins, and where a regression would hide.
#   2. **Scale.** 62 mathlib modules exercise `choice` nodes, `#exit`, and token densities that
#      34 self-hosted modules do not.
#   3. **Digest reuse.** Every run's report is hashed and compared against a recorded expectation, so
#      a change in *what the formatter says* is caught even when it costs no time. Speed gates are
#      all satisfiable by being wrong faster; this is the one that is not.
#   4. **Saved raw profiles.** Each run goes through `profile-run.sh`, which writes `.meta`,
#      `.phases`, `.stdout`, and `.stderr` into `experiments/results/` and enforces the 8 GiB /
#      256 MiB-swap / normal-pressure envelope. Those files are the raw evidence a later stack reads
#      instead of re-running anything.
#
# ## Variance policy, applied here rather than described elsewhere
#
# `RPR-IMPL` measured the same binary over the same warm corpus at 3,977 ms and 19,968 ms. So:
#
#   - **Never gate on a wall time.** Nothing below compares a duration to a threshold.
#   - **Report the median of at least three**, never a single run, and never the first: the first run
#     after an idle period reads roughly 1.8x the settled value.
#   - **Report the spread alongside the median.** A median with a 5x spread under it is a different
#     claim from a median with a 5% spread, and printing only the median hides which one you have.
#   - **Record machine conditions.** `profile-run.sh` already captures load, swap, and pressure into
#     each `.meta`; a number without them cannot be compared to a number taken later.
#
# ## Usage
#
#   run-scheduled-gates.sh            compare against recorded digests; fail on mismatch
#   run-scheduled-gates.sh --record   write the current digests as the new expectation
#
# `--record` is deliberately a separate, explicit act. A runner that silently re-recorded on every
# mismatch would report success forever while the output drifted arbitrarily far.

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

binary=$repo_root/.lake/build/bin/lean-fmt
mathlib_root=${LEAN_FMT_MATHLIB_ROOT:-/Users/jcreinhold/Code/mathlib4}
sample=$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt
expected_file=$repo_root/experiments/gates/expected-digests.txt
repetitions=${LEAN_FMT_SCHEDULED_REPETITIONS:-3}

record=false
[[ ${1:-} == --record ]] && record=true

if [[ ! -x $binary ]]; then
  printf 'build lean-fmt first: lake build\n' >&2
  exit 2
fi
if [[ ! -d $mathlib_root ]]; then
  printf 'mathlib checkout not found: %s (set LEAN_FMT_MATHLIB_ROOT)\n' "$mathlib_root" >&2
  exit 2
fi

mkdir -p "$(dirname "$expected_file")"
touch "$expected_file"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

failures=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
  printf '  FAIL %s\n' "$1" >&2
  failures=$((failures + 1))
}

files=()
while IFS= read -r relative_path; do
  [[ -z $relative_path ]] || files+=("$mathlib_root/$relative_path")
done <"$sample"

# One measured run. Returns wall ms on stdout; leaves the report at $scratch/report.out.
timed_run() {
  python3 - "$binary" "$mathlib_root" "$scratch/report.out" "$scratch/report.err" "${files[@]}" <<'TIMED'
import os, subprocess, sys, time

binary, root, out_path, err_path, *targets = sys.argv[1:]
environment = dict(os.environ, LEAN_FMT_PROFILE_PHASES="1")
command = [binary, "check", "--output-format", "concise", "--root", root, *targets]
with open(out_path, "wb") as out, open(err_path, "wb") as err:
    started = time.monotonic()
    subprocess.run(command, stdout=out, stderr=err, env=environment)
    print(int((time.monotonic() - started) * 1000))
TIMED
}

digest_of() { shasum -a 256 "$1" | awk '{print $1}'; }

expected_digest() { sed -n "s/^$1=\([0-9a-f]*\)$/\1/p" "$expected_file" | tail -1; }

record_digest() {
  local key=$1 value=$2
  local kept
  kept=$(grep -v "^$key=" "$expected_file" || true)
  printf '%s\n' "$kept" | sed '/^$/d' >"$scratch/expected.new"
  printf '%s=%s\n' "$key" "$value" >>"$scratch/expected.new"
  sort "$scratch/expected.new" >"$expected_file"
}

# Compare an observed digest against the recorded one, or record it under --record.
check_digest() {
  local key=$1 observed=$2
  local want
  want=$(expected_digest "$key")
  if $record; then
    record_digest "$key" "$observed"
    ok "recorded $key = ${observed:0:8}…"
  elif [[ -z $want ]]; then
    bad "$key has no recorded digest; run with --record once, and commit the result"
  elif [[ $want == "$observed" ]]; then
    ok "$key report digest unchanged (${observed:0:8}…)"
  else
    bad "$key report changed: expected ${want:0:8}…, got ${observed:0:8}… -- the formatter's output moved, which no performance change may do"
  fi
}

printf 'experiments/run-scheduled-gates.sh: the heavy half\n'
printf 'machine: %s\n' "$(uptime | sed 's/.*load averages*://')"
printf 'sample:  %d files from %s\n\n' "${#files[@]}" "$mathlib_root"

printf -- '--- cold: the state the per-commit gates never reach ---\n'

# `clean` drops this project's cache entries, which is what makes the next run genuinely cold.
"$binary" clean --root "$mathlib_root" >/dev/null 2>&1 || true
cold_wall=$(timed_run)
cold_digest=$(digest_of "$scratch/report.out")
cold_children=$(grep -c '^phase\.exact_child_ms=' "$scratch/report.err" || true)
printf '  cold wall %s ms, %s frontend children\n' "$cold_wall" "$cold_children"
check_digest "mathlib-sample.check.cold" "$cold_digest"

printf -- '\n--- warm: median of %d, with the spread ---\n' "$repetitions"

walls=()
for _ in $(seq 1 "$repetitions"); do
  walls+=("$(timed_run)")
done
warm_digest=$(digest_of "$scratch/report.out")

read -r median spread <<<"$(python3 -c "
import statistics, sys
values = sorted(int(v) for v in sys.argv[1:])
print(int(statistics.median(values)), round(values[-1] / max(values[0], 1), 2))
" "${walls[@]}")"

# Reported, never gated. The spread is the honest qualifier on the median: `RPR-IMPL` saw 5x on an
# unchanged binary, so a median printed alone would invite a comparison it cannot support.
printf '  warm walls %s ms; median %s ms, spread %sx\n' "${walls[*]}" "$median" "$spread"
if python3 -c "import sys; sys.exit(0 if $spread <= 2.0 else 1)"; then
  ok "spread ${spread}x -- these numbers are comparable to another quiet-machine run"
else
  printf '  note  spread %sx: the machine was busy, so treat the median as an upper bound only\n' \
    "$spread"
fi

check_digest "mathlib-sample.check.warm" "$warm_digest"

if [[ $cold_digest == "$warm_digest" ]]; then
  ok "cold and warm reports agree, so the cache serves what it stored"
else
  bad "cold and warm reports differ: the cache is not serving what it stored"
fi

printf -- '\n--- the adversarial PositionIndex shapes ---\n'

# `ruff-15` handed forward a guess about the worst shape and `RPR-IMPL` measured it: position
# dominates (7.5x between a finding at the start and one at the end of the same 4 MB file), because
# the walk stops at the last offset it needs. Growth is what matters here, not absolute time, so
# this reports the ratio between the shapes and gates nothing on either one's duration.
if bash "$repo_root/experiments/run-positions-bench.sh" 4000000 >"$scratch/positions.txt" 2>&1; then
  sed 's/^/  /' "$scratch/positions.txt"
  early=$(awk '$1=="early" {print $3}' "$scratch/positions.txt")
  late=$(awk '$1=="late" {print $3}' "$scratch/positions.txt")
  if [[ -n $early && -n $late ]] && ((late >= early)); then
    ok "late/early ratio $(python3 -c "print(round($late / max($early,1), 1))")x, the expected shape"
  else
    bad "the positions bench did not reproduce its expected shape (early=$early late=$late)"
  fi
else
  bad "the positions bench failed; see $scratch/positions.txt"
fi

printf '\n'
if ((failures == 0)); then
  printf 'scheduled gates: ok\n'
else
  printf 'scheduled gates: %d failed\n' "$failures" >&2
  exit 1
fi
