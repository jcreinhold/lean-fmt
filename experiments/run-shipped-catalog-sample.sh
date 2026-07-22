#!/usr/bin/env bash
# RGR-FINAL shipped-catalog confirmation (`ruff-12b`). Runs the frozen 62-module mathlib sample under
# the catalog AS SHIPPED and records the finding count per selector, so the accepted catalog rests on
# a run of the built binary rather than on `RGR-EVIDENCE`'s numbers carried forward.
#
# Three arms, because the shipped change is a SELECTOR-VISIBLE one and a count alone would not show it:
#
#   default          the five source/import-tier default rules. Unchanged by `ruff-12b`, so this arm
#                    is the control: it must reproduce CP-2's baseline (27 findings).
#   all              `--select all` with NO `--preview`. Before `ruff-12b` this equalled `default`,
#                    because every stable rule was default-on. It must now be default + FMT013 --
#                    that difference IS the stable-optional outcome, observed end to end.
#   all --preview    every live rule. Must reproduce `RGR-EVIDENCE`'s 2 findings; a change here means
#                    something moved between measuring the catalog and shipping it.
#
# Counts only. No wall time is asserted -- `tests/performance/run.sh` owns cost, and `ruff-19`'s
# variance policy is why a number measured here would not mean anything.
#
# mathlib is built but NOT built with `LeanFmtCompilerPlugin`, so this is the `ordinary-built`
# workload. `--no-cache` makes each arm cold.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
fmt="$repo_root/.lake/build/bin/lean-fmt"
[[ -x $fmt ]] || { echo "build lean-fmt first" >&2; exit 2; }
[[ -d $mathlib_root ]] || { echo "no mathlib at $mathlib_root" >&2; exit 2; }

files=(); while IFS= read -r f; do [[ -n $f ]] && files+=("$f"); done <"$sources"
echo "manifest: ${#files[@]} modules from $sources"

out_dir=${OUT_DIR:-$(mktemp -d)}
mkdir -p "$out_dir"
echo "reports: $out_dir"

arm() {
  local label=$1; shift
  local json="$out_dir/$label.json"
  # `check` exits 1 when it reports findings, which is not a failure of the run.
  set +e
  "$fmt" check --root "$mathlib_root" --json --no-cache "$@" "${files[@]}" >"$json" 2>"$json.err"
  local rc=$?
  set -e
  if [[ $rc -gt 1 ]]; then
    echo "  $label: RUN FAILED (exit $rc)" >&2; tail -5 "$json.err" >&2; return 1
  fi
  # Codes in emission order, so a count is never reported without saying which rules produced it.
  local codes
  codes=$(grep -o '"code":"FMT[0-9]*"' "$json" | sed 's/.*"\(FMT[0-9]*\)"/\1/' | sort | uniq -c \
            | awk '{printf "%s×%s ", $1, $2}')
  local n
  n=$(grep -o '"code":"FMT[0-9]*"' "$json" | wc -l | tr -d ' ')
  printf '  %-16s findings=%-4s %s\n' "$label" "$n" "${codes:-(none)}"
}

arm default       --select default
arm all           --select all
arm all-preview   --select all --preview
