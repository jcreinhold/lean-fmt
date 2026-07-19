---
claim_id: ROS-IMPL
status: planned
depends_on: [ROS-SPEC]
---

# Capture whole-file info trees, ship the fixable FMT014 and the capability gate

## Task

Deliver **ROS-IMPL**: Capture the owned deprecation-occurrence fact from the whole-file info trees under
demand, ship FMT014's `unsafe` rename through `ruff-06`'s fix machinery, and add the capability split so
the info-tree walk is paid only when the fix is demanded — implementing the interface ROS-SPEC froze,
without changing the surfaced FMT014 report or the source/syntax/semantic fast paths.

Read `roadmap.md`, `notes/01-model.md` and `results/01-spec.md` (the frozen interface), `AGENTS.md`, and
the live implementation and tests before changing an interface. Write the interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- Implement the task behind the existing private intent-to-report architecture; keep CLI presentation in
  `LeanFmt.Cli` and lifecycle/cache/project complexity below callers. `LeanFmt.Rules` stays absent from
  the compiler-plugin closure and its library globs (the `tests/boundary/run.sh` invariant).
- Capture the whole-file info trees in `analyzeExact` under the fixable-capability demand only, resolve
  each deprecated-declaration occurrence to `(range, declName, newName?, since?, text?)` in
  normalized-source coordinates, and store it as immutable data in the projection — no `Environment`,
  `InfoTree`, `Position`, or `FileMap` reaches a rule. Add the owned occurrence fact to
  `SemanticProjection` and bump the artifact schema (`v5 → v6`), with the stale-miss guard.
- Add the capability model: `SemanticCaps` with `Option` sub-fields, record captured caps in
  `SemanticResult` (`v6 → v7`), extend `cacheHitServes` to require `demandedCaps ⊆ entry caps`, and route
  the fixable-FMT014 demand into `demandedTier`/`demandedCaps`. A monolithic-era entry must miss a
  fixable demand, and the surfaced-only and rendering-only demands must not trigger the info-tree walk.
- Ship FMT014's `unsafe` fix: emit a rename `Fix` (bare-identifier occurrences with a `newName?` only,
  per the frozen predicate) and route it through `ruff-06`'s applicability/conflict/transaction path and
  the output re-elaboration validator, exactly as `ruff-10b` routes a syntax fix. Keep the surfaced
  FMT014 finding for every non-qualifying occurrence; `fixable` in the registry becomes true, and the
  fix is withheld unless admitted.
- Remove the deferral path rather than leaving a parallel architecture. Add or update focused fixtures
  and persistent regression tests at the owning layer, including a fresh-frontend differential that the
  projected occurrence `(range, declName, newName?)` matches Lean's own resolution, and a demand-gating
  test that the info-tree walk is absent unless the fixable capability is demanded.
- Write `results/02-impl.md` with exact commands, raw outputs or evidence locators, measurements,
  decisions changed during execution, and remaining uncertainty. Update `state/current.md` only after
  reading the checks, then regenerate `state/next.md`.

## Plan

1. Reproduce and characterize the current capture and fix boundaries relevant to this claim (the
   monolithic `.semantic` capture, `cacheHitServes`, the surfaced FMT014, the `ruff-06`/`ruff-10b`
   fix path).
2. Implement the whole-file info-tree capture and the owned-occurrence projection behind the
   capability gate; the walk is demanded, not always-on.
3. Implement the capability split (`SemanticCaps`, schema bumps, `cacheHitServes` `⊆`) and the FMT014
   rename fix, reusing the `ruff-06` machinery.
4. Exercise positive, negative, malformed, stale, custom-syntax, Unicode, and resource cases: a clean
   rename, a withheld (unadmitted) fix, non-bare-identifier occurrences left report-only, a
   `newName? = none` entry, a monolithic-era cache miss, and the demand-gating both directions.
5. Inspect all callers and documentation for leaked mechanism or claims stronger than evidence.

## Stop

- The artifact and `SemanticResult` schema and cache identity must include the compiler/runtime version
  and the captured capabilities.
- No retained mutable environment; the owned occurrence fact is immutable data.
- A rename must never be applied to an occurrence the frozen predicate excludes, and the info-tree walk
  must never run for a demand that did not ask for the fixable capability.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules
  (`tests/semantic/run.sh`, `tests/modes/run.sh`, `tests/check/run.sh`, `lake exe lean-fmt-tests`).
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually — the info-tree
  capture lives in `LeanFmt.Analysis`, and `LeanFmt.Rules` must stay out of the plugin closure.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden in this
  stack.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-11b-owned-semantic-fix`.
- Run `git diff --check` and read all output before marking ROS-IMPL verified.
