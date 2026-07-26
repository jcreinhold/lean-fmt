#!/usr/bin/env bash
# Shim: the semantic suite is the compiled `suite-semantic` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-semantic >&2
exec .lake/build/bin/suite-semantic "$@"
