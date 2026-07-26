#!/usr/bin/env bash
# Shim: the declaration-formatter suite is the compiled `suite-declaration-formatter` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-declaration-formatter >&2
exec .lake/build/bin/suite-declaration-formatter "$@"
