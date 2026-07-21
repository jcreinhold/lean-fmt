#!/usr/bin/env bash
set -euo pipefail

# `ruff-19` RPR-IMPL. The two-session concurrency test, under the roadmap's adoption rule.
#
# `roadmap.md` line 19: "Test exactly one-worker/one-thread first, then at most two isolated sessions
# only if it improves end-to-end release time by at least 20% within 8 GiB, normal pressure, and
# 256 MiB swap."
#
# So this is a decision procedure, not an optimization. It measures one thing: does splitting a
# corpus across two concurrent `lean-fmt` processes beat one process doing all of it by >=20%?
#
#   arm A  one process over all N files, wall = its own
#   arm B  two processes over N/2 files each, started together, wall = max of the two
#
# Both arms run warm, and the cache is re-primed before every repetition so that both arms start
# from the same full-hit state. That is deliberate: it isolates the timing question from the
# *clobbering* question, which is a separate finding recorded in `results/02-optimize.md` -- two
# sessions publishing the same project index is atomic and safe (`writeIndexAtomic` renames a
# pid-and-nonce-unique temporary) but last-writer-wins, so a concurrent pair leaves a cache holding
# roughly half of what it should.
#
# Peak RSS is aggregate across the arm's processes, which is what the 8 GiB stop rule governs.

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

binary=$repo_root/.lake/build/bin/lean-fmt
manifest=${1:-$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt}
project_root=${2:-/Users/jcreinhold/Code/mathlib4}
repetitions=${3:-3}

if [[ ! -x $binary ]]; then
  printf 'build lean-fmt first: LEAN_NUM_THREADS=1 lake build\n' >&2
  exit 2
fi
if [[ ! -d $project_root ]]; then
  printf 'project root does not exist: %s\n' "$project_root" >&2
  exit 2
fi

files=()
while IFS= read -r relative_path; do
  [[ -z $relative_path ]] || files+=("$project_root/$relative_path")
done <"$manifest"

count=${#files[@]}
half=$((count / 2))
left=("${files[@]:0:half}")
right=("${files[@]:half}")

printf 'manifest %s\n' "$manifest"
printf 'files    %d  (split %d / %d)\n' "$count" "${#left[@]}" "${#right[@]}"
printf 'binary   %s\n\n' "$binary"

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
swap_used_mib() { sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p'; }

# One run of the binary over the given files, reporting peak RSS in BYTES on stdout --
# `/usr/bin/time -l` on macOS prints the maximum resident set size in bytes, not KiB.
run_one() {
  local rss_file=$1
  shift
  /usr/bin/time -l "$binary" check --output-format concise --root "$project_root" "$@" \
    >/dev/null 2>"$rss_file" || true
  grep 'maximum resident set size' "$rss_file" | awk '{print $1}'
}

prime() {
  "$binary" check --output-format concise --root "$project_root" "${files[@]}" >/dev/null 2>&1 || true
}

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

printf '%-6s %-4s %10s %14s %10s\n' arm rep wall_ms peak_rss_b swap_mib
for rep in $(seq 1 "$repetitions"); do
  prime
  swap_before=$(swap_used_mib)
  started=$(now_ms)
  a_rss=$(run_one "$scratch/a.err" "${files[@]}")
  a_wall=$(($(now_ms) - started))
  printf '%-6s %-4s %10s %14s %10s\n' A "$rep" "$a_wall" "$a_rss" \
    "$(python3 -c "print(round($(swap_used_mib) - $swap_before, 1))")"

  prime
  swap_before=$(swap_used_mib)
  started=$(now_ms)
  run_one "$scratch/b1.err" "${left[@]}" >"$scratch/b1.rss" &
  b1=$!
  run_one "$scratch/b2.err" "${right[@]}" >"$scratch/b2.rss" &
  b2=$!
  wait $b1 $b2
  b_wall=$(($(now_ms) - started))
  b_rss=$(($(cat "$scratch/b1.rss") + $(cat "$scratch/b2.rss")))
  printf '%-6s %-4s %10s %14s %10s\n' B "$rep" "$b_wall" "$b_rss" \
    "$(python3 -c "print(round($(swap_used_mib) - $swap_before, 1))")"
done

printf '\nAdoption needs arm B at most 0.80x arm A, aggregate peak RSS under 8 GiB (8589934592 B),\n'
printf 'normal pressure, and under 256 MiB of new swap. Read every column before deciding.\n'
