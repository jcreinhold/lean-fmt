#!/usr/bin/env bash
# Shim: the formatter suite is the compiled `suite-formatter` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-formatter >&2
exec .lake/build/bin/suite-formatter "$@"
