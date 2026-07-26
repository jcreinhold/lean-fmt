#!/usr/bin/env bash
# Shim: the lsp suite is the compiled `suite-lsp` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-lsp >&2
exec .lake/build/bin/suite-lsp "$@"
