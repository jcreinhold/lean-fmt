#!/usr/bin/env bash
# Shim: the collection-formatter suite is the compiled `suite-collection-formatter` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build suite-collection-formatter >&2
exec .lake/build/bin/suite-collection-formatter "$@"
