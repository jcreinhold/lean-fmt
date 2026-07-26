#!/usr/bin/env bash
# Shim: the module-formatter suite is the compiled `suite-module-formatter` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-module-formatter >&2
exec .lake/build/bin/suite-module-formatter "$@"
