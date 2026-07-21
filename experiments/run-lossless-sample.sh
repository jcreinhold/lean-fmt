#!/usr/bin/env bash
set -euo pipefail

# Project every module in a frozen sample through the exact frontend, validate each projection with
# the independent oracle, and record what the new schema costs on real modules.
#
# This is `RLS-FINAL`'s size profile. Everything measured before it was a fixture under 1 KB, which
# supports no claim about a real file. Run it under `profile-run.sh`, which owns the RSS, swap, and
# pressure gates and kills the process group on breach.
#
# usage: run-lossless-sample.sh [MATHLIB_ROOT] [SOURCES] [RESULT_ROOT]

repo_root=$(cd "$(dirname "$0")/.." && pwd)
mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
result_root=${3:-"$repo_root/experiments/results/lossless-sample-$(date -u +%Y%m%dT%H%M%SZ)"}

application="$repo_root/.lake/build/bin/lean-fmt"
oracle="$repo_root/tests/lossless/check_projection.py"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$result_root"
cp "$sources" "$result_root/sources.txt"
timings="$result_root/measurements.tsv"
printf 'path\traw_bytes\tnormalized_bytes\ttokens\tnodes\tkinds\ttrivia_runs\ttail_bytes\tartifact_bytes\tsetup_ms\tanalyze_ms\n' \
  >"$timings"

monotonic_ns() { python3 -c 'import time; print(time.monotonic_ns())'; }
elapsed_ms() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", (b - a) / 1000000 }'; }

cd "$mathlib_root"
while IFS= read -r source; do
  [[ -n $source ]] || continue
  setup="$scratch/setup.json"
  envelope="$scratch/envelope.json"

  start=$(monotonic_ns)
  LEAN_NUM_THREADS=1 lake setup-file "$source" >"$setup" 2>"$scratch/setup.err"
  stop=$(monotonic_ns)
  setup_ms=$(elapsed_ms "$start" "$stop")

  start=$(monotonic_ns)
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$setup" "$source" "$source" 8589934592 >"$envelope" 2>"$scratch/analyze.err"
  stop=$(monotonic_ns)
  analyze_ms=$(elapsed_ms "$start" "$stop")

  # A diagnostic here means the module did not analyze, which is not a projection failure. The stop
  # rule is byte-identical reconstruction for every *successful* case, so record and move on.
  if ! python3 -c '
import json, sys
envelope = json.load(open(sys.argv[1]))
sys.exit(0 if envelope["artifact"] and not envelope["diagnostics"] else 1)' "$envelope"; then
    printf '%s\tanalysis-failed\n' "$source" >>"$result_root/failures.txt"
    continue
  fi

  # The oracle re-derives every claim from the artifact and the file alone. It is the whole point of
  # running a sample at all: a projection nobody can contradict is not evidence.
  measured=$(python3 "$oracle" --envelope "$envelope" "$mathlib_root/$source")
  artifact_bytes=$(python3 -c '
import json, sys
artifact = json.load(open(sys.argv[1]))["artifact"]
print(len(json.dumps(artifact, separators=(",", ":"))))' "$envelope")

  python3 - "$source" "$measured" "$artifact_bytes" "$setup_ms" "$analyze_ms" <<'PY' >>"$timings"
import sys
path, measured, artifact_bytes, setup_ms, analyze_ms = sys.argv[1:6]
fields = dict(pair.split("=") for pair in measured.split())
print("\t".join([
    path, fields["raw_bytes"], fields["normalized_bytes"], fields["tokens"], fields["nodes"],
    fields["kinds"], fields["trivia_runs"], fields["tail_bytes"], artifact_bytes,
    setup_ms, analyze_ms,
]))
PY
done <"$result_root/sources.txt"

python3 - "$timings" "$result_root" <<'PY' | tee "$result_root/summary.txt"
import csv, statistics, sys

rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
if not rows:
    sys.exit("the sample produced no measurements")


def column(name, cast=int):
    return [cast(row[name]) for row in rows]


source = column("normalized_bytes")
artifact = column("artifact_bytes")
tokens = column("tokens")
nodes = column("nodes")
analyze = column("analyze_ms", float)
ratio = [a / s for a, s in zip(artifact, source)]
# The claim under test is that the artifact is O(tokens + nodes), not O(source bytes). Ratio against
# source is what a reader reaches for, so report both and let the per-element cost carry the claim.
per_element = [a / (t + n) for a, t, n in zip(artifact, tokens, nodes)]

print(f"files={len(rows)}")
print(f"source_bytes_total={sum(source)}")
print(f"artifact_bytes_total={sum(artifact)}")
print(f"tokens_total={sum(tokens)}")
print(f"nodes_total={sum(nodes)}")
print(f"ratio_aggregate={sum(artifact) / sum(source):.3f}")
print(f"ratio_median={statistics.median(ratio):.3f}")
print(f"ratio_max={max(ratio):.3f}")
print(f"bytes_per_element_mean={statistics.mean(per_element):.2f}")
print(f"bytes_per_element_max={max(per_element):.2f}")
print(f"source_bytes_max={max(source)}")
print(f"artifact_bytes_max={max(artifact)}")
print(f"analyze_ms_total={sum(analyze):.1f}")
print(f"analyze_ms_median={statistics.median(analyze):.1f}")
print(f"analyze_ms_max={max(analyze):.1f}")
largest = max(rows, key=lambda row: int(row["artifact_bytes"]))
print(f"largest_artifact_path={largest['path']}")
print(f"phase.analyze_total_ms={int(sum(analyze))}")
PY

printf '%s\n' "$result_root"
