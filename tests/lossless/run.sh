#!/usr/bin/env bash
# Shim: the lossless suite is the compiled `suite-lossless` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-lossless >&2
exec .lake/build/bin/suite-lossless "$@"
