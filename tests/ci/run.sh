#!/usr/bin/env bash
# Shim: the ci suite is the compiled `suite-ci` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-ci >&2
exec .lake/build/bin/suite-ci "$@"
