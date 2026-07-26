#!/usr/bin/env bash
# Shim: the style suite is the compiled `suite-style` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-style >&2
exec .lake/build/bin/suite-style "$@"
