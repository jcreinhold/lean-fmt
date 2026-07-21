#!/usr/bin/env bash
set -euo pipefail

# Durable per-commit performance gates (`ruff-19` RPR-FINAL).
#
# ## What this suite refuses to do
#
# It does not assert a wall time. `RPR-IMPL` measured the same unchanged binary over the same warm
# corpus at 3,977 ms and at 19,968 ms depending on nothing but what else the machine was doing, and
# `phase.module_evidence_ms` alone swings 1,687-5,916 ms on page-cache state. A threshold calibrated
# on a quiet machine fails on a busy one, gets raised until it never fires, and then guards nothing.
# The prompt's own stop rule says it: "do not encode flaky wall-time thresholds without calibration."
#
# So every gate below is a **count, a ratio, or a digest** -- quantities that do not move when the
# machine gets slower. What they catch is a *change in the work performed*, which is what a
# performance regression actually is.
#
# ## Why it primes in-run rather than assuming a warm cache
#
# `tests/cache/run.sh` documents the self-hosting hazard: the cache index is named by a digest that
# includes the formatter binary's own identity, so editing any `LeanFmt/*.lean` rebuilds the binary,
# renames the index, and orphans every entry. A gate that assumed a warm cache would therefore fail
# on every commit that touched the formatter -- which is every commit this suite exists to guard.
# Each section primes and then measures, so it depends on no prior state.
#
# ## The gates
#
#   §1  a warm run is fully cache-served: hits == served == targets, and the frontend never runs
#   §2  no work happens outside the top-level phases (RPR-SPEC gate G3, recalibrated)
#   §3  no top-level phase silently measures nothing (the `withPhase <| pure e` defect class)
#   §4  digest reuse: the report is byte-identical cold and warm
#
# Heavier scheduled checks -- the frozen mathlib sample, the positions bench, the integrated
# artifact path, and the concurrency re-test -- are not here. They cost minutes, not seconds, and
# live in `experiments/` for a scheduled runner. See `docs/projects/ruff-19-performance/`.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

fmt="$repo_root/.lake/build/bin/lean-fmt"
manifest="$repo_root/experiments/workloads/lean-fmt-self.txt"

if [[ ! -x $fmt ]]; then
  printf 'build lean-fmt first: lake build\n' >&2
  exit 2
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

files=()
while IFS= read -r relative_path; do
  [[ -z $relative_path ]] || files+=("$repo_root/$relative_path")
done <"$manifest"
expected_targets=${#files[@]}

failures=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
  printf '  FAIL %s\n' "$1" >&2
  failures=$((failures + 1))
}

# The 17 top-level phase names. Sub-phases are excluded from the accounted sum -- they are nested
# inside a top-level bracket and counting both double-counts the same milliseconds.
# `docs/projects/ruff-19-performance/notes/01-phase-schema.md` §5.1 and `notes/02-instrumentation.md`
# are the source; that table marks every sub-phase in bold, and this list is the complement.
top_level=(
  discovery workspace_load selection_snapshot cache_epoch cache_lookup module_evidence
  official_artifacts import_findings exact_setup setup_prime exact_child envelope_decode
  layout rules cache_write positions render_report
)

# Run the workload, capturing the report on stdout and the profile channel on stderr.
profile_run() {
  local stdout_path=$1 stderr_path=$2
  LEAN_FMT_PROFILE_PHASES=1 "$fmt" check --output-format concise --root "$repo_root" "${files[@]}" \
    >"$stdout_path" 2>"$stderr_path" || true
}

counter() { sed -n "s/^$1=\([0-9-]*\)$/\1/p" "$2" | tail -1; }
phase_sum() { sed -n "s/^phase\.$1_ms=\([0-9]*\)$/\1/p" "$2" | awk '{n+=$1} END {print n+0}'; }
phase_count() { grep -c "^phase\.$1_ms=" "$2" || true; }

printf 'tests/performance: durable gates, no wall-time thresholds\n\n'

printf -- '--- §1 a warm run is fully cache-served ---\n'

# Prime. The first run may be cold for any reason -- a rebuilt binary, a fresh checkout, another
# suite having cleaned -- and that is not what this section measures.
profile_run "$scratch/prime.out" "$scratch/prime.err"

profile_run "$scratch/warm.out" "$scratch/warm.err"

targets=$(counter cache.targets "$scratch/warm.err")
hits=$(counter cache.index_hits "$scratch/warm.err")
served=$(counter cache.served "$scratch/warm.err")

if [[ $targets == "$expected_targets" ]]; then
  ok "the manifest's $expected_targets files are the targets"
else
  bad "expected $expected_targets targets, got '${targets:-<none>}'"
fi

if [[ $hits == "$targets" && $served == "$targets" ]]; then
  ok "every target is an index hit and is served ($hits/$targets)"
else
  bad "warm run not fully served: targets=$targets hits=${hits:-<none>} served=${served:-<none>}"
fi

# The strongest single gate in this suite. A cache-served run must never reach the exact frontend;
# if it does, some identity input started moving that should not, which is the `ruff-16b` defect
# class. It is a count, so it holds on any machine.
child_runs=$(phase_count exact_child "$scratch/warm.err")
if [[ $child_runs == 0 ]]; then
  ok "the exact frontend never runs on a fully served workload"
else
  bad "warm run spawned $child_runs exact-frontend children; expected 0"
fi

setup_runs=$(phase_count exact_setup "$scratch/warm.err")
if [[ $setup_runs == 0 ]]; then
  ok "no per-target Lake setup resolution on a fully served workload"
else
  bad "warm run resolved $setup_runs per-target setups; expected 0"
fi

printf -- '\n--- §2 no work outside the top-level phases (gate G3) ---\n'

# The wall clock must cover the formatter process and nothing else. Taking two `python3`
# timestamps around the run instead put both interpreter startups in the denominator, which read as
# 68 ms of unaccounted time the formatter never spent -- the harness failing its own measurement.
# One Python process times the child directly.
wall=$(python3 - "$fmt" "$repo_root" "$scratch/g3.out" "$scratch/g3.err" "${files[@]}" <<'TIMED'
import os, subprocess, sys, time

binary, root, out_path, err_path, *targets = sys.argv[1:]
environment = dict(os.environ, LEAN_FMT_PROFILE_PHASES="1")
command = [binary, "check", "--output-format", "concise", "--root", root, *targets]
with open(out_path, "wb") as out, open(err_path, "wb") as err:
    started = time.monotonic()
    subprocess.run(command, stdout=out, stderr=err, env=environment)
    print(int((time.monotonic() - started) * 1000))
TIMED
)

accounted=0
for name in "${top_level[@]}"; do
  accounted=$((accounted + $(phase_sum "$name" "$scratch/g3.err")))
done

# `RPR-SPEC` states G3 as a percentage -- 90% accounted -- and measured 95.1% and 97.2% on
# `mathlib-sample`. On this workload the same binary accounts for only 89.0%, and calibrating that
# gap is what turns G3 into a gate rather than a coin flip.
#
# The unaccounted remainder over five runs: **51, 51, 67, 51, 50 ms**, while wall ranged 453-1,225 ms.
# It is a constant, not a fraction. It is process startup and teardown -- binary load, Lean runtime
# initialization, exit -- which no phase brackets and none should.
#
# So the percentage form of G3 is workload-length-dependent by construction: a fixed 51 ms is 0.5%
# of a 10.9 s `mathlib-sample` run and 11% of a 450 ms `self` run. The published 95.1%/97.2% figures
# are exactly what this constant predicts. Stating G3 as a bare percentage, with no workload length
# attached, was under-specified; `results/03-regressions.md` records the correction.
#
# This gate therefore bounds the **remainder**, which is the quantity that actually stays put. The
# bound is 250 ms, about 5x the observed constant and above the 67 ms seen when wall spiked 2.7x
# under load. It fires when a genuinely unbracketed region of *work* appears -- which is the
# regression G3 exists to catch -- and not when the machine is busy.
fraction=$(python3 -c "print(round(100.0 * $accounted / max($wall, 1), 1))")
unaccounted=$((wall - accounted))
if ((unaccounted <= 250)); then
  ok "unaccounted remainder ${unaccounted} ms of ${wall} ms (${fraction}% accounted, bound 250 ms)"
else
  bad "unaccounted remainder ${unaccounted} ms of ${wall} ms exceeds the 250 ms startup bound: work is happening outside every top-level phase"
fi

printf -- '\n--- §3 no top-level phase silently measures nothing ---\n'

# `RPR-IMPL` found `phase.positions_ms` reading 0 ms on every workload for a reason that had nothing
# to do with speed: `withPhase "x" <| pure e` evaluates `e` before the bracket opens, so the timer
# measured an already-computed value. Lean is strict, and a plain `let` in a `do` block is floated
# out too; only `IO.lazyPure` forces inside. Every figure the phase had ever produced was void.
#
# The gate is a fixture large enough that the phase *must* be non-zero if it is measuring at all. A
# 2 MB body with one finding at the very end costs tens of milliseconds to index and single-digit
# microseconds to not-measure, so 0 ms is unambiguous evidence of the defect rather than of speed.
fixture_dir="$repo_root/tests/reporting/performance-gate"
mkdir -p "$fixture_dir"
python3 - "$fixture_dir/Late.lean" <<'PY'
import sys, pathlib
# A control byte (FMT003) inside a comment: it fires anywhere, needs no frontend, is report-only, and
# leaves the file parseable. Placed at the end, so `positionsOf` must walk the whole source to reach it.
header = "/-\nCopyright (c) 2026 Jacob Reinhold. All rights reserved.\n-/\n\nmodule\n\n/-\n"
body = ("x" * 79 + "\n") * (2_000_000 // 80)
pathlib.Path(sys.argv[1]).write_text(header + body + "\x01" + "\n-/\n", encoding="utf-8")
PY

LEAN_FMT_PROFILE_PHASES=1 "$fmt" check --output-format concise --root "$repo_root" \
  "$fixture_dir/Late.lean" >"$scratch/pos.out" 2>"$scratch/pos.err" || true
rm -rf "$fixture_dir"

positions_emitted=$(phase_count positions "$scratch/pos.err")
positions_ms=$(phase_sum positions "$scratch/pos.err")

if [[ $positions_emitted -gt 0 ]]; then
  ok "phase.positions_ms is emitted for a file with findings"
else
  bad "phase.positions_ms was never emitted; the bracket is gone or the finding did not fire"
fi

if [[ $positions_ms -gt 0 ]]; then
  ok "the PositionIndex build measures itself (${positions_ms} ms over 2 MB)"
else
  bad "phase.positions_ms read 0 ms over 2 MB: the bracket is timing an already-evaluated value"
fi

printf -- '\n--- §4 digest reuse: cold and warm agree byte for byte ---\n'

# A performance change that alters the report is not a performance change. Comparing the primed run's
# report against the warm run's is the cheapest possible correctness anchor for everything above:
# every gate here is satisfiable by doing less work *and* getting it wrong, except this one.
if cmp -s "$scratch/prime.out" "$scratch/warm.out"; then
  ok "the served report is identical to the report that populated the cache"
else
  bad "cold and warm reports differ; the cache is not serving what it stored"
fi

printf '\n'
if ((failures == 0)); then
  printf 'tests/performance: ok\n'
else
  printf 'tests/performance: %d gate(s) failed\n' "$failures" >&2
  exit 1
fi
