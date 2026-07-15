---
claim_id: ECV2-CHECK
status: planned
depends_on: [ECV2-DESIGN]
---

# Implement exact check end to end

## Task

Implement `lean-fmt check` over the selected design with exact Lake workspace/toolchain discovery,
deterministic file selection, artifact use, and bounded exact fallback. Check never writes source.

## Target

- Native Lean CLI and private application modules under `LeanFmt`.
- Complete path-sorted reports; syntax failures are file results and infrastructure failures are
  aggregated without dropping unrelated files.
- Exit 0 for clean, 1 for findings/broken files, and 2 for infrastructure failure.
- Text and JSON reports are stable and byte-equivalent across execution paths.

## Stop

Do not add other product modes or duplicate the semantic analyzer.

## Check

- End-to-end tests cover clean, findings, malformed header, unresolved import, custom syntax, stale
  artifact, worker abort, resource exhaustion, and deterministic output.
- Verify source contents and mtimes are unchanged.
- `lake build`
- `lake exe lean-fmt -- check --help`
- `git diff --check`
