#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: profile-run.sh --name NAME --project-root ROOT --build-state STATE
  --cache-state STATE --sources FILE [--output-dir DIR] -- COMMAND [ARG...]

The command must process exactly the sorted, duplicate-free source manifest. It may emit
`phase.<name>_ms=<integer>` and `cache.<name>=<integer>` lines; those lines are retained separately
as phase evidence.
EOF
}

name=
project_root=
build_state=
cache_state=
sources=
output_dir=
rss_limit_kib=${LEAN_FMT_PROFILE_RSS_LIMIT_KIB:-8388608}
swap_limit_kib=${LEAN_FMT_PROFILE_SWAP_LIMIT_KIB:-262144}
pressure_limit=${LEAN_FMT_PROFILE_PRESSURE_LEVEL_MAX:-1}

while (($#)); do
  case "$1" in
  --name)
    name=${2:-}
    shift 2
    ;;
  --project-root)
    project_root=${2:-}
    shift 2
    ;;
  --build-state)
    build_state=${2:-}
    shift 2
    ;;
  --cache-state)
    cache_state=${2:-}
    shift 2
    ;;
  --sources)
    sources=${2:-}
    shift 2
    ;;
  --output-dir)
    output_dir=${2:-}
    shift 2
    ;;
  --)
    shift
    break
    ;;
  *)
    usage
    exit 2
    ;;
  esac
done

if [[ -z $name || -z $project_root || -z $build_state ||
  -z $cache_state || -z $sources || $# -eq 0 ]]; then
  usage
  exit 2
fi
if [[ ! -d $project_root || ! -f $sources ]]; then
  printf 'project root or source manifest does not exist\n' >&2
  exit 2
fi
if ! LC_ALL=C sort -c "$sources"; then
  printf 'source manifest must be bytewise path-sorted\n' >&2
  exit 2
fi
if [[ -n "$(LC_ALL=C uniq -d "$sources")" ]]; then
  printf 'source manifest contains duplicate paths\n' >&2
  exit 2
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
if [[ -z $output_dir ]]; then
  output_dir="$repo_root/experiments/results"
fi
mkdir -p "$output_dir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
prefix="$output_dir/$name-$stamp"
meta="$prefix.meta"
stdout_file="$prefix.stdout"
stderr_file="$prefix.stderr"
phases_file="$prefix.phases"

swap_used_kib() {
  sysctl -n vm.swapusage | awk '
    function kib(value, unit) {
      if (unit == "G") return int(value * 1024 * 1024)
      if (unit == "M") return int(value * 1024)
      if (unit == "K") return int(value)
      return int(value / 1024)
    }
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "used") {
          value = $(i + 2)
          unit = substr(value, length(value), 1)
          number = substr(value, 1, length(value) - 1)
          print kib(number, unit)
          exit
        }
      }
    }'
}

pressure_level() {
  sysctl -n kern.memorystatus_vm_pressure_level
}

command_text=$(printf '%q ' "$@")
command_text=${command_text% }
profile_binary=${LEAN_FMT_PROFILE_BINARY:-$1}
if [[ -f $profile_binary ]]; then
  profile_binary=$(cd "$(dirname "$profile_binary")" && pwd)/$(basename "$profile_binary")
  profile_binary_digest=$(shasum -a 256 "$profile_binary" | awk '{print $1}')
else
  profile_binary_digest=unavailable
fi
source_count=$(wc -l <"$sources" | tr -d ' ')
source_digest=$(shasum -a 256 "$sources" | awk '{print $1}')
swap_before_kib=$(swap_used_kib)
pressure_level_before=$(pressure_level)
pressure_before=$(memory_pressure -Q 2>/dev/null | tail -1 || true)
{
  printf 'schema=lean-fmt.profile.v1\n'
  printf 'name=%s\n' "$name"
  printf 'lean_fmt_revision=%s\n' "$(git -C "$repo_root" rev-parse HEAD)"
  printf 'project_root=%s\n' "$project_root"
  printf 'project_revision=%s\n' "$(git -C "$project_root" rev-parse HEAD)"
  printf 'lean_toolchain=%s\n' "$(<"$project_root/lean-toolchain")"
  printf 'build_state=%s\n' "$build_state"
  printf 'cache_state=%s\n' "$cache_state"
  printf 'source_manifest=%s\n' "$sources"
  printf 'source_count=%s\n' "$source_count"
  printf 'source_digest=%s\n' "$source_digest"
  printf 'machine=%s\n' "$(uname -a)"
  printf 'command=%s\n' "$command_text"
  printf 'binary=%s\n' "$profile_binary"
  printf 'binary_digest=%s\n' "$profile_binary_digest"
  printf 'rss_limit_kib=%s\n' "$rss_limit_kib"
  printf 'swap_limit_kib=%s\n' "$swap_limit_kib"
  printf 'pressure_level_limit=%s\n' "$pressure_limit"
  printf 'swap_before_kib=%s\n' "$swap_before_kib"
  printf 'pressure_level_before=%s\n' "$pressure_level_before"
  printf 'pressure_before=%s\n' "$pressure_before"
} >"$meta"

started_ns=$(python3 -c 'import time; print(time.monotonic_ns())')
LEAN_NUM_THREADS=1 perl -MPOSIX -e \
  'POSIX::setpgid(0, 0) or die "setpgid: $!"; exec @ARGV or die "exec: $!"' \
  "$@" >"$stdout_file" 2>"$stderr_file" &
pid=$!
peak_rss_kib=0
peak_pressure_level=$pressure_level_before
hard_stop=none

# Exact and artifact workers deliberately call `setsid`, so process-group membership is not a
# workload boundary. Follow the live parent relation instead; otherwise both the recorded peak and
# the 8 GiB stop omit precisely the frontend children this harness exists to measure.
process_tree() {
  ps -axo ppid=,pid=,rss= | awk -v root="$pid" -v field="$1" '
    {
      parent[$2] = $1
      rss[$2] = $3
      order[++n] = $2
    }
    END {
      included[root] = 1
      for (pass = 1; pass <= n; pass++)
        for (i = 1; i <= n; i++)
          if (included[parent[order[i]]]) included[order[i]] = 1
      for (i = 1; i <= n; i++)
        if (included[order[i]]) {
          if (field == "pids") printf "%s ", order[i]
          else total += rss[order[i]]
        }
      if (field != "pids") print total + 0
    }'
}

while kill -0 "$pid" 2>/dev/null; do
  rss_kib=$(process_tree rss)
  if ((rss_kib > peak_rss_kib)); then
    peak_rss_kib=$rss_kib
  fi
  current_swap_kib=$(swap_used_kib)
  swap_delta_kib=$((current_swap_kib - swap_before_kib))
  current_pressure_level=$(pressure_level)
  if ((current_pressure_level > peak_pressure_level)); then
    peak_pressure_level=$current_pressure_level
  fi
  if ((rss_kib >= rss_limit_kib)); then
    hard_stop=rss
  elif ((swap_delta_kib > swap_limit_kib)); then
    hard_stop=swap
  elif ((current_pressure_level > pressure_limit)); then
    hard_stop=pressure
  fi
  if [[ $hard_stop != none ]]; then
    # Kill escaped descendant sessions explicitly before the original process group. Pids come only
    # from the root's current ancestry, never from a name match or broad group guess.
    descendant_pids=$(process_tree pids)
    if [[ -n $descendant_pids ]]; then
      # shellcheck disable=SC2086 -- deliberate expansion of validated numeric pids
      kill -TERM $descendant_pids 2>/dev/null || true
    fi
    kill -TERM -- "-$pid" 2>/dev/null || true
    break
  fi
  sleep 0.25
done
set +e
wait "$pid"
status=$?
set -e
finished_ns=$(python3 -c 'import time; print(time.monotonic_ns())')
wall_ms=$(((finished_ns - started_ns) / 1000000))
swap_after_kib=$(swap_used_kib)
swap_delta_kib=$((swap_after_kib - swap_before_kib))
pressure_level_after=$(pressure_level)
pressure_after=$(memory_pressure -Q 2>/dev/null | tail -1 || true)
output_digest=$(shasum -a 256 "$stdout_file" | awk '{print $1}')
# `cache.<name>=<count>` lines are retained alongside `phase.<name>_ms`. Wall time cannot separate
# "the cache served the run" from "the page cache was warm" — the confound that made `ruff-16` read a
# whole-project invalidation as an in-process reuse defect (`ruff-16b` `RCI-SPEC`). A profile that
# keeps the timings and drops the counts preserves exactly that ambiguity, so both channels are
# evidence here.
{
  grep -E '^(phase\.[A-Za-z0-9_.-]+_ms|cache\.[A-Za-z0-9_.-]+)=[0-9]+$' "$stdout_file" || true
  grep -E '^(phase\.[A-Za-z0-9_.-]+_ms|cache\.[A-Za-z0-9_.-]+)=[0-9]+$' "$stderr_file" || true
} >"$phases_file"
{
  printf 'exit_status=%s\n' "$status"
  printf 'hard_stop=%s\n' "$hard_stop"
  printf 'wall_ms=%s\n' "$wall_ms"
  printf 'peak_rss_kib=%s\n' "$peak_rss_kib"
  printf 'swap_after_kib=%s\n' "$swap_after_kib"
  printf 'swap_delta_kib=%s\n' "$swap_delta_kib"
  printf 'peak_pressure_level=%s\n' "$peak_pressure_level"
  printf 'pressure_level_after=%s\n' "$pressure_level_after"
  printf 'pressure_after=%s\n' "$pressure_after"
  printf 'output_digest=%s\n' "$output_digest"
  printf 'stdout=%s\n' "$stdout_file"
  printf 'stderr=%s\n' "$stderr_file"
  printf 'phases=%s\n' "$phases_file"
} >>"$meta"

printf '%s\n' "$meta"
if [[ $hard_stop != none ]]; then
  exit 137
fi
exit "$status"
