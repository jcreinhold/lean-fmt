---
claim_id: ECV2-SCALE
status: planned
depends_on: [ECV2-MODES]
---

# Optimize and accept mathlib-scale execution

## Task

Measure and optimize all three relevant mathlib paths: ordinarily built with formatter cache cold,
formatter-integrated artifacts present with result cache cold, and result cache warm.

## Target

- Ordinary-built cold aims below ten minutes and records the best exact time even if an upstream Lean
  limitation remains; every retained optimization must improve end-to-end time or simplify design.
- Formatter-integrated cache-cold completes below ten minutes; cache-warm completes below 30 seconds.
- Every run covers all 8,795 files, stays at or below 8 GiB aggregate RSS, normal pressure, and 256 MiB
  swap growth, with no crash, abort, or missing file.
- Evidence names machine, revisions, toolchain, build/artifact/cache states, wall time, peak RSS,
  pressure, swap delta, and output digest.

## Stop

Do not improve timing by weakening exactness, omitting files, hiding prerequisite compilation, or
raising the memory envelope.

## Check

- Run three release-equivalent trials for each path.
- Differentially sample every optimized path against fresh exact frontend results.
- `lake build`
- `git diff --check`
