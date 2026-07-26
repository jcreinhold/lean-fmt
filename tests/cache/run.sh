#!/usr/bin/env bash
# Shim: the cache suite is the compiled `suite-cache` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-cache >&2
exec .lake/build/bin/suite-cache "$@"
