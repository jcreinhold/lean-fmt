---
claim_id: ECV2-SERVE
status: planned
depends_on: [ECV2-SCALE]
---

# Add editor service after batch acceptance

## Task

Add the NDJSON editor service over the same private snapshot-analysis and validation primitive.

## Target

- Bounded FIFO requests, stale-version rejection, health, shutdown, malformed-request recovery, and
  no concurrent mutation of one exact Lean session.
- Service protocol types remain private and do not create a second parser/orchestrator.

## Check

- Differentially compare service and CLI results.
- Test busy, stale, malformed, failure, shutdown, and bounded-memory behavior.
- `lake build`
- `git diff --check`
