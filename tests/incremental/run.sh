#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

lake build lean-fmt-tests
lake setup-file tests/incremental/Fixture.lean >"$work/setup.json"
lake exe lean-fmt-tests incremental-analyzer \
  "$work/setup.json" tests/incremental/Fixture.lean | tee "$work/result.txt"

grep -Eq '^incremental updates=[0-9]+ reused=[1-9][0-9]* invalidated=[2-9][0-9]* failed=1 cancelled=1 rss_kib=#\[[0-9, ]+\] retained=1$' \
  "$work/result.txt"

printf 'tests/incremental: ok\n'
