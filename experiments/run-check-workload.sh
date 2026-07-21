#!/usr/bin/env bash
set -euo pipefail

# One frozen workload run: the shipped binary over exactly the manifest's files.
#
# `profile-run.sh` requires that the command process exactly the sorted, duplicate-free manifest it
# was handed, and it has no way to check that — it only reads the manifest for metadata. This driver
# is how a `lean-fmt` run is made to satisfy that requirement literally: every path is passed as an
# explicit argument, so selection is the manifest and not whatever discovery happens to find today.
#
# Discovery-selected runs are a separate workload, not this one. Passing paths pins selection but
# also bypasses the discovery walk, so a run measured through here does not measure discovery on a
# large tree; `docs/projects/ruff-19-performance/evidence/01-workloads.md` records which frozen
# workload takes which route and why.

if (($# < 3)); then
  printf 'usage: %s BINARY PROJECT_ROOT SOURCE_MANIFEST [ARG...]\n' "$0" >&2
  exit 2
fi

binary=$1
project_root=$(cd "$2" && pwd)
manifest=$(cd "$(dirname "$3")" && pwd)/$(basename "$3")
shift 3

files=()
while IFS= read -r relative_path; do
  [[ -z $relative_path ]] || files+=("$project_root/$relative_path")
done <"$manifest"

exec "$binary" "$@" --root "$project_root" "${files[@]}"
