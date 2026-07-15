#!/usr/bin/env bash
# Run the workspace test suite.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo test --workspace
scripts/check-boundary.sh
