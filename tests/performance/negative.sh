#!/usr/bin/env bash
set -euo pipefail

# Negative tests for the performance gates (`ruff-19` RPR-FINAL).
#
# ## Why this file exists
#
# `run.sh` reports "ok" four times against a healthy tree. That is exactly what it would report if
# every predicate were `return 0`. A gate nobody has ever seen fail is not evidence of health; it is
# an untested claim, and the more reassuring its output the more expensive the eventual surprise.
#
# So each gate is exercised twice here: on input it must accept, and on input it must reject. Both
# halves matter. A predicate that always fails would catch every regression and be uninstallable; a
# predicate that always passes catches nothing and looks perfect. Only the pair pins the behavior.
#
# ## Why the rejection cases are crafted rather than provoked
#
# Provoking a real cache miss means editing a source file mid-suite; provoking a real unbracketed
# region means editing `LeanFmt/*.lean` and rebuilding. Both would make this suite mutate the tree
# it is measuring, and the second would take minutes. The predicates read the profile channel, and
# the profile channel is text, so the honest cheap route is to hand them the text a broken formatter
# would emit. That tests the gate, which is this file's job. Whether the *formatter* emits that text
# under real breakage is `run.sh`'s job, on real runs.
#
# The crafted captures are not invented from scratch: each is a real warm capture's shape with one
# quantity moved, and the moved quantity is named in the case description.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

# shellcheck source=tests/performance/gates.sh
source "$repo_root/tests/performance/gates.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

failures=0
checked=0

# `expect_accept`/`expect_reject` invert the usual reporting: here a predicate returning 1 is the
# passing outcome for half the cases, so the case description says which is expected.
expect_accept() {
  local description=$1
  shift
  checked=$((checked + 1))
  if "$@"; then
    printf '  ok   accepts %s\n' "$description"
  else
    printf '  FAIL rejected %s, which is valid\n' "$description" >&2
    failures=$((failures + 1))
  fi
}

expect_reject() {
  local description=$1
  shift
  checked=$((checked + 1))
  if "$@"; then
    printf '  FAIL accepted %s; this gate cannot fail and guards nothing\n' "$description" >&2
    failures=$((failures + 1))
  else
    printf '  ok   rejects %s\n' "$description"
  fi
}

# A healthy warm capture: 45 targets, all hit and served, no frontend work, phases that measure.
cat >"$scratch/healthy.err" <<'CAPTURE'
cache.targets=45
cache.index_hits=45
cache.served=45
phase.discovery_ms=7
phase.workspace_load_ms=515
phase.selection_snapshot_ms=5
phase.cache_epoch_ms=5
phase.cache_lookup_ms=139
phase.import_findings_ms=27
phase.positions_ms=17
phase.render_report_ms=0
CAPTURE

printf 'tests/performance negative: every gate must be able to fail\n\n'

printf -- '--- §0b renderer work is linear in nodes plus marks ---\n'
cat >"$scratch/doc-healthy.out" <<'CAPTURE'
doc-steps label=zero-width-siblings n=1000 nodes=4001 steps=4001 marks=0 native=0
doc-steps label=zero-width-nesting n=1000 nodes=2001 steps=2001 marks=0 native=0
doc-steps label=call-args n=1000 nodes=6005 steps=6005 marks=0 native=0
doc-steps label=marked-call-args n=1000 nodes=7005 steps=8005 marks=1000 native=0
doc-steps label=zero-width-siblings n=8000 nodes=32001 steps=32001 marks=0 native=0
doc-steps label=zero-width-nesting n=8000 nodes=16001 steps=16001 marks=0 native=0
doc-steps label=call-args n=8000 nodes=48005 steps=48005 marks=0 native=0
doc-steps label=marked-call-args n=8000 nodes=56005 steps=64005 marks=8000 native=0
CAPTURE
expect_accept "eight renderer rows with steps = nodes + marks" \
  gate_doc_steps_linear "$scratch/doc-healthy.out"

sed 's/nodes=32001 steps=32001/nodes=32001 steps=64001/' \
  "$scratch/doc-healthy.out" >"$scratch/doc-rescan.out"
expect_reject "a zero-width suffix rescan doubling renderer work" \
  gate_doc_steps_linear "$scratch/doc-rescan.out"

head -7 "$scratch/doc-healthy.out" >"$scratch/doc-truncated.out"
expect_reject "a truncated renderer report that omits one adversarial row" \
  gate_doc_steps_linear "$scratch/doc-truncated.out"

printf -- '--- §1a the workload is the one that was handed over ---\n'
expect_accept "a run over all 45 targets" gate_targets_match "$scratch/healthy.err" 45

sed 's/^cache.targets=45$/cache.targets=44/' "$scratch/healthy.err" >"$scratch/fewer.err"
expect_reject "a run that quietly processed 44 of 45 files" \
  gate_targets_match "$scratch/fewer.err" 45

printf -- '\n--- §1b every target served from the index ---\n'
expect_accept "45 targets, 45 hits, 45 served" gate_fully_served "$scratch/healthy.err"

sed -e 's/^cache.index_hits=45$/cache.index_hits=41/' -e 's/^cache.served=45$/cache.served=41/' \
  "$scratch/healthy.err" >"$scratch/misses.err"
expect_reject "4 cache misses on a warm run (the cache-identity regression)" \
  gate_fully_served "$scratch/misses.err"

grep -v '^cache\.' "$scratch/healthy.err" >"$scratch/nocounters.err"
expect_reject "a capture with no cache counters at all" \
  gate_fully_served "$scratch/nocounters.err"

printf -- '\n--- §1c no frontend work on a served run ---\n'
expect_accept "a capture with neither exact_child nor exact_setup" \
  gate_no_frontend_work "$scratch/healthy.err"

cp "$scratch/healthy.err" "$scratch/child.err"
printf 'phase.exact_child_ms=2058\n' >>"$scratch/child.err"
expect_reject "a served run that still spawned a frontend child" \
  gate_no_frontend_work "$scratch/child.err"

cp "$scratch/healthy.err" "$scratch/setup.err"
printf 'phase.exact_setup_ms=0\n' >>"$scratch/setup.err"
expect_reject "a per-target setup resolution, even one costing 0 ms" \
  gate_no_frontend_work "$scratch/setup.err"

printf -- '\n--- §1d child admission stays serial ---\n'
cat >"$scratch/serial.err" <<'CAPTURE'
cache.active_children=1
cache.active_children=1
CAPTURE
expect_accept "two sequential child admissions" gate_serial_children "$scratch/serial.err" 2

sed '2s/=1$/=2/' "$scratch/serial.err" >"$scratch/concurrent.err"
expect_reject "a second concurrently active child" gate_serial_children "$scratch/concurrent.err" 2
expect_reject "an empty child profile" gate_serial_children "$scratch/healthy.err" 2

printf -- '\n--- §1e artifact formatting avoids exact-source analysis ---\n'
cat >"$scratch/artifact.err" <<'CAPTURE'
phase.artifact_child_ms=900
cache.path_artifact_render=1
CAPTURE
cat >"$scratch/exact-route.err" <<'CAPTURE'
phase.exact_child_ms=1500
cache.path_exact_render=1
CAPTURE
expect_accept "one artifact child versus one forced exact child" \
  gate_artifact_avoids_exact "$scratch/artifact.err" "$scratch/exact-route.err"

cp "$scratch/artifact.err" "$scratch/artifact-regressed.err"
printf 'phase.exact_child_ms=1500\n' >>"$scratch/artifact-regressed.err"
expect_reject "an artifact route that also launches the exact-source child" \
  gate_artifact_avoids_exact "$scratch/artifact-regressed.err" "$scratch/exact-route.err"

printf -- '\n--- §2 gate G3, on the remainder ---\n'
# The healthy capture accounts for 715 ms. A 760 ms wall leaves a 45 ms remainder: the startup
# constant, and inside the bound.
expect_accept "a 45 ms remainder (the measured ~51 ms startup constant)" \
  gate_remainder_within "$scratch/healthy.err" 760 250

# Same capture, 1,500 ms wall: 785 ms is unbracketed. That is a region doing real work that no
# top-level phase brackets, which is precisely what G3 exists to catch.
expect_reject "785 ms of work happening outside every top-level phase" \
  gate_remainder_within "$scratch/healthy.err" 1500 250

# The bound must not be so loose that it stops discriminating near its own edge.
expect_reject "a remainder one millisecond over the bound" \
  gate_remainder_within "$scratch/healthy.err" 966 250

printf -- '\n--- §3 no phase silently measures nothing ---\n'
expect_accept "positions at 17 ms" gate_phase_measures "$scratch/healthy.err" positions

# The exact signature of the defect `RPR-IMPL` found: the phase is emitted, so nothing looks broken,
# and it reads 0 ms forever because the bracket wraps an already-evaluated pure value.
sed 's/^phase.positions_ms=17$/phase.positions_ms=0/' "$scratch/healthy.err" >"$scratch/zero.err"
expect_reject "positions emitted but reading 0 ms over 2 MB (the withPhase <| pure e defect)" \
  gate_phase_measures "$scratch/zero.err" positions

grep -v '^phase\.positions_ms=' "$scratch/healthy.err" >"$scratch/absent.err"
expect_reject "positions never emitted at all" \
  gate_phase_measures "$scratch/absent.err" positions

printf -- '\n--- §4 the report did not change ---\n'
printf 'LeanFmt/Cli.lean:1:1: FMT001 example\n' >"$scratch/report-a.out"
cp "$scratch/report-a.out" "$scratch/report-b.out"
expect_accept "two identical reports" \
  gate_reports_identical "$scratch/report-a.out" "$scratch/report-b.out"

printf 'LeanFmt/Cli.lean:1:2: FMT001 example\n' >"$scratch/report-c.out"
expect_reject "reports differing by one column" \
  gate_reports_identical "$scratch/report-a.out" "$scratch/report-c.out"

printf '\n'
if ((failures == 0)); then
  printf 'tests/performance negative: ok (%d cases, every gate proven to discriminate)\n' "$checked"
else
  printf 'tests/performance negative: %d of %d cases failed\n' "$failures" "$checked" >&2
  exit 1
fi
