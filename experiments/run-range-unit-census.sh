#!/usr/bin/env bash
set -euo pipefail

# How often does range expansion have to extend forward? — `RSF-FINAL` census.
#
# `notes/01-stream-range.md` §4 derives the expansion rule from a property of `Doc.fits`: because
# `fits` walks the *tail* of the work list, a group at the end of a layout unit can be rebroken by
# whatever follows it, and exactly one construct stops that walk — a `verbatim` holding a newline. So a
# range whose last selected unit does not end at a line boundary must keep extending, or it rewrites
# bytes it reported as untouched.
#
# `RSF-IMPL` measured that on a synthetic `Doc` and pinned it with a selection test, but never counted
# it on real Lean. This does. For each module it renders once through the product's own
# `Printer.formatWithMap` and asks, of the units that have something after them, how many end in
# anything but a newline. That count is the number of unit boundaries at which the forward extension
# fires; zero would mean the clause is unreachable on idiomatic source and the test is the only thing
# holding it up.
#
# The corpus is the frozen mathlib sample, for the reason `run-printer-sample.sh` gives: this
# repository is source I wrote and already formatted the way the layouts format it, so it cannot answer
# a question about how people actually write. Complete mathlib is forbidden; this is the frozen sample
# only.
#
# usage: run-range-unit-census.sh [MATHLIB_ROOT] [SOURCES] [OUT]

repo_root=$(cd "$(dirname "$0")/.." && pwd)
mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
out=${3:-"$repo_root/experiments/evidence/03-range-unit-census.txt"}

application="$repo_root/.lake/build/bin/lean-fmt"
tests="$repo_root/.lake/build/bin/lean-fmt-tests"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

for binary in "$application" "$tests"; do
  if [[ ! -x $binary ]]; then
    printf 'missing %s; run `LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests` first\n' \
      "$binary" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$out")"
report="$scratch/report"
: >"$report"

analyzed=0
skipped=0
total_units=0
total_extending=0
modules_with_extension=0

field() { printf '%s' "$2" | tr ' ' '\n' | sed -n "s/^$1=\([0-9]*\)$/\1/p"; }

cd "$mathlib_root"
while read -r source; do
  [[ -n $source ]] || continue
  setup="$scratch/setup.json"

  if ! LEAN_NUM_THREADS=1 lake setup-file "$source" >"$setup" 2>"$scratch/err"; then
    skipped=$((skipped + 1))
    printf 'skipped\t%s\tsetup-file failed\n' "$source" >>"$report"
    continue
  fi
  if ! LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$setup" "$source" "$source" 8589934592 >"$scratch/env.json" 2>"$scratch/err"; then
    skipped=$((skipped + 1))
    printf 'skipped\t%s\tanalyze failed\n' "$source" >>"$report"
    continue
  fi
  if ! line=$("$tests" range-units "$scratch/env.json" "$source" 80 2>"$scratch/err"); then
    skipped=$((skipped + 1))
    printf 'skipped\t%s\t%s\n' "$source" "$(tail -1 "$scratch/err")" >>"$report"
    continue
  fi

  units=$(field units "$line")
  extending=$(field extending "$line")
  analyzed=$((analyzed + 1))
  total_units=$((total_units + units))
  total_extending=$((total_extending + extending))
  [[ $extending -eq 0 ]] || modules_with_extension=$((modules_with_extension + 1))
  printf 'ok\t%s\t%s\n' "$source" "$line" >>"$report"
done <"$sources"

{
  printf '# range unit census — RSF-FINAL\n'
  printf '# corpus: %s\n' "$sources"
  printf '# width: 80\n'
  printf 'analyzed=%s skipped=%s\n' "$analyzed" "$skipped"
  printf 'units=%s extending=%s modules_with_extension=%s\n' \
    "$total_units" "$total_extending" "$modules_with_extension"
  printf '\n'
  cat "$report"
} >"$out"

printf 'analyzed=%s skipped=%s units=%s extending=%s modules_with_extension=%s\n' \
  "$analyzed" "$skipped" "$total_units" "$total_extending" "$modules_with_extension"
printf 'wrote %s\n' "$out"
