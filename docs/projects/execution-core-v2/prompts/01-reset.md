---
claim_id: ECV2-RESET
status: verified
depends_on: []
---

# Preserve the failed implementation before replacement

## Task

Preserve the complete pre-replacement work on `codex/archive-execution-core-attempt`, including the
60 GiB failure, and record its base revision and verification evidence.

## Target

- Archive commit `629d157694c9cbaa4dae29323db4711b9004ee39` contains the pre-reset tree.
- `notes/01-reset.md` and `evidence/01-baseline-checks.md` record the archive and baseline.

## Check

- Inspect the archive commit and recorded dirty-path inventory.
- Confirm the active branch can recover every archived file without carrying it in production.
