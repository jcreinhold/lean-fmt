#!/usr/bin/env bash
# Shim: the downstream suite is the compiled `suite-downstream` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-downstream >&2
exec .lake/build/bin/suite-downstream "$@"
