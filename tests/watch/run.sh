#!/usr/bin/env bash
# Shim: the watch suite is the compiled `suite-watch` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-watch >&2
exec .lake/build/bin/suite-watch "$@"
