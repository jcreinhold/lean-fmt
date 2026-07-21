#!/usr/bin/env bash
set -euo pipefail

# Source-security scan cost, asserted rather than asserted-about (`RSR-FINAL`).
#
# The roadmap requires the source rules "remain linear in source size". `FMT003` is one pass over the
# byte array and `FMT004` one fold over the codepoints carrying a running offset, so each is O(n) by
# construction — but a note cannot notice a regression, and this can. `LeanFmtTest.lean`'s
# `security-bench` mode times `runSourceRules` on scan-clean inputs of doubling size, where the shared
# O(m log m) finding-sort contributes nothing and the number is the scan itself.
#
# **Growth ratios, not wall-clock budgets** (the `tests/layout/bench.sh` convention). A machine-time
# threshold would be a number invented here that fails on a slow machine while catching nothing. A
# ratio across an 8x size step separates linear (8x) from quadratic (64x) by a factor that is far
# outside timing noise and means the same thing on any machine.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt-tests
tests=$(lake -q query lean-fmt-tests --text)

output=$("$tests" security-bench)
printf '%s\n' "$output"

failures=0

field() { printf '%s\n' "$output" | sed -n "s/^$1 .*$2=\([0-9.]*\).*/\1/p"; }

printf -- '--- growth ---\n'

# Linear predicts 8x across the 8x size step; quadratic predicts 64x. The bound of 20 is 2.5x the
# linear prediction and under a third of the quadratic one, so noise cannot reach it and a regression
# to superlinear cannot slip under it.
t_lo=$(field clean-1x ms)
t_hi=$(field clean-8x ms)
b_lo=$(field clean-1x bytes)
b_hi=$(field clean-8x bytes)
if [[ -z $t_lo || -z $t_hi ]]; then
  printf 'FAIL: missing clean-1x or clean-8x measurement\n' >&2
  failures=$((failures + 1))
else
  ratio=$(awk -v a="$t_lo" -v b="$t_hi" 'BEGIN { printf "%.1f", b / a }')
  size=$(awk -v a="$b_lo" -v b="$b_hi" 'BEGIN { printf "%d", b / a }')
  if awk -v r="$ratio" 'BEGIN { exit !(r > 20) }'; then
    printf 'FAIL clean scan: %sx over %sx size, over the 20x bound — not linear\n' \
      "$ratio" "$size" >&2
    failures=$((failures + 1))
  else
    printf '  ok   clean scan       %6sx over %sx size (bound 20x) — linear in source size\n' \
      "$ratio" "$size"
  fi
fi

# Per-byte cost must be flat across the whole range, not merely bounded end to end: a superlinear kink
# between two adjacent doublings would still pass an 8x-step bound if a later step compensated.
prev=""
for label in clean-1x clean-2x clean-4x clean-8x; do
  ms=$(field "$label" ms)
  bytes=$(field "$label" bytes)
  ns=$(awk -v ms="$ms" -v b="$bytes" 'BEGIN { printf "%.3f", (ms * 1000000) / b }')
  printf '  info %-12s %s ns/byte\n' "$label" "$ns"
  if [[ -n $prev ]] && awk -v a="$prev" -v b="$ns" 'BEGIN { exit !(b > a * 1.6) }'; then
    printf 'FAIL %s: per-byte cost jumped %sx from the previous size — a superlinear kink\n' \
      "$label" "$(awk -v a="$prev" -v b="$ns" 'BEGIN { printf "%.2f", b / a }')" >&2
    failures=$((failures + 1))
  fi
  prev="$ns"
done

# Findings still fire at scale, in this single process — no worker, no child, no project setup, because
# a source-tier rule reads only the string it is handed. Not asserted for time: its cost is the shared
# finding-sort, not the scan.
printf -- '--- findings fire at scale (worker-free), reported, not timed ---\n'
dense_findings=$(printf '%s\n' "$output" | sed -n 's/^dense .* findings=\([0-9]*\).*/\1/p')
dense_bytes=$(field dense bytes)
if [[ -z $dense_findings || $dense_findings -eq 0 ]]; then
  printf 'FAIL: the dense input produced no findings; the scans did not fire at scale\n' >&2
  failures=$((failures + 1))
else
  printf '  ok   dense scan       %s findings over %s bytes, in one process\n' \
    "$dense_findings" "$dense_bytes"
fi

printf 'failures=%d\n' "$failures"
exit $((failures > 0 ? 1 : 0))
