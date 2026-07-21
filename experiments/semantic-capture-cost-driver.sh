#!/usr/bin/env bash
set -euo pipefail

# Inner command for `run-semantic-cost.sh`, wrapped by `profile-run.sh` so its wall time and peak
# aggregate RSS are recorded. For every source in the manifest it runs one `__analyze-exact` child —
# the exact production capture path — with `captureSemantic` set to $cap (1 = semantic, 0 = the
# syntax-only baseline). Elaboration is identical in both; only the trailing notation-spacing walk
# differs, so the paired delta isolates the semantic fact's cost. Setups are pre-generated and reused
# across both passes, so `lake setup-file` is never inside the profiled region.

cap=$1
manifest=$2
setup_dir=$3
mathlib_root=$4
application=$5
mathlib_lean_path=$6
maxb=$7

index=0
captured_total=0
while IFS= read -r source; do
  [[ -n $source ]] || continue
  index=$((index + 1))
  setup="$setup_dir/$index.setup.json"
  out=$(LEAN_PATH="$mathlib_lean_path" LEAN_NUM_THREADS=1 \
    lake env "$application" __analyze-exact \
    "$setup" "$mathlib_root/$source" "$source" "$maxb" "$cap")
  # Count captured notations so the baseline and semantic passes are provably doing different work.
  n=$(printf '%s' "$out" | python3 -c 'import json,sys
a=json.load(sys.stdin)["artifact"]
s=a.get("semantic")
print(len(s["notations"]) if s else 0)')
  captured_total=$((captured_total + n))
done <"$manifest"

printf 'phase.files_ms=%d\n' "$index"
printf 'phase.captured_notations_ms=%d\n' "$captured_total"
