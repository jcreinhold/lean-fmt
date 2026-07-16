#!/usr/bin/env bash
set -euo pipefail

# Layout cost, asserted rather than asserted-about.
#
# `notes/01-layout-design.md` §4.6 makes a complexity claim, and the roadmap requires rendering be
# "linear or demonstrably near-linear on adversarial nesting". `RLC-FINAL` found that claim was false
# when it was written — every group nested inside a flat group re-ran the whole fit test, making
# adversarial nesting quadratic. A note cannot notice that; this can.
#
# **Growth ratios, not wall-clock budgets.** A machine-time threshold would be a number invented here
# and would fail on a slow machine while catching nothing. A ratio across a 10x or 8x size step
# separates linear from quadratic by a factor of 8-100, which is far outside timing noise, and it
# means the same thing on any machine.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt-tests
tests=$(lake -q query lean-fmt-tests --text)

output=$("$tests" doc-bench)
printf '%s\n' "$output"

failures=0

ms_at() {
  printf '%s\n' "$output" | sed -n "s/^$1 n=$2 .* ms=\([0-9.]*\) .*/\1/p"
}

# `label`: shape; `lo`/`hi`: the size step; `bound`: the largest growth ratio still consistent with the
# claim. Linear predicts hi/lo; quadratic predicts (hi/lo)². The bound sits between them, nearer the
# linear end, so noise cannot reach it and a regression to quadratic cannot miss it.
assert_growth() {
  local label=$1 lo=$2 hi=$3 bound=$4 claim=$5
  local t_lo t_hi ratio
  t_lo=$(ms_at "$label" "$lo")
  t_hi=$(ms_at "$label" "$hi")
  if [[ -z "$t_lo" || -z "$t_hi" ]]; then
    printf 'FAIL %s: no measurement at n=%s or n=%s\n' "$label" "$lo" "$hi" >&2
    failures=$((failures + 1))
    return
  fi
  ratio=$(awk -v a="$t_lo" -v b="$t_hi" 'BEGIN { printf "%.1f", b / a }')
  if awk -v r="$ratio" -v b="$bound" 'BEGIN { exit !(r > b) }'; then
    printf 'FAIL %s: %sx from n=%s to n=%s, over the %sx bound — %s\n' \
      "$label" "$ratio" "$lo" "$hi" "$bound" "$claim" >&2
    failures=$((failures + 1))
  else
    printf '  ok   %-18s %6sx over %sx size (bound %sx) — %s\n' "$label" "$ratio" \
      "$(awk -v a="$lo" -v b="$hi" 'BEGIN { printf "%d", b / a }')" "$bound" "$claim"
  fi
}

printf -- '--- growth ---\n'

# The roadmap's actual bar, and the reason this file exists. Before RLC-FINAL this was 72x (quadratic);
# it is now ~8x. A bound of 24 is 3x the linear prediction and a third of the quadratic one.
assert_growth zero-width-nesting 1000 8000 24 "roadmap: near-linear on adversarial nesting"

# The shape a real printer emits: a group per construct, text in every one.
assert_growth call-args 1000 100000 300 "linear on realistic width"
assert_growth marked-call-args 1000 100000 400 "mark costs a constant, not an exponent"

# `nested-calls` is *linear in output bytes* but its output is Θ(n²) bytes, because `nest` is unclamped
# by contract (§4.6). Billing it per node would fail for a reason that is not the fit test's fault, so
# it is billed per byte: ~2.2 ns/byte at every size.
ns_per_byte() {
  local n=$1 ms bytes
  ms=$(ms_at nested-calls "$n")
  bytes=$(printf '%s\n' "$output" | sed -n "s/^nested-calls n=$n .* out_bytes=\([0-9]*\) .*/\1/p")
  awk -v ms="$ms" -v b="$bytes" 'BEGIN { printf "%.2f", (ms * 1000000) / b }'
}
small=$(ns_per_byte 1000)
large=$(ns_per_byte 10000)
printf '  info nested-calls      %s ns/byte at n=1000, %s ns/byte at n=10000\n' "$small" "$large"
if awk -v a="$small" -v b="$large" 'BEGIN { exit !(b > a * 4) }'; then
  printf 'FAIL nested-calls: cost per output byte grew %sx; it should be flat\n' \
    "$(awk -v a="$small" -v b="$large" 'BEGIN { printf "%.1f", b / a }')" >&2
  failures=$((failures + 1))
else
  printf '  ok   nested-calls      cost per output byte is flat — the Θ(n²) is `nest`, not the fit test\n'
fi

# `zero-width-siblings` is the known hole and is deliberately NOT asserted linear: it is quadratic, on
# purpose, and §4.6 records why. `n` sibling groups that spend no column and offer no break force every
# fit test to walk the whole tail, because "does this fit up to the next break" genuinely depends on the
# whole tail when there is no next break. Closing it needs Oppen's running total — the model RLC-SPEC
# rejected on expressiveness. It is reported so the number cannot drift unnoticed.
printf -- '--- the known hole (§4.6), reported, not asserted ---\n'
sib_lo=$(ms_at zero-width-siblings 1000)
sib_hi=$(ms_at zero-width-siblings 8000)
printf '  info zero-width-siblings %sx over 8x size (linear would be 8x) — quadratic, as documented\n' \
  "$(awk -v a="$sib_lo" -v b="$sib_hi" 'BEGIN { printf "%.1f", b / a }')"

printf 'failures=%d\n' "$failures"
exit $((failures > 0 ? 1 : 0))
