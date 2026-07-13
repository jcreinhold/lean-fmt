#!/usr/bin/env bash
# Check Rust formatting across the workspace.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo fmt --all -- --check
