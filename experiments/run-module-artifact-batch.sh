#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
limit=${3:-8}
repeats=${4:-1}
concurrency=${5:-4}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
result_root="$repo_root/experiments/results/module-artifact-batch-$stamp"
manifest="$result_root/manifest.tsv"
batch_manifest="$result_root/batch-manifest.tsv"
concurrent_manifest="$result_root/concurrent-manifest.tsv"

mkdir -p "$result_root"
head -n "$limit" "$sources" >"$result_root/sources.txt"
: >"$manifest"

monotonic_ns() {
  python3 -c 'import time; print(time.monotonic_ns())'
}

elapsed_ms() {
  awk -v start="$1" -v stop="$2" 'BEGIN { printf "%d", (stop - start) / 1000000 }'
}

prepare_started=$(monotonic_ns)
cd "$repo_root"
LEAN_NUM_THREADS=1 lake build LeanFmtCompilerPlugin:shared artifactExtractor
LEAN_NUM_THREADS=1 lake -d experiments/module-artifact-batch build artifact-batch-probe artifact-concurrency-probe
plugin=$(lake -q query LeanFmtCompilerPlugin:shared --text)
extractor=$(lake -q query artifactExtractor --text)
batch_probe="$repo_root/experiments/module-artifact-batch/.lake/build/bin/artifact-batch-probe"
concurrency_probe="$repo_root/experiments/module-artifact-batch/.lake/build/bin/artifact-concurrency-probe"

index=0
while IFS= read -r source; do
  index=$((index + 1))
  case_dir="$result_root/$index"
  mkdir -p "$case_dir"
  setup="$case_dir/setup.json"
  (
    cd "$mathlib_root"
    LEAN_NUM_THREADS=1 lake setup-file "$source" >"$setup"
  )
  module_name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$setup")
  (
    cd "$mathlib_root"
    LEAN_NUM_THREADS=1 lake env lean -DElab.async=false --setup="$setup" --plugin="$plugin" \
      -o "$case_dir/module.olean" "$source" >"$case_dir/compile.stdout" \
      2>"$case_dir/compile.stderr"
  )
  printf '%s\t%s\t%s\n' "$module_name" "$case_dir/module.olean" "$case_dir/batch.json" \
    >>"$manifest"
done <"$result_root/sources.txt"
: >"$concurrent_manifest"
while IFS=$'\t' read -r module_name module_file _batch_output; do
  item=${module_file%/module.olean}
  printf '%s\t%s\t%s\n' "$module_name" "$module_file" "$item/concurrent.json" \
    >>"$concurrent_manifest"
done <"$manifest"
for ((repeat = 0; repeat < repeats; repeat++)); do
  cat "$manifest" >>"$batch_manifest"
done
prepare_finished=$(monotonic_ns)
printf 'phase.prepare_ms=%s\n' "$(elapsed_ms "$prepare_started" "$prepare_finished")"

lean_path=$(cd "$mathlib_root" && lake env printenv LEAN_PATH)
single_started=$(monotonic_ns)
while IFS=$'\t' read -r module_name module_file _batch_output; do
  item=${module_file%/module.olean}
  LEAN_PATH="$lean_path" LEAN_NUM_THREADS=1 \
    "$extractor" "$module_name" "$module_file" "$item/single.json"
done <"$manifest"
single_finished=$(monotonic_ns)
printf 'phase.single_total_ms=%s\n' "$(elapsed_ms "$single_started" "$single_finished")"

batch_started=$(monotonic_ns)
LEAN_PATH="$lean_path" LEAN_NUM_THREADS=1 "$batch_probe" "$batch_manifest"
batch_finished=$(monotonic_ns)
printf 'phase.batch_process_wall_ms=%s\n' "$(elapsed_ms "$batch_started" "$batch_finished")"

concurrent_started=$(monotonic_ns)
LEAN_PATH="$lean_path" LEAN_NUM_THREADS="$concurrency" \
  "$concurrency_probe" "$concurrent_manifest" "$extractor"
concurrent_finished=$(monotonic_ns)
printf 'phase.concurrent_process_wall_ms=%s\n' \
  "$(elapsed_ms "$concurrent_started" "$concurrent_finished")"

if ((concurrency > 1)); then
  control_concurrency=$((concurrency / 2))
  control_started=$(monotonic_ns)
  LEAN_PATH="$lean_path" LEAN_NUM_THREADS="$control_concurrency" \
    "$concurrency_probe" "$concurrent_manifest" "$extractor"
  control_finished=$(monotonic_ns)
  printf 'phase.concurrent_control_process_wall_ms=%s\n' \
    "$(elapsed_ms "$control_started" "$control_finished")"
fi

while IFS=$'\t' read -r _module_name module_file batch_output; do
  item=${module_file%/module.olean}
  cmp "$item/single.json" "$batch_output"
  cmp "$item/single.json" "$item/concurrent.json"
done <"$manifest"

printf 'batch_result=%s\n' "$result_root"
