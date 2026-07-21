#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
mathlib_root=${MATHLIB_ROOT:-"$HOME/Code/mathlib4"}
limit_kib=${LEAN_FMT_EXPERIMENT_RSS_LIMIT_KIB:-8388608}
result_dir="$repo_root/experiments/lean-native/results"
mkdir -p "$result_dir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
output="$result_dir/import-probe-$stamp.tsv"
meta="$result_dir/import-probe-$stamp.meta"

mapfile_cmd=()
while IFS= read -r file; do
  [[ -z $file ]] || mapfile_cmd+=("$file")
done <"$repo_root/experiments/lean-native/mathlib-slice.txt"

before_swap=$(sysctl -n vm.swapusage)
before_pressure=$(memory_pressure -Q 2>/dev/null | tail -1 || true)
{
  printf 'lean_fmt_revision=%s\n' "$(git -C "$repo_root" rev-parse HEAD)"
  printf 'mathlib_revision=%s\n' "$(git -C "$mathlib_root" rev-parse HEAD)"
  printf 'lean_toolchain=%s\n' "$(<"$mathlib_root/lean-toolchain")"
  printf 'machine=%s\n' "$(uname -a)"
  printf 'rss_limit_kib=%s\n' "$limit_kib"
  printf 'swap_before=%s\n' "$before_swap"
  printf 'pressure_before=%s\n' "$before_pressure"
} >"$meta"

cd "$mathlib_root"
started=$(date +%s)
LEAN_NUM_THREADS=1 perl -MPOSIX -e \
  'POSIX::setpgid(0, 0) or die "setpgid: $!"; exec @ARGV or die "exec: $!"' \
  lake env lean --run "$repo_root/experiments/lean-native/ImportProbe.lean" \
  "${mapfile_cmd[@]}" >"$output" 2>>"$meta" &
pid=$!
peak=0
stopped=0
while kill -0 "$pid" 2>/dev/null; do
  rss=$(ps -axo pgid=,rss= | awk -v group="$pid" '$1 == group { total += $2 } END { print total + 0 }')
  if [[ $rss =~ ^[0-9]+$ ]]; then
    if ((rss > peak)); then
      peak=$rss
    fi
    if ((rss >= limit_kib)); then
      printf 'hard_stop_rss_kib=%s\n' "$rss" >>"$meta"
      kill -TERM -- "-$pid" 2>/dev/null || true
      stopped=1
      break
    fi
  fi
  sleep 0.25
done
set +e
wait "$pid"
status=$?
set -e
elapsed=$(($(date +%s) - started))
{
  printf 'exit_status=%s\n' "$status"
  printf 'hard_stopped=%s\n' "$stopped"
  printf 'wall_seconds=%s\n' "$elapsed"
  printf 'peak_rss_kib=%s\n' "$peak"
  printf 'swap_after=%s\n' "$(sysctl -n vm.swapusage)"
  printf 'pressure_after=%s\n' "$(memory_pressure -Q 2>/dev/null | tail -1 || true)"
  printf 'output=%s\n' "$output"
} >>"$meta"

printf '%s\n%s\n' "$meta" "$output"
if ((stopped)); then
  exit 137
fi
exit "$status"
