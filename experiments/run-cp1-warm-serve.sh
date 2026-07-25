#!/usr/bin/env bash
# RGR-EVIDENCE CP-1 probe (`ruff-12b`). Tests the one prediction `results/01-criteria.md` §5.2 rests on:
# that the aggregate semantic-result cache serves a tier *above source* on a warm hit, so `ruff-19`'s
# §1 gates (fully served, zero `exact_child`, zero `exact_setup`) survive graduating a syntax- or
# semantic-tier rule onto the default path.
#
# This has never been exercised, because no default rule has ever demanded a tier above source. The
# probe does not change any rule's `defaultEnabled`; it simulates the graduated default set by adding
# the rule to an explicit selection, which is the same execution path a default selection takes once
# `resolveAxis` has run.
#
# Everything asserted here is a COUNT, per `tests/performance/run.sh`'s rule, so the result is valid
# even on a loaded machine.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
source "$repo_root/tests/performance/gates.sh"

fmt="$repo_root/.lake/build/bin/lean-fmt"
[[ -x $fmt ]] || {
  echo "build lean-fmt first" >&2
  exit 2
}

files=()
while IFS= read -r f; do [[ -n $f ]] && files+=("$f"); done <"$repo_root/experiments/workloads/lean-fmt-self.txt"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# One arm = one candidate default set. `baseline` is today's five source/import-tier rules; each other
# arm adds one rule of a higher tier to that set.
run_arm() {
  local name=$1
  shift
  local out="$scratch/$name"
  # Prime, then measure the warm repeat. The first run is cold for reasons that are not the subject.
  LEAN_FMT_PROFILE_PHASES=1 "$fmt" check --output-format concise --root "$repo_root" \
    "$@" "${files[@]}" >"$out.prime.out" 2>"$out.prime.err" || true
  LEAN_FMT_PROFILE_PHASES=1 "$fmt" check --output-format concise --root "$repo_root" \
    "$@" "${files[@]}" >"$out.warm.out" 2>"$out.warm.err" || true

  local targets hits served child setup
  targets=$(gate_counter cache.targets "$out.warm.err")
  hits=$(gate_counter cache.index_hits "$out.warm.err")
  served=$(gate_counter cache.served "$out.warm.err")
  child=$(gate_phase_count exact_child "$out.warm.err")
  setup=$(gate_phase_count exact_setup "$out.warm.err")

  local verdict=ok
  gate_targets_match "$out.warm.err" "${#files[@]}" || verdict=FAIL-1a
  gate_fully_served "$out.warm.err" || verdict=FAIL-1b
  gate_no_frontend_work "$out.warm.err" || verdict=FAIL-1c

  # The zero-count gates above are also what a cache that served the *wrong* thing would print, so
  # they are not on their own evidence that the higher tier was served. Two more checks:
  #   - the warm report must equal the cold one byte for byte (`ruff-19` §4's `gate_reports_identical`);
  #   - and the report must be non-empty, or "identical" is two empty files agreeing about nothing.
  cmp -s "$out.prime.out" "$out.warm.out" || verdict="$verdict/REPORT-DIFFERS"
  local lines
  lines=$(wc -l <"$out.warm.out" | tr -d ' ')

  printf '%-34s targets=%-4s hits=%-4s child=%-3s setup=%-3s report_lines=%-4s %s\n' \
    "$name" "$targets" "$hits" "$child" "$setup" "$lines" "$verdict"
}

printf 'CP-1 probe: does a warm run stay fully cache-served with a tier above source selected?\n'
printf 'workload=lean-fmt-self (%d files)  gates=ruff-19 §1a/§1b/§1c (counts only)\n\n' "${#files[@]}"

run_arm "baseline (default, 5 rules)"
run_arm "+FMT010 (syntax tier)" --preview --select default --select FMT010
run_arm "+FMT011 (syntax, fixable)" --preview --select default --select FMT011
run_arm "+FMT013 (semantic tier)" --preview --select default --select FMT013
run_arm "+all ten preview" --preview --select default --select FMT006 --select FMT007 \
  --select FMT008 --select FMT009 --select FMT010 --select FMT011 --select FMT012 \
  --select FMT013 --select FMT014 --select FMT015
