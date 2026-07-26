#!/usr/bin/env bash
# Shim: the imports suite is the compiled `suite-imports` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-imports >&2
exec .lake/build/bin/suite-imports "$@"
