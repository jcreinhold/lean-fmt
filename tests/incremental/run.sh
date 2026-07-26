#!/usr/bin/env bash
# Shim: the incremental suite is the compiled `suite-incremental` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-incremental >&2
exec .lake/build/bin/suite-incremental "$@"
