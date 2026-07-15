---
kind: state
first_unresolved: 02-oracle
---

# Current state

The clean two-binary foundation is verified. Execution continues with the exact semantic oracle and
measurement contract.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-reset | ECV2-RESET | verified | — |
| 02-oracle | ECV2-ORACLE | planned | ECV2-RESET |
| 03-design | ECV2-DESIGN | planned | ECV2-ORACLE |
| 04-check | ECV2-CHECK | planned | ECV2-DESIGN |
| 05-reuse | ECV2-REUSE | planned | ECV2-CHECK |
| 06-scale | ECV2-SCALE | planned | ECV2-REUSE |
| 07-cache | ECV2-CACHE | planned | ECV2-SCALE |
| 08-modes | ECV2-MODES | planned | ECV2-CACHE |
| 09-serve | ECV2-SERVE | planned | ECV2-MODES |
| 10-acceptance | ECV2-ACCEPTANCE | planned | ECV2-SERVE |
| 11-final | ECV2-FINAL | planned | ECV2-ACCEPTANCE |

## Blockers

None recorded. ECV2-ORACLE must freeze exact semantics and the measurable workload before the Rust
execution path is optimized.

## Verification convention

A claim becomes verified only after its prompt-specific checks pass and their meaningful output is
recorded under `evidence/` or `results/`. State is coordination metadata, not evidence. A failed or
unreproduced command reopens the owning claim.
