---
claim_id: RCI-IMPL
status: planned
depends_on: [RCI-SPEC]
---

# Rekey entries on the import closure

## Task

Deliver **RCI-IMPL**: Implement the frozen identity in `LeanFmt.Cache`, expose from `LeanFmt.Project`
only what supplying the closure requires, land the mutation-checked stale-hit differential, and measure
one-file-edit invalidation at entry granularity.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- Implement the task behind the existing private intent-to-report architecture; keep CLI presentation in
  `LeanFmt.Cli` and lifecycle/cache/project complexity below callers.
- Add or update focused fixtures and persistent regression tests at the owning layer.
- Write `results/02-implementation.md` with exact commands, raw outputs or evidence locators,
  measurements, decisions changed during execution, and remaining uncertainty.
- Update `state/current.md` only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Narrow `environmentDigest?` to the non-project inputs it should have covered — dependency roots,
   search paths, toolchain, shared libraries — and move project-source coverage into per-entry identity
   as the frozen closure digest. `environment` must stop naming the index file on project content.
2. Supply the closure from `LeanFmt.Project`'s existing graph rather than re-resolving imports inside
   `Cache`. If the graph does not already carry what is needed, extend it there; do not build a second
   import resolver in the cache layer.
3. Land the differential test and **mutation-check it**: with the closure contribution removed from the
   identity it must fail with a stale hit; restored, it must pass. Record both outputs verbatim in the
   result note. A test only observed to pass does not satisfy this.
4. Measure invalidation at entry granularity on this repository and on a focused fixture: edit one leaf
   module, one widely-imported module, and one module with no dependents; report hits and misses per
   run, not wall time alone.
5. Confirm index-file behavior: repeated edits must not leave one orphaned index per revision.
6. Inspect all callers and documentation for leaked mechanism or claims stronger than evidence.

## Stop

- **A stale hit is a stop.** If any exercised edit shape serves a cached result disagreeing with fresh
  analysis, stop and reopen `RCI-SPEC`'s identity rather than narrowing the test around it.
- Do not widen the cache's public surface; `ResultCache` stays constructed only through `open?`.
- Do not weaken `open?`'s refusal to manufacture a partial epoch to make invalidation cheaper.
- Do not defer the watch re-exec decision here by removing it opportunistically; `RCI-FINAL` owns it on
  measurement.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules.
- Run `tests/check/run.sh`, `tests/watch/run.sh`, and `tests/boundary/run.sh`; inspect every changed
  module boundary manually.
- Use focused fixtures or the frozen sample for scale; complete mathlib is forbidden in this stack.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-16b-cache-identity`.
- Run `git diff --check` and read all output before marking RCI-IMPL verified.
