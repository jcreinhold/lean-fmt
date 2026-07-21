#!/usr/bin/env bash
set -euo pipefail

# `ruff-17` RLP-FINAL. `run.sh` is the suite; this is the acceptance run, and the difference is the
# client. `run.sh` drives the server from Python, which is independent of our Lean but is still a
# client we wrote. `Acceptance.lean` drives it with `Lean.Data.Lsp.Ipc` — the client the Lean team
# wrote to test Lean's own language server — so the framing, the message algebra, and the error-code
# decoder are all somebody else's.
#
# It is separate from `run.sh` because it costs minutes rather than seconds: the concurrent
# cancellation case formats a large module twice, and the stability case issues a hundred requests
# while sampling resident size. `results/04-acceptance.md` records the numbers.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)

lake env lean --run tests/lsp/Acceptance.lean "$application" "$repo_root"
