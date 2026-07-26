#!/usr/bin/env bash
# Shim: the scale suite is the compiled `suite-scale` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-scale >&2
exec .lake/build/bin/suite-scale "$@"
