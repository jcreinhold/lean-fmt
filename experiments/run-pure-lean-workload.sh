#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
	printf 'usage: %s <oracle|full|import|groups|setup-audit> PROJECT_ROOT SOURCE_MANIFEST\n' "$0" >&2
	exit 2
fi

mode=$1
mathlib_root=$(cd "$2" && pwd)
manifest=$(cd "$(dirname "$3")" && pwd)/$(basename "$3")
repo_root=$(cd "$(dirname "$0")/.." && pwd)
experiment_root="$repo_root/experiments/pure-lean-core"
files=()
while IFS= read -r relative_path; do
	[[ -z "$relative_path" ]] || files+=("$mathlib_root/$relative_path")
done <"$manifest"

cd "$experiment_root"
case "$mode" in
oracle)
	result=0
	for relative_path in "${files[@]}"; do
		relative_path=${relative_path#"$mathlib_root/"}
		setup_file=$(mktemp)
		printf 'source=%s\n' "$mathlib_root/$relative_path"
		if (cd "$mathlib_root" && lake setup-file "$relative_path" >"$setup_file" &&
			lake env lean --setup="$setup_file" "$relative_path"); then
			printf 'oracle_status=ok\n'
		else
			printf 'oracle_status=error\n'
			result=1
		fi
		rm -f "$setup_file"
	done
	exit "$result"
	;;
full)
	exec lake exe pure-lean-core "$mathlib_root" "${files[@]}"
	;;
import)
	exec lake exe pure-lean-analyze --import-only "$mathlib_root" "${files[@]}"
	;;
groups)
	exec lake exe header-groups "$mathlib_root" "$manifest"
	;;
setup-audit)
	exec lake exe setup-audit "$mathlib_root" "$manifest"
	;;
*)
	printf 'unknown mode: %s\n' "$mode" >&2
	exit 2
	;;
esac
