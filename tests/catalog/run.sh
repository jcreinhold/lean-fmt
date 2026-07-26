#!/usr/bin/env bash
# Shim: the catalog suite is the compiled `suite-catalog` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-catalog >&2
exec .lake/build/bin/suite-catalog "$@"
