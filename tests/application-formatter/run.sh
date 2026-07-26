#!/usr/bin/env bash
# Shim: the application-formatter suite is the compiled `suite-application-formatter` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build suite-application-formatter >&2
exec .lake/build/bin/suite-application-formatter "$@"
