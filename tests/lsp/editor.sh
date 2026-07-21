#!/usr/bin/env bash
set -euo pipefail

# The editor check. `run.sh` and `acceptance.sh` drive the protocol; this drives a real
# editor's client against it, which is the one thing neither of them can do.
#
# It needs Neovim 0.11 or newer on PATH, so it is not in the `tests/*/run.sh` sweep and
# skips rather than fails when Neovim is absent. `editor.lua` holds the checks.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

if ! command -v nvim >/dev/null 2>&1; then
  echo "lean-fmt editor check SKIPPED (no nvim on PATH)"
  exit 0
fi

version=$(nvim --version | head -1 | sed -E 's/^NVIM v([0-9]+)\.([0-9]+).*/\1 \2/')
major=${version% *}
minor=${version#* }
if [ "$major" -eq 0 ] && [ "$minor" -lt 11 ]; then
  echo "lean-fmt editor check SKIPPED (nvim $major.$minor, needs 0.11+ for vim.lsp.config)"
  exit 0
fi

LEAN_NUM_THREADS=1 lake build lean-fmt

# `--clean -u NONE` so the developer's own configuration cannot decide the result.
nvim --headless --clean -u NONE -l tests/lsp/editor.lua

echo "lean-fmt language server editor check passed"
