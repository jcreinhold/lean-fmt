#!/usr/bin/env bash
# Shim: the validator suite is the compiled `suite-validator` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-validator >&2
exec .lake/build/bin/suite-validator "$@"
