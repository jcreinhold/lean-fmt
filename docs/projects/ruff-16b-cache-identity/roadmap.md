---
kind: roadmap
topic: "Result-cache identity and incremental invalidation"
main_results: [RCI-FINAL]
prereq_stacks: [ruff-16-watch-incremental]
blueprint_tracked: false
---

# Result-cache identity and incremental invalidation

## Goal

Make the aggregate result cache invalidate the modules an edit can actually affect, instead of the whole
project, without ever converting a miss into a stale hit.

## The defect

`Cache.environmentDigest?` folds the content of **every** project source into `environment`
(`sourceRootParts?` walks `workspace.augmentedLeanSrcPath` and digests each `.lean` file's bytes).
`environment` feeds `baseDigest`, and `baseDigest` *names the index file* (`indexPath`). So editing any
one source changes the index filename, orphaning the previous index and invalidating every entry in it.

Measured on this repository at commit `442478c`, 112 files:

| Run | Wall time |
| --- | --- |
| cold | 64.3 s |
| unchanged re-run | 0.63 s |
| **after appending one comment to one file** | **61.6 s** |

A second index file appears in `.lean-fmt-cache/results/` after the edit, which is the direct
observable. The practical consequence is that the persistent cache helps only when nothing changed —
precisely the case where the user is least likely to be waiting on it.

**This supersedes `ruff-16`'s recorded diagnosis.** `ruff-16-watch-incremental/results/02-implementation.md`
decision 3 attributed the same ~70 s to `execute` failing to reuse the cache *within one process* and
routed around it by re-execing each watch generation. That is wrong: `execute` opens a fresh
`ResultCache` per call (`Application.lean:1298`) and there is no retained in-process state to go stale.
The two numbers being compared were different workloads — cold-after-edit against an unchanged tree.
`RCI-SPEC` owns correcting that record.

## The hard part

The whole-project digest is coarse but it is **not gratuitous**, and the naive fix is unsafe. Per-entry
identity already carries `source := Digest.ofString target.source` — the target's own bytes. If module
`B` imports `A` and only `A` changes, `B`'s own source digest is unchanged while its elaboration
environment is not. Dropping project sources from `environment` without replacing them converts a
correct-but-catastrophic miss into a **silent stale hit**, which is the one direction that matters.

So the work is to key each entry on its **transitive import closure** rather than on the whole project,
and to prove the resulting invalidation is neither too coarse (the current defect) nor too fine (stale
hits).

## Completion contract

- Editing one module invalidates that module and its dependents, and leaves unrelated modules' entries
  served from cache. Demonstrated as wall-time and as entry-level hit/miss counts, not wall-time alone.
- Entry identity binds the transitive import closure — every module whose content can change the
  target's elaboration — under the existing stale-miss discipline. Dependency sources outside the
  project and non-source environment inputs keep whatever coverage they have now; this stack narrows
  project-source coverage only.
- **A differential test that a naive fix fails.** Change only a transitively imported module, leave the
  target untouched, and assert the target is re-analyzed. This test must be mutation-checked: with the
  closure contribution removed from the identity it fails with a stale hit, restored it passes.
- Index files are not orphaned per edit. Whatever keying ships, `.lean-fmt-cache/results/` does not
  accumulate one index per source revision, and stale indices are collectable.
- **Decide whether watch's per-generation re-exec comes out.** `ruff-16` adopted it for a reason that
  did not hold. Removing it is still a measurement, not a consequence: re-exec also buys the flat
  retention `ruff-16` measured (16 KiB over 13 generations) against a ~400 ms child-process fixed cost.
  Measure in-process against re-exec and record the decision either way.
- Cache failure still never changes analysis results, and a corrupt index is still an empty cache.

## Work order

1. **RCI-SPEC — Freeze the identity and the stale-hit test.** Correct the `ruff-16` record. Establish
   the reproduction as evidence. Define what the import closure is for this purpose (source-tier and
   syntax-tier targets may differ), where it is computed, what happens when it cannot be determined,
   and the differential test that separates a correct fix from a naive one. Ship documentation and one
   characterization test; no production interface, per the `*-SPEC` convention.
2. **RCI-IMPL — Rekey entries on the import closure.** Implement it in `LeanFmt.Cache` with whatever
   `LeanFmt.Project` must expose to supply the closure. Land the mutation-checked differential test.
   Measure one-file-edit invalidation at entry granularity.
3. **RCI-FINAL — Audit invalidation and settle the watch workaround.** Adversarial cases: cyclic-looking
   import graphs, a module added or deleted mid-closure, config and toolchain changes, a dependency
   rebuild, index accumulation and collection. Decide re-exec on measurement. Verify no stale hit under
   any exercised edit shape.

## Evidence and verification

Every prompt writes a result note with exact commands, raw outputs or evidence locators, measurements,
decisions changed during execution, and remaining uncertainty. Report cache behavior as entry-level hit
and miss counts wherever a claim is about invalidation; wall time alone cannot distinguish "cache
worked" from "the OS page cache was warm", which is exactly how `ruff-16` misread this.

Run the affected Lean build and tests, `tests/watch/run.sh`, `tests/check/run.sh`, `tests/boundary/run.sh`,
this stack's structural checker, the generated-next check, and `git diff --check`. Use focused fixtures
and the frozen representative mathlib sample; do not run complete mathlib in this stack.

## Blueprint

This is formatter repository maintenance and introduces no mathematical theorem claim. Therefore this
roadmap sets `blueprint_tracked: false`.

## Stop rules

- **A stale hit is a stop, not a bug to file.** If any exercised edit shape serves a cached result that
  disagrees with a fresh analysis, stop and reopen the identity rather than narrowing the test.
- Preserve exact ordered imports, search-path precedence, file-local syntax effects, validation identity,
  private application boundaries, and atomic writes.
- Do not widen the cache's public surface; `ResultCache` stays a private capability constructed only
  through `open?`.
- Do not weaken `open?`'s refusal to manufacture a partial epoch in order to make invalidation cheaper.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
