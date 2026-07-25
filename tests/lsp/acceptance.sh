#!/usr/bin/env bash
# Shim: the acceptance run is the compiled `suite-lsp-acceptance` executable now (an interpreted
# generic against compiled library code does not link, and a compiled client runs the same checks
# faster). Kept so muscle memory and docs keep working until the orchestrator subsumes it.
set -euo pipefail

cd "$(dirname "$0")/../.." || exit 1
exec lake exe suite-lsp-acceptance
