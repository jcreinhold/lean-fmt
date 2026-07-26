#!/usr/bin/env bash
# Shim: the block-formatter suite is the compiled `suite-block-formatter` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-block-formatter >&2
exec .lake/build/bin/suite-block-formatter "$@"
