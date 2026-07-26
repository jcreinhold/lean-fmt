#!/usr/bin/env bash
# Shim: the suppression suite is the compiled `suite-suppression` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build suite-suppression >&2
exec .lake/build/bin/suite-suppression "$@"
