#!/usr/bin/env bash
# Shim: the modes suite is the compiled `suite-modes` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-modes >&2
exec .lake/build/bin/suite-modes "$@"
