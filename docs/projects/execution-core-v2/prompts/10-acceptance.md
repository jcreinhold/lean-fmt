---
claim_id: ECV2-ACCEPTANCE
status: planned
depends_on: [ECV2-SERVE]
---

# Run whole-system acceptance

## Task

Verify the exact two-binary system from clean build through command-line modes, cache, long-lived
service, mathlib-scale execution, memory enforcement, and packaging. Capture reproducible evidence
and update documentation only to measured behavior.

## Read

- All prior result notes and evidence.
- `README.md`, `AGENTS.md`, usage/performance documentation, and release scripts.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/20-designing-for-performance.md`.
- `~/.codex/plugins/cache/lean-rs-skills/lean-rs-skills/0.1.1/skills/optimizing-lean-performance/SKILL.md`.

## Target

- `docs/projects/execution-core-v2/evidence/10-acceptance.md` records revision, exact toolchain,
  commands, file counts, wall time, trace epochs, child rotations, peak process-tree RSS, exits,
  and failures.
- A fresh `lean-fmt check` over `~/Code/mathlib4` completes in a reasonable measured time and never
  exceeds 8 GiB aggregate RSS; the cached repeat creates no child.
- Command reports include every selected file and match oracle samples.
- Documentation describes the two binaries, exact ordered context, reuse, coarse trace epoch,
  memory guarantee, modes, and service without promising unmeasured behavior.

## Stop

Do not accept a run against a different toolchain or incomplete file selection. Do not omit failed
files from timing. Do not weaken the oracle or memory bound to make acceptance pass.

## Check

- Build from clean state, run command-mode golden tests, service tests, cold mathlib check, warm
  cached check, and process-tree RSS monitoring.
- Confirm workspace membership and native linking again.
- `scripts/fmt.sh`
- `scripts/lint.sh`
- `scripts/test.sh`
- `scripts/lean.sh`
- `git diff --check`
