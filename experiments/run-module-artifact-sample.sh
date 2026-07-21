#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
result_root="$repo_root/experiments/results/module-artifact-sample-$stamp"
scratch=$(mktemp -d)
active_paths=()
active_backups=()

mkdir -p "$result_root"
cp "$sources" "$result_root/sources.txt"

restore_module_outputs() {
  local index
  for index in "${!active_paths[@]}"; do
    if [[ -e ${active_backups[$index]} ]]; then
      cp -p "${active_backups[$index]}" "${active_paths[$index]}"
    else
      rm -f "${active_paths[$index]}"
    fi
  done
  active_paths=()
  active_backups=()
}

cleanup() {
  status=$?
  restore_module_outputs
  if [[ $status -ne 0 ]]; then
    cp -R "$scratch" "$result_root/failure"
  fi
  rm -rf "$scratch"
  exit "$status"
}
trap cleanup EXIT

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build LeanFmtCompilerPlugin:shared artifactExtractor
LEAN_NUM_THREADS=1 lake -d experiments/pure-lean-core build LeanFmtProbePlugin:shared
plugin="$repo_root/.lake/build/lib/liblean_x2dfmt_LeanFmtCompilerPlugin.dylib"
oracle_plugin="$repo_root/experiments/pure-lean-core/.lake/build/lib/libpure_x2dlean_x2dcore_LeanFmtProbePlugin.dylib"
extractor="$repo_root/.lake/build/bin/lean-fmt-artifact-extract"
cd "$mathlib_root"
mathlib_lean_path=$(lake env printenv LEAN_PATH)

printf 'index\tpath\tfirst\tplain_ms\tplugin_ms\textract_ms\toracle_ms\tartifact_bytes\tolean_delta_bytes\n' \
  >"$result_root/timings.tsv"

monotonic_ns() {
  python3 -c 'import time; print(time.monotonic_ns())'
}

elapsed_ms() {
  awk -v start="$1" -v stop="$2" 'BEGIN { printf "%.3f", (stop - start) / 1000000 }'
}

index=0
while IFS= read -r source; do
  index=$((index + 1))
  if [[ -n ${LEAN_FMT_SAMPLE_LIMIT:-} && $index -gt $LEAN_FMT_SAMPLE_LIMIT ]]; then
    break
  fi
  case_dir="$scratch/$index"
  mkdir -p "$case_dir/original"
  setup="$case_dir/setup.json"

  cd "$mathlib_root"
  LEAN_NUM_THREADS=1 lake setup-file "$source" >"$setup"
  module_name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$setup")
  module_path=${module_name//./\/}
  canonical_olean="$mathlib_root/.lake/build/lib/lean/$module_path.olean"
  plugin_olean="$case_dir/plugin.olean"
  artifact="$case_dir/artifact.json"

  prepare_module_outputs() {
    local path backup suffix
    restore_module_outputs
    for suffix in "" ".private" ".server"; do
      path="$canonical_olean$suffix"
      backup="$case_dir/original/olean${suffix:-.main}"
      active_paths+=("$path")
      active_backups+=("$backup")
      if [[ -e $path ]]; then
        cp -p "$path" "$backup"
      fi
    done
    path="${canonical_olean%.olean}.ir"
    backup="$case_dir/original/module.ir"
    active_paths+=("$path")
    active_backups+=("$backup")
    if [[ -e $path ]]; then
      cp -p "$path" "$backup"
    fi
  }

  run_plain() {
    local start stop
    start=$(monotonic_ns)
    LEAN_NUM_THREADS=1 lake env lean -DElab.async=false --setup="$setup" \
      -o "$case_dir/plain.olean" "$source" >"$case_dir/plain.stdout" 2>"$case_dir/plain.stderr"
    stop=$(monotonic_ns)
    plain_ms=$(elapsed_ms "$start" "$stop")
  }

  run_plugin() {
    local start stop
    prepare_module_outputs
    start=$(monotonic_ns)
    LEAN_NUM_THREADS=1 lake env lean -DElab.async=false \
      --setup="$setup" --plugin="$plugin" -o "$canonical_olean" "$source" \
      >"$case_dir/plugin.stdout" 2>"$case_dir/plugin.stderr"
    stop=$(monotonic_ns)
    plugin_ms=$(elapsed_ms "$start" "$stop")
    cp -p "$canonical_olean" "$plugin_olean"
  }

  run_extract() {
    local start stop
    start=$(monotonic_ns)
    LEAN_PATH="$mathlib_lean_path" LEAN_NUM_THREADS=1 \
      "$extractor" "$module_name" "$canonical_olean" "$artifact" \
      >"$case_dir/extract.stdout" 2>"$case_dir/extract.stderr"
    stop=$(monotonic_ns)
    extract_ms=$(elapsed_ms "$start" "$stop")
    restore_module_outputs
  }

  run_oracle() {
    local start stop
    start=$(monotonic_ns)
    LEAN_FMT_PROBE_ARTIFACT="$case_dir/oracle.json" LEAN_NUM_THREADS=1 \
      lake env lean -DElab.async=false --setup="$setup" --plugin="$oracle_plugin" \
      -o "$case_dir/oracle.olean" "$source" \
      >"$case_dir/oracle.stdout" 2>"$case_dir/oracle.stderr"
    stop=$(monotonic_ns)
    oracle_ms=$(elapsed_ms "$start" "$stop")
  }

  if ((index % 2 == 1)); then
    first=plain
    run_plain
    run_plugin
  else
    first=plugin
    run_plugin
    run_plain
  fi
  run_extract
  run_oracle

  cmp "$case_dir/plain.olean" "$case_dir/oracle.olean"
  python3 - "$artifact" "$case_dir/oracle.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    artifact = json.load(stream)
with open(sys.argv[2]) as stream:
    oracle = json.load(stream)

# `RLS-IMPL` replaced the flat `commands`/`sourceBytes` projection with `LosslessSource`, so the
# command stream is now the root of each command's node tree: `collect` walks one command at a time
# with no parent, and widens each node to the hull of the leaves beneath it. That hull is what
# `Syntax.getRange?` returns, which is what the probe records — so the two must still agree
# command for command. The probe shares no module with `LeanFmt`, which is the point of comparing.
source = artifact["source"]
kinds, nodes = source["kinds"], source["nodes"]
actual = []
for kind, parent, start, stop in nodes:
    if parent is None:
        actual.append({"kind": kinds[kind], "start": start, "stop": stop})
assert actual == oracle["commands"], (actual, oracle["commands"])
assert source["normalizedBytes"] == oracle["source_bytes"]
PY

  artifact_bytes=$(wc -c <"$artifact" | tr -d ' ')
  plain_olean_bytes=$(wc -c <"$case_dir/plain.olean" | tr -d ' ')
  plugin_olean_bytes=$(wc -c <"$plugin_olean" | tr -d ' ')
  olean_delta_bytes=$((plugin_olean_bytes - plain_olean_bytes))
  printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$index" "$source" "$first" "$plain_ms" "$plugin_ms" "$extract_ms" "$oracle_ms" \
    "$artifact_bytes" "$olean_delta_bytes" >>"$result_root/timings.tsv"
  rm -rf "$case_dir"
done <"$result_root/sources.txt"

python3 - "$result_root/timings.tsv" >"$result_root/summary.txt" <<'PY'
import csv
import statistics
import sys

with open(sys.argv[1], newline="") as stream:
    rows = list(csv.DictReader(stream, delimiter="\t"))

plain = [float(row["plain_ms"]) for row in rows]
plugin = [float(row["plugin_ms"]) for row in rows]
oracle = [float(row["oracle_ms"]) for row in rows]
extract = [float(row["extract_ms"]) for row in rows]
sizes = [int(row["artifact_bytes"]) for row in rows]
olean_delta = [int(row["olean_delta_bytes"]) for row in rows]
delta = [instrumented - baseline for baseline, instrumented in zip(plain, plugin)]

print(f"files={len(rows)}")
print(f"plain_total_ms={sum(plain):.3f}")
print(f"plugin_total_ms={sum(plugin):.3f}")
print(f"oracle_total_ms={sum(oracle):.3f}")
print(f"extract_total_ms={sum(extract):.3f}")
print(f"extract_mean_ms={statistics.mean(extract):.3f}")
print(f"extract_median_ms={statistics.median(extract):.3f}")
print(f"paired_delta_total_ms={sum(delta):.3f}")
print(f"paired_delta_mean_ms={statistics.mean(delta):.3f}")
print(f"paired_delta_median_ms={statistics.median(delta):.3f}")
print(f"artifact_bytes_mean={statistics.mean(sizes):.1f}")
print(f"artifact_bytes_max={max(sizes)}")
print(f"olean_delta_bytes_mean={statistics.mean(olean_delta):.1f}")
print(f"olean_delta_bytes_max={max(olean_delta)}")
PY

printf '%s\n' "$result_root"
