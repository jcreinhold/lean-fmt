#!/usr/bin/env bash
# RGR-EVIDENCE §5.3 CP-2 measurement (`ruff-12b`). What does an `ordinary-built` project pay, on the
# cold path, for one default rule above source tier?
#
# `results/01-criteria.md` §5.3 set the budget at 1.25x the five-rule baseline and projected, from
# `ruff-19`'s ~408 ms marginal per module, that a syntax-tier rule would cost about 2x. That projection
# came from four small fixture modules in lean-fmt's own tree, and `ruff-19` said so in as many words:
# "It is not a speed benchmark: four small fixture modules are not a project." This measures the same
# quantity on 62 real mathlib modules.
#
# Both arms run in ONE `check` invocation over the whole manifest, so per-process and per-workspace
# setup is amortized exactly once — the opposite of `run-lifecycle-precision-sample.sh`, which spawns a
# process per module and therefore overstates the per-module cost.
#
# mathlib is built but NOT built with `LeanFmtCompilerPlugin`, so its `.olean`s carry no
# `leanFmtArtifact`. That is the definition of `ordinary-built`, and it is reached here without
# `LEAN_FMT_DISABLE_ARTIFACT`: the facet lookup runs and finds nothing, which is the cost CP-4 is about.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
source "$repo_root/tests/performance/gates.sh"

mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
reps=${REPS:-3}
fmt="$repo_root/.lake/build/bin/lean-fmt"
[[ -x $fmt ]] || {
  echo "build lean-fmt first" >&2
  exit 2
}

files=()
while IFS= read -r f; do [[ -n $f ]] && files+=("$f"); done <"$sources"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# `ruff-19`'s variance policy: median of >=3, never the first run. `--no-cache` makes every repetition
# cold, which is the workload under test -- the warm path is CP-1's and is already settled.
arm() {
  local label=$1
  shift
  local -a walls=() children=() child_ms=()
  local i
  for ((i = 0; i <= reps; i++)); do
    local err="$work/$label.$i.err" t0 t1
    t0=$(python3 -c 'import time; print(time.monotonic())')
    LEAN_FMT_PROFILE_PHASES=1 "$fmt" check --output-format concise --root "$mathlib_root" \
      --no-cache "$@" "${files[@]}" >"$work/$label.$i.out" 2>"$err" || true
    t1=$(python3 -c 'import time; print(time.monotonic())')
    # Run 0 is the discard: a first run is cold for reasons that are not the subject.
    ((i == 0)) && continue
    walls+=("$(python3 -c "print(round(($t1-$t0)*1000))")")
    children+=("$(gate_phase_count exact_child "$err")")
    child_ms+=("$(gate_phase_sum exact_child "$err")")
  done
  python3 - "$label" "${#files[@]}" "${walls[@]}" -- "${children[@]}" -- "${child_ms[@]}" <<'PY'
import sys, statistics
label, nfiles = sys.argv[1], int(sys.argv[2])
rest = sys.argv[3:]
a = rest[:rest.index("--")]; rest = rest[rest.index("--")+1:]
b = rest[:rest.index("--")]; c = rest[rest.index("--")+1:]
walls = [int(x) for x in a]
print(f"{label:34s} wall_median={statistics.median(walls):>8.0f} ms  "
      f"spread={min(walls)}-{max(walls)}  "
      f"exact_child_count={b[0]}  exact_child_ms={c[0]}  "
      f"per_module={statistics.median(walls)/nfiles:.0f} ms")
PY
}

printf 'CP-2: ordinary-built cold cost of a default rule above source tier\n'
printf 'corpus=%s (%d modules)  root=%s  reps=%d (first discarded)\n' \
  "$(basename "$sources")" "${#files[@]}" "$mathlib_root" "$reps"
printf 'mathlib is built WITHOUT LeanFmtCompilerPlugin, so this is the ordinary-built state.\n\n'

arm "baseline (default, 5 rules)"
arm "+FMT011 (syntax tier)" --preview --select default --select FMT011
