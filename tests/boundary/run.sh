#!/usr/bin/env bash
# Shim: the boundary suite is the compiled `suite-boundary` executable now.
# Kept so `tests/run-all.sh` and muscle memory keep working until the orchestrator subsumes it.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build suite-boundary >&2
exec .lake/build/bin/suite-boundary "$@"
