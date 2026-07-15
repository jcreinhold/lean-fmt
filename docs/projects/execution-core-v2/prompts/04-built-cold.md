---
claim_id: ECV2-BUILT-COLD
status: planned
depends_on: [ECV2-WORKLOADS]
role: api-audit
---

# Minimize exact cold time on an ordinarily built project

## Task

Find the fastest exact path when project `.olean`s are current but no formatter artifact or cache
exists. Sub-ten-minute mathlib is the goal; every meaningful improvement is retained even if current
Lean cannot yet reach it.

## Read

- The import-only 62-file lower bound and `Mathlib.lean` union measurement.
- Lean `ImportState`, `importModulesCore`, `finalizeImport`, `EnvironmentHeader.moduleData`, persistent
  extensions, initializers, compacted regions, incremental snapshots, and compiler setup artifacts.

## Target

- Compare fresh exact children, exact-context grouping, parser-only environment construction,
  shared module-region/exact-environment views, and existing compiler artifacts.
- Prototype the deepest feasible pure Lean primitive; measure it on the fixed sample and mathlib.
- If an exact shared parser environment requires a Lean API change, write the smallest upstream API
  and invariants, including initializer isolation and module ordering, and retain a compiling prototype
  where possible.
- Record the best ordinary-built cold time. Falling short of ten minutes is honest evidence, not a
  reason to introduce superset grammar or exceed the memory envelope.

## Stop

Reject union/superset parsing, final-file grammar used retroactively, unsafe region release with live
extensions, and concurrency whose configured or measured aggregate can exceed 8 GiB.

## Check

- Byte-compare optimized syntax/results with fresh exact frontend runs, including adversarial syntax.
- Record end-to-end improvement, not only microbenchmarks.
- `lake build`
- `git diff --check`
