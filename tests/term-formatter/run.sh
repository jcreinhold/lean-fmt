#!/usr/bin/env bash
# Shim: the term-formatter suite is the compiled `suite-term-formatter` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build suite-term-formatter >&2
exec .lake/build/bin/suite-term-formatter "$@"
