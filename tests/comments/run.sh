#!/usr/bin/env bash
# Shim: the comments suite is the compiled `suite-comments` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build suite-comments >&2
exec .lake/build/bin/suite-comments "$@"
