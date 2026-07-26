#!/usr/bin/env bash
# Shim: the layout suite is the compiled `suite-layout` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-layout >&2
exec .lake/build/bin/suite-layout "$@"
