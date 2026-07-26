#!/usr/bin/env bash
# Shim: the format-suppression suite is the compiled `suite-format-suppression` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-format-suppression >&2
exec .lake/build/bin/suite-format-suppression "$@"
