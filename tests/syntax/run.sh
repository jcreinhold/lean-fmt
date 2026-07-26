#!/usr/bin/env bash
# Shim: the syntax suite is the compiled `suite-syntax` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build suite-syntax >&2
exec .lake/build/bin/suite-syntax "$@"
