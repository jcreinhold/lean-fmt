#!/usr/bin/env bash
# Shim: the stream suite is the compiled `suite-stream` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-stream >&2
exec .lake/build/bin/suite-stream "$@"
