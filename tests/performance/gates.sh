# Gate predicates for `tests/performance` (`ruff-19` RPR-FINAL). Sourced, never executed.
#
# These live apart from `run.sh` for one reason: `negative.sh` must be able to prove that each gate
# *can* fail, and it can only prove that about the logic the suite actually ships. If the negative
# tests reimplemented these conditions they would be testing a copy, and a copy that drifted from
# the original would still pass while the real gate rotted. So the predicates are functions over
# file paths here, `run.sh` calls them on real runs, and `negative.sh` calls the same functions on
# crafted profile output.
#
# Every function is a predicate: it returns 0 when the gate holds and 1 when it does not, and prints
# nothing. Reporting belongs to the caller, which knows whether a failure is expected.

# The 17 top-level phase names. Sub-phases are excluded from the accounted sum -- they are nested
# inside a top-level bracket, so counting both double-counts the same milliseconds.
# `LeanFmt/Profile.lean` (the phase schema) and the instrumentation it documents
# are the source; that table marks every sub-phase in bold, and this list is its complement.
GATE_TOP_LEVEL_PHASES=(
  discovery workspace_load selection_snapshot cache_epoch cache_lookup module_evidence
  official_artifacts import_findings exact_setup setup_prime exact_child envelope_decode
  layout rules cache_write positions render_report
)

# --- accessors over one profile-channel capture ---------------------------------------------------

# The last value of a `cache.*` counter, or empty if the run never emitted it.
gate_counter() { sed -n "s/^$1=\([0-9-]*\)$/\1/p" "$2" | tail -1; }

# The summed milliseconds of one phase across every site that emitted it.
gate_phase_sum() { sed -n "s/^phase\.$1_ms=\([0-9]*\)$/\1/p" "$2" | awk '{n+=$1} END {print n+0}'; }

# How many times one phase was emitted. A count, so it is machine-speed independent.
gate_phase_count() { grep -c "^phase\.$1_ms=" "$2" || true; }

# Milliseconds attributed to top-level phases, which is the numerator of gate G3.
gate_accounted() {
  local stderr_path=$1 name total=0
  for name in "${GATE_TOP_LEVEL_PHASES[@]}"; do
    total=$((total + $(gate_phase_sum "$name" "$stderr_path")))
  done
  printf '%s' "$total"
}

# --- the gates ------------------------------------------------------------------------------------

# §1a. The run saw exactly the workload it was handed. Catches a selection change masquerading as a
# speedup: processing fewer files is always faster and is never an optimization.
gate_targets_match() {
  local stderr_path=$1 expected=$2
  [[ $(gate_counter cache.targets "$stderr_path") == "$expected" ]]
}

# §1b. Every target was an index hit and was served from it. This is the cache-identity gate: when
# an input to the index digest starts moving that should not, hits fall and this fires.
gate_fully_served() {
  local stderr_path=$1
  local targets hits served
  targets=$(gate_counter cache.targets "$stderr_path")
  hits=$(gate_counter cache.index_hits "$stderr_path")
  served=$(gate_counter cache.served "$stderr_path")
  [[ -n $targets && $hits == "$targets" && $served == "$targets" ]]
}

# §1c. The strongest single gate here. A fully served run must never reach the exact frontend or
# resolve a per-target Lake setup; both are the expensive paths `RPR-IMPL` spent its optimizations
# getting off the warm path, and both are counts rather than durations.
gate_no_frontend_work() {
  local stderr_path=$1
  [[ $(gate_phase_count exact_child "$stderr_path") == 0 &&
    $(gate_phase_count exact_setup "$stderr_path") == 0 ]]
}

# §2. Gate G3, recalibrated onto the remainder rather than the percentage. See `run.sh` for the
# measurement that motivates the form: the unaccounted time is a ~51 ms constant (process startup
# nothing brackets), so a *percentage* threshold is workload-length-dependent and a *remainder*
# threshold is not. Fires when a genuinely unbracketed region of work appears.
gate_remainder_within() {
  local stderr_path=$1 wall=$2 bound=$3
  local accounted
  accounted=$(gate_accounted "$stderr_path")
  ((wall - accounted <= bound))
}

# §3. One named phase both exists and measured something. This is the `withPhase <| pure e` defect
# class: Lean is strict, so a pure value bound inside the bracket is evaluated before the bracket
# opens and the phase reports 0 ms forever. It looks like speed and is actually blindness, and it
# silently voided every figure the phase ever produced.
gate_phase_measures() {
  local stderr_path=$1 name=$2
  (($(gate_phase_count "$name" "$stderr_path") > 0)) &&
    (($(gate_phase_sum "$name" "$stderr_path") > 0))
}

# §4. The report did not change. Every other gate above is satisfiable by doing less work *and*
# getting the answer wrong; this is the one that is not.
gate_reports_identical() { cmp -s "$1" "$2"; }
