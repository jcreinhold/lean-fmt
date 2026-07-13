#!/usr/bin/env bash
# Lint the workspace with warnings denied.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo clippy --workspace --all-targets -- -D warnings
