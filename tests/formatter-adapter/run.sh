#!/usr/bin/env bash
# Shim: the formatter-adapter suite is the compiled `suite-formatter-adapter` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-formatter-adapter >&2
exec .lake/build/bin/suite-formatter-adapter "$@"
