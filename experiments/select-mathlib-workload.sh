#!/usr/bin/env bash
set -euo pipefail

mathlib_root=${1:-"$HOME/Code/mathlib4"}
selection=${2:-full}

expected_revision=783ccda4ee524f13cc5636237be0a1942bc04824
expected_toolchain=leanprover/lean4:v4.32.0
expected_file_count=8795
expected_sample_count=62
expected_sample_digest=1936bdb60e01c14fdc986a535ef9317d63775506708e35f4155a9c4c5c6eeeef

actual_revision=$(git -C "$mathlib_root" rev-parse HEAD)
actual_toolchain=$(<"$mathlib_root/lean-toolchain")
if [[ "$actual_revision" != "$expected_revision" ]]; then
	printf 'mathlib revision mismatch: expected %s, got %s\n' \
		"$expected_revision" "$actual_revision" >&2
	exit 2
fi
if [[ "$actual_toolchain" != "$expected_toolchain" ]]; then
	printf 'mathlib toolchain mismatch: expected %s, got %s\n' \
		"$expected_toolchain" "$actual_toolchain" >&2
	exit 2
fi

case "$selection" in
full)
	find "$mathlib_root" -path '*/.lake' -prune -o -type f -name '*.lean' -print |
		LC_ALL=C sort |
		sed "s#^$mathlib_root/##"
	;;
sample)
	find "$mathlib_root/Mathlib" "$mathlib_root/Archive" \
		"$mathlib_root/Counterexamples" -type f -name '*.lean' -print |
		LC_ALL=C sort |
		awk 'NR % 137 == 1' |
		sed "s#^$mathlib_root/##"
	;;
*)
	printf 'usage: %s [MATHLIB_ROOT] [full|sample]\n' "$0" >&2
	exit 2
	;;
esac |
awk -v selection="$selection" \
	-v expected_full="$expected_file_count" \
	-v expected_sample="$expected_sample_count" \
	-v expected_digest="$expected_sample_digest" '
  { lines[NR] = $0 }
  END {
    expected = selection == "full" ? expected_full : expected_sample
    if (NR != expected) {
      printf "workload count mismatch: expected %d, got %d\n", expected, NR > "/dev/stderr"
      exit 2
    }
    for (i = 1; i <= NR; i++) print lines[i]
  }
' |
if [[ "$selection" == sample ]]; then
	tmp=$(mktemp)
	trap 'rm -f "$tmp"' EXIT
	tee "$tmp"
	digest=$(shasum -a 256 "$tmp" | awk '{print $1}')
	if [[ "$digest" != "$expected_sample_digest" ]]; then
		printf 'sample digest mismatch: expected %s, got %s\n' \
			"$expected_sample_digest" "$digest" >&2
		exit 2
	fi
else
	cat
fi
