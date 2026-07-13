#!/usr/bin/env bash
# Build the LeanFmt capability package under its pinned toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
lake -d lean build
