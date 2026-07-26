#!/usr/bin/env bash
# Shim: the reporting suite is the compiled `suite-reporting` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-reporting >&2
exec .lake/build/bin/suite-reporting "$@"
