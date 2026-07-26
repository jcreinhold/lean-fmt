#!/usr/bin/env bash
# Shim: the command-formatter suite is the compiled `suite-command-formatter` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build suite-command-formatter >&2
exec .lake/build/bin/suite-command-formatter "$@"
