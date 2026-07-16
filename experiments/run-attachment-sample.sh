#!/usr/bin/env bash
set -euo pipefail

# Comment attachment over the frozen 62-module mathlib sample.
#
# This is `RLC-FINAL`'s answer to the blocker `RLC-IMPL` recorded: until now the comment rule had never
# met code it did not anticipate. `tests/layout/run.sh` checks 18 modules, but they are *this project's
# own*, in a house style with no trailing comments at all — so every position that matters was covered
# only by fixtures written against the rule they test. This sample is the only corpus available that
# nobody wrote to suit the rule.
#
# The claim under test is the roadmap's "preserve every comment exactly once", and it is decidable
# rather than aspirational: `structurallyValid` independently guarantees the trivia runs tile
# `[headerStop, terminalStop)` exactly once, so `Comments.partitions` compares two independent walks.
#
# Complete mathlib is forbidden here and is not run: the sample is frozen at 62 modules by
# `experiments/workloads/mathlib-v4.32.0-sample.txt`, which `RLS-FINAL` already profiled.
#
# usage: run-attachment-sample.sh [MATHLIB_ROOT] [SOURCES] [RESULT_ROOT]

repo_root=$(cd "$(dirname "$0")/.." && pwd)
mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
result_root=${3:-"$repo_root/experiments/results/attachment-sample-$(date -u +%Y%m%dT%H%M%SZ)"}

application="$repo_root/.lake/build/bin/lean-fmt"
tests="$repo_root/.lake/build/bin/lean-fmt-tests"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$result_root"
cp "$sources" "$result_root/sources.txt"
measurements="$result_root/measurements.tsv"
printf 'path\tcomments\tleading\ttrailing\tdangling\theader_bytes\ttokens\n' >"$measurements"

cd "$mathlib_root"
while IFS= read -r source; do
  [[ -n "$source" ]] || continue
  setup="$scratch/setup.json"
  envelope="$scratch/envelope.json"

  LEAN_NUM_THREADS=1 lake setup-file "$source" >"$setup" 2>"$scratch/setup.err"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$setup" "$source" "$source" 8589934592 >"$envelope" 2>"$scratch/analyze.err"

  # A diagnostic means the module did not analyze, which is not an attachment failure. Record and move
  # on; the stop rule is about every *successful* projection.
  if ! python3 -c '
import json, sys
envelope = json.load(open(sys.argv[1]))
sys.exit(0 if envelope["artifact"] and not envelope["diagnostics"] else 1)' "$envelope"; then
    printf '%s\tanalysis-failed\n' "$source" >>"$result_root/failures.txt"
    continue
  fi

  # `attach-report` fails the process if `partitions` is false, so a non-zero exit here *is* the stop
  # rule firing on real code.
  if ! report=$("$tests" attach-report "$envelope" "$mathlib_root/$source" 2>&1); then
    printf '%s\t%s\n' "$source" "$report" >>"$result_root/failures.txt"
    continue
  fi

  python3 - "$source" "$report" <<'PY' >>"$measurements"
import sys
path, report = sys.argv[1:3]
f = dict(pair.split("=") for pair in report.split())
print("\t".join([path, f["comments"], f["leading"], f["trailing"], f["dangling"],
                 f["header_bytes"], f["tokens"]]))
PY
done <"$result_root/sources.txt"

python3 - "$measurements" "$result_root" <<'PY' | tee "$result_root/summary.txt"
import csv, sys

rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
if not rows:
    sys.exit("the sample produced no measurements")

def total(name):
    return sum(int(row[name]) for row in rows)

failures = 0
try:
    failures = sum(1 for _ in open(sys.argv[2] + "/failures.txt"))
except FileNotFoundError:
    pass

modules_with_trailing = sum(1 for row in rows if int(row["trailing"]) > 0)
modules_with_dangling = sum(1 for row in rows if int(row["dangling"]) > 0)

print(f"modules={len(rows)} failures={failures} tokens={total('tokens')}")
print(f"comments={total('comments')} leading={total('leading')} "
      f"trailing={total('trailing')} dangling={total('dangling')}")
print(f"modules_with_trailing={modules_with_trailing} modules_with_dangling={modules_with_dangling}")
PY

printf 'results in %s\n' "$result_root"
