#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
	printf 'usage: %s <full|import> MATHLIB_ROOT SOURCE_MANIFEST\n' "$0" >&2
	exit 2
fi

mode=$1
mathlib_root=$2
manifest=$3
repo_root=$(cd "$(dirname "$0")/.." && pwd)
experiment_root="$repo_root/experiments/pure-lean-core"
files=()
while IFS= read -r relative_path; do
	[[ -z "$relative_path" ]] || files+=("$mathlib_root/$relative_path")
done <"$manifest"

cd "$experiment_root"
case "$mode" in
full)
	exec lake exe pure-lean-core "$mathlib_root" "${files[@]}"
	;;
import)
	exec lake exe pure-lean-analyze --import-only "$mathlib_root" "${files[@]}"
	;;
*)
	printf 'unknown mode: %s\n' "$mode" >&2
	exit 2
	;;
esac
