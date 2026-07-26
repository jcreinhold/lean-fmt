#!/usr/bin/env bash
# Shim: the check suite is the compiled `suite-check` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-check >&2
exec .lake/build/bin/suite-check "$@"
