#!/usr/bin/env bash
# Shim: the compiler facet suite is the compiled `suite-compiler` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-compiler >&2
exec .lake/build/bin/suite-compiler "$@"
