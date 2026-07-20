---
kind: state
first_unresolved: 03-implementation
---

# Current state

This stack was opened after `ruff-16-watch-incremental` closed, when a review of that stack's
result-cache finding did not survive reading the code. Its external prerequisite stack is
`ruff-16-watch-incremental`, which records `first_unresolved: none`. If live code contradicts a
prerequisite result, reopen the owning prerequisite rather than patching around it.

`RCI-SPEC` and `RCI-MODEL` have run. The diagnosis below is **confirmed** and reproduced at entry
granularity; the `ruff-16` record is amended everywhere it was asserted; the currency check, the tier
decision, the undeterminable-currency rule, and the differential test are frozen in
`results/01-contract.md`; and the decision is modelled and proved sound **and** complete in
`LeanFmt/Cache/Spec.lean` under four named hypotheses, depending on `propext` alone
(`results/02-model.md`).

What remains is implementation. Nothing in `LeanFmt.Cache` has changed yet — the shipped cache still
folds every project source into the index filename.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-contract | RCI-SPEC | verified | — |
| 02-model | RCI-MODEL | verified | RCI-SPEC |
| 03-implementation | RCI-IMPL | planned | RCI-MODEL |
| 04-acceptance | RCI-FINAL | planned | RCI-IMPL |

## The diagnosis, now confirmed

`Cache.environmentDigest?` folds every project source file's bytes into `environment` via
`sourceRootParts?`; `environment` feeds `baseDigest`; `baseDigest` names the index file through
`indexPath`. Editing one source therefore changes the index filename and orphans every entry.

Re-measured under `RCI-SPEC` at `60e5da5`, 112 files, with entry-level counts from the profile
channel (`results/01-contract.md` §2, `evidence/01-invalidation-and-traces.md` §1):

| Run | `index_hits` | Wall time | Observable |
| --- | --- | --- | --- |
| cold | 0 / 112 | 61.32 s | index file created |
| unchanged re-run | **112 / 112** | 0.58 s | same index served |
| one comment appended to one file | **0 / 112** | 59.10 s | **second index file appears** |
| that comment reverted | **112 / 112** | 0.70 s | original index served again |

`index_hits = 0`, not `111`, is the finding: the edit invalidated the *name of the index*, not the
edited file's entry. The revert row confirms the name is a content digest over the whole project
source set. Timings alone could not distinguish any of this from a warm page cache, which is how the
original misreading happened.

## What this stack superseded (done)

`ruff-16-watch-incremental/results/02-implementation.md` decision 3 attributed the same ~70 s to
`execute` failing to reuse the result cache **within one process**, and adopted per-generation re-exec
in watch on that basis. That diagnosis is **refuted**, on two counts:

- `execute` opens a fresh `ResultCache` per call (`Application.lean:1298`), and `loadedEntries` is
  created inside `open?` (`Cache.lean:267`), so there is no retained in-process state that could go
  stale.
- The compared numbers were different workloads — cold-after-edit against an unchanged tree. An
  unchanged-tree run reproduces at 0.58 s here, matching the "0.52 s separate process" figure.

`RCI-SPEC` amended all five sites and they are now consistent: `ruff-16`'s
`results/02-implementation.md` (two amendment blocks) and `results/03-acceptance.md` (entry struck and
annotated), the inherited notes in `ruff-17-lsp` and `ruff-19-performance` `state/current.md`
(`[DISPUTED]` → `[REFUTED]`), and the bullet in `ruff-19-performance/roadmap.md` (replaced by a
`[REMOVED]` stub, its work-order citation corrected). The shipped re-exec behavior is untouched;
`RCI-FINAL` still owns that decision and still owes it a measurement.

## Blockers and prerequisites

- None external. `ruff-16-watch-incremental` is `verified` and its shipped surface is what this stack
  re-examines.
- The naive fix is unsafe and is the stack's central risk, but **not** for the reason first written
  here. Rules provably cannot read across modules (`Rules.lean:17`: a rule "cannot reach a workspace, a
  cache, an `Environment`, or `IO` — not by convention but because `run`'s argument type is a fact
  view"), and the one cross-module rule family is computed outside the cache for that reason
  (`Application.lean:1286`). The risk is that **the fact view itself is import-derived**: Lean's grammar
  is open, so a `notation`/`macro`/`syntax` change in `A` changes how `B`'s unchanged bytes parse. A
  cached analysis of `B` describes a parse produced under `A`'s old grammar, and rendering canonical
  text from it can change what the code means.
- The missing check is currency, and Lake already computes it. `validateOleanTrace?` parses only
  `schemaVersion` and `outputs` (`Cache.lean:14-17`), proving the artifact is intact but never current.
  **`RCI-SPEC` verified the trace reading, and it came back different from what was written here.**
  `["A transitive imports (all)", h]` hashes the closure of `A`'s *imports* and **excludes `A`
  itself** — measured, by adding a declaration to a module and observing that no dependent's entry
  under that key moved. The key carrying `A`'s own artifacts is `["A:importAllArts", h]`, and it is
  exactly recomputable from `A`'s own trace `outputs`. The frozen check is built on that
  (`results/01-contract.md` §3-4); the design the roadmap originally sketched would have served the
  stale parse.
- **This stack carries the repository's first theorem claims.** It still sets
  `blueprint_tracked: false`: that flag records membership in a blueprint node graph, not the presence
  of theorems, and `lean-fmt` has no blueprint document. The scope is
  narrow and stated in `notes/01-what-is-provable.md`: the direct claim "the cache is always valid" is
  not provable at all, because the decision is `IO` and Lean models no filesystem. What is provable is a
  soundness/completeness pair for a pure decision function over an explicit observation, under four
  named hypotheses — digest injectivity, observation faithfulness (**false in general**; a bounded
  TOCTOU race), Lake trace fidelity, and analysis purity. Enumerating those hypotheses is the point.
- A module's stored `depHash` records what it was **built against**, not whether that is still true.
  Read alone it falsely hits in exactly the stale case that matters. The frozen design avoids it:
  currency compares `M`'s *recorded expectation* for each import against that import's **current**
  artifacts, and never reads `M`'s own stored `depHash`.
- **Open for `RCI-IMPL`/`RCI-FINAL`:** index collection. Making the index name independent of project
  sources removes future accumulation, but no collection path exists at all — the two orphans this
  repository accumulated during `RCI-SPEC` are still on disk. One of the two later prompts must state
  whether collection is added or whether a stable name makes it moot.
