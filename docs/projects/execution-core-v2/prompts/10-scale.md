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
- Optimization iterations use the frozen representative sample and named worst-case files. Stop a
  run once it decisively rejects its hypothesis; do not finish a known-losing full workload.
- A release candidate advances to one complete 8,795-file acceptance run per relevant path only when
  sampled evidence projects that the path can satisfy its stated target. Each such acceptance run
  stays at or below 8 GiB aggregate RSS, normal pressure, and 256 MiB swap growth, with no crash,
  abort, or missing file.
- If the ordinary-built path remains implausible under its sampled evidence, record the best exact
  sample and upstream limitation without spending a full run merely to reproduce the projection.
- Evidence names machine, revisions, toolchain, build/artifact/cache states, wall time, peak RSS,
  pressure, swap delta, binary digest, and output digest.

## Stop

Do not improve timing by weakening exactness, omitting files, hiding prerequisite compilation, or
raising the memory envelope.

## Check

- Run paired representative-sample trials while optimizing and retain raw per-file timings.
- Run one monitored full acceptance per plausible release-candidate path. Reuse it while the binary,
  workload, toolchain, and relevant configuration digests remain unchanged.
- Differentially sample every optimized path against fresh exact frontend results.
- `lake build`
- `git diff --check`
