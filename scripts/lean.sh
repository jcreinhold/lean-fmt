#!/usr/bin/env bash
# Build the LeanFmt capability package under its pinned toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${LEAN_NUM_THREADS:=1}"
export LEAN_NUM_THREADS
lake -d crates/lean-fmt/lean build
