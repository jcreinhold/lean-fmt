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
#   §1d serial child admission remains explicit and bounded
#   §1e artifact rendering avoids exact-source analysis and preserves the report
#   §2  no work happens outside the top-level phases (RPR-SPEC gate G3, recalibrated)
#   §3  no top-level phase silently measures nothing (the `withPhase <| pure e` defect class)
#   §4  digest reuse: the report is byte-identical cold and warm
#
# Heavier scheduled checks -- the frozen mathlib sample, the positions bench, the integrated
# artifact path, and the concurrency re-test -- are not here. They cost minutes, not seconds, and
# live in `experiments/` for a scheduled runner.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

fmt="$repo_root/.lake/build/bin/lean-fmt"
tests="$repo_root/.lake/build/bin/lean-fmt-tests"
manifest="$repo_root/experiments/workloads/lean-fmt-self.txt"

if [[ ! -x $fmt ]]; then
  printf 'build lean-fmt first: lake build\n' >&2
  exit 2
fi
if [[ ! -x $tests ]]; then
  printf 'build lean-fmt-tests first: lake build\n' >&2
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

# The gate predicates. `tests/performance/negative.sh` proves each one can fail by calling these
# same functions on crafted profile output, which is why they are a sourced library and not inline.
# shellcheck source=tests/performance/gates.sh
source "$repo_root/tests/performance/gates.sh"

# Run the workload, capturing the report on stdout and the profile channel on stderr.
profile_run() {
  local stdout_path=$1 stderr_path=$2
  LEAN_FMT_PROFILE_PHASES=1 "$fmt" check --output-format concise --root "$repo_root" "${files[@]}" \
    >"$stdout_path" 2>"$stderr_path" || true
}

printf 'tests/performance: durable gates, no wall-time thresholds\n\n'

printf -- '--- §0 the gates themselves discriminate ---\n'

# Before trusting four "ok" lines, check that they are capable of not being "ok". `negative.sh`
# feeds every predicate in `gates.sh` both input it must accept and input it must reject; a gate
# that cannot fail would report a healthy tree exactly as convincingly as `return 0` does. It runs
# first because an instrument is checked before it is read, and it is pure text handling, so it
# costs milliseconds.
if bash "$repo_root/tests/performance/negative.sh" >"$scratch/negative.log" 2>&1; then
  ok "$(tail -1 "$scratch/negative.log" | sed 's/^tests.performance negative: ok //;s/[()]//g')"
else
  bad "the gate predicates do not discriminate; see below"
  sed 's/^/    /' "$scratch/negative.log" >&2
fi

printf -- '\n--- §0b renderer work is linear in document nodes ---\n'
"$tests" doc-step-counts >"$scratch/doc-steps.out"
if gate_doc_steps_linear "$scratch/doc-steps.out"; then
  ok "every custom node is visited once and every mark adds one close step (8 adversarial rows)"
else
  bad "renderer work is no longer steps = nodes + marks, or the step report is incomplete"
  sed 's/^/    /' "$scratch/doc-steps.out" >&2
fi

printf -- '\n--- §0c validation performs exactly two frontend renders ---\n'
validator_fixture="$repo_root/tests/performance/validator-gate/Accepted.lean"
lake setup-file "$validator_fixture" >"$scratch/validator-setup.json"
"$fmt" __analyze-exact "$scratch/validator-setup.json" "$validator_fixture" \
  "$validator_fixture" 8589934592 4:80 >"$scratch/validator.json"
if python3 - "$scratch/validator.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
canonical = result.get("canonical")
assert canonical is not None and result.get("validationFailure") is None, result
assert canonical["validation"] == {
    "frontendRuns": 2,
    "renders": 2,
    "structuralComparisons": 1,
    "idempotencePasses": 1,
}, canonical
assert canonical["metrics"]["frontendRuns"] == 2, canonical
PY
then
  ok "one candidate run plus one reparsed idempotence run; no hidden third render"
else
  bad "validation work counts changed from frontend/renders/comparisons/idempotence = 2/2/1/1"
fi

printf -- '\n--- §1 a warm run is fully cache-served ---\n'

# Prime. The first run may be cold for any reason -- a rebuilt binary, a fresh checkout, another
# suite having cleaned -- and that is not what this section measures.
profile_run "$scratch/prime.out" "$scratch/prime.err"

profile_run "$scratch/warm.out" "$scratch/warm.err"

targets=$(gate_counter cache.targets "$scratch/warm.err")
hits=$(gate_counter cache.index_hits "$scratch/warm.err")
served=$(gate_counter cache.served "$scratch/warm.err")

if gate_targets_match "$scratch/warm.err" "$expected_targets"; then
  ok "the manifest's $expected_targets files are the targets"
else
  bad "expected $expected_targets targets, got '${targets:-<none>}'"
fi

if gate_fully_served "$scratch/warm.err"; then
  ok "every target is an index hit and is served ($hits/$targets)"
else
  bad "warm run not fully served: targets=${targets:-<none>} hits=${hits:-<none>} served=${served:-<none>}"
fi

child_runs=$(gate_phase_count exact_child "$scratch/warm.err")
setup_runs=$(gate_phase_count exact_setup "$scratch/warm.err")
if gate_no_frontend_work "$scratch/warm.err"; then
  ok "neither the exact frontend nor per-target setup runs on a served workload"
else
  bad "warm run did frontend work: $child_runs children, $setup_runs setup resolutions; expected 0 and 0"
fi

printf -- '\n--- §1d/§1e bounded child lifetime and artifact acceleration ---\n'

artifact_fixture="$repo_root/tests/compiler/ArtifactLayout.lean"
LEAN_NUM_THREADS=1 lake build +ArtifactLayout:leanFmtArtifact >/dev/null
LEAN_FMT_PROFILE_PHASES=1 LEAN_NUM_THREADS=1 "$fmt" diff --no-cache "$artifact_fixture" \
  >"$scratch/artifact.out" 2>"$scratch/artifact.err" || true
LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_PROFILE_PHASES=1 LEAN_NUM_THREADS=1 \
  "$fmt" diff --no-cache "$artifact_fixture" \
  >"$scratch/exact.out" 2>"$scratch/exact.err" || true

if gate_serial_children "$scratch/artifact.err" 1 && gate_serial_children "$scratch/exact.err" 1; then
  ok "artifact and exact strategies each admit exactly one active child"
else
  bad "child admission was absent or exceeded one active child"
fi

if gate_artifact_avoids_exact "$scratch/artifact.err" "$scratch/exact.err"; then
  ok "artifact-built formatting uses one artifact child and zero exact-source children"
else
  bad "artifact/exact strategy counts no longer distinguish their frontend work"
fi

if gate_reports_identical "$scratch/artifact.out" "$scratch/exact.out"; then
  ok "artifact-built and exact-source reports are byte-identical"
else
  bad "artifact-built and exact-source reports differ"
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

accounted=$(gate_accounted "$scratch/g3.err")

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
# This gate therefore bounds the **remainder**, which is the quantity that actually stays put --
# provided the machine is not thrashing. "It is a constant" was calibrated over five runs whose wall
# ranged 453-1,225 ms, and it is false past that: on 2026-07-25, with a mathlib child and two builds
# sharing the machine, this same run measured **841 ms of 6,913 ms** and the gate reported a
# regression that was not there. A re-run on the quiet machine read 57 ms of 638 ms. A gate that
# fails on load is a gate people learn to re-run, which is the same as not having one.
#
# So the constant is measured here rather than carried in from another machine. `rules --json` loads
# the same binary, initializes the same Lean runtime, does a bounded amount of work and exits: it is
# process startup with a receipt. It reads 23-25 ms quiet, against the 50-51 ms remainder the real
# run leaves, and both inflate together because both are the same class of cost. The bound stays 250
# ms whenever the machine is quiet -- 10x the quiet control, which is where the original calibration
# put it -- and scales with the control when it is not.
control_ms=$(python3 - "$fmt" <<'CONTROL'
import subprocess, sys, time
started = time.monotonic()
subprocess.run([sys.argv[1], "rules", "--json"], capture_output=True)
print(int((time.monotonic() - started) * 1000))
CONTROL
)
GATE_REMAINDER_BOUND_MS=$(( control_ms * 10 > 250 ? control_ms * 10 : 250 ))
fraction=$(python3 -c "print(round(100.0 * $accounted / max($wall, 1), 1))")
unaccounted=$((wall - accounted))
if gate_remainder_within "$scratch/g3.err" "$wall" "$GATE_REMAINDER_BOUND_MS"; then
  ok "unaccounted remainder ${unaccounted} ms of ${wall} ms (${fraction}% accounted, bound \
${GATE_REMAINDER_BOUND_MS} ms from a ${control_ms} ms startup control)"
else
  bad "unaccounted remainder ${unaccounted} ms of ${wall} ms exceeds the ${GATE_REMAINDER_BOUND_MS} ms startup bound: work is happening outside every top-level phase"
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
# A control byte (FMT001) inside a comment: it fires anywhere, needs no frontend, is report-only, and
# leaves the file parseable. Placed at the end, so `positionsOf` must walk the whole source to reach it.
header = "/-\nCopyright (c) 2026 Jacob Reinhold. All rights reserved.\n-/\n\nmodule\n\n/-\n"
body = ("x" * 79 + "\n") * (2_000_000 // 80)
pathlib.Path(sys.argv[1]).write_text(header + body + "\x01" + "\n-/\n", encoding="utf-8")
PY

LEAN_FMT_PROFILE_PHASES=1 "$fmt" check --output-format concise --root "$repo_root" \
  "$fixture_dir/Late.lean" >"$scratch/pos.out" 2>"$scratch/pos.err" || true
rm -rf "$fixture_dir"

positions_emitted=$(gate_phase_count positions "$scratch/pos.err")
positions_ms=$(gate_phase_sum positions "$scratch/pos.err")

if gate_phase_measures "$scratch/pos.err" positions; then
  ok "the PositionIndex build measures itself (${positions_ms} ms over 2 MB)"
elif ((positions_emitted == 0)); then
  bad "phase.positions_ms was never emitted; the bracket is gone or the finding did not fire"
else
  bad "phase.positions_ms read 0 ms over 2 MB: the bracket is timing an already-evaluated value"
fi

printf -- '\n--- §4 digest reuse: cold and warm agree byte for byte ---\n'

# A performance change that alters the report is not a performance change. Comparing the primed run's
# report against the warm run's is the cheapest possible correctness anchor for everything above:
# every gate here is satisfiable by doing less work *and* getting it wrong, except this one.
if gate_reports_identical "$scratch/prime.out" "$scratch/warm.out"; then
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
