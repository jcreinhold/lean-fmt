#!/usr/bin/env bash
# Shim: the discovery suite is the compiled `suite-discovery` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-discovery >&2
exec .lake/build/bin/suite-discovery "$@"
