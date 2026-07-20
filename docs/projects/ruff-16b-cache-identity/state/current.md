---
kind: state
first_unresolved: 01-contract
---

# Current state

This stack was opened after `ruff-16-watch-incremental` closed, when a review of that stack's
result-cache finding did not survive reading the code. Its external prerequisite stack is
`ruff-16-watch-incremental`, which records `first_unresolved: none`. If live code contradicts a
prerequisite result, reopen the owning prerequisite rather than patching around it.

No prompt has run. Nothing below is verified; it is the diagnosis that motivated the stack, and
`RCI-SPEC` owns confirming or correcting it.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-contract | RCI-SPEC | planned | — |
| 02-model | RCI-MODEL | planned | RCI-SPEC |
| 03-implementation | RCI-IMPL | planned | RCI-MODEL |
| 04-acceptance | RCI-FINAL | planned | RCI-IMPL |

## The diagnosis this stack starts from

`Cache.environmentDigest?` folds every project source file's bytes into `environment` via
`sourceRootParts?`; `environment` feeds `baseDigest`; `baseDigest` names the index file through
`indexPath`. Editing one source therefore changes the index filename and orphans every entry.

Measured on this repository at `442478c`, 112 files, with `.lake/build/bin/lean-fmt check --root .`:

| Run | Wall time | Observable |
| --- | --- | --- |
| cold | 64.3 s | index file created |
| unchanged re-run | 0.63 s | same index served |
| one comment appended to one file | 61.6 s | **second index file appears** |

The second index file is the direct evidence; the timings alone would not distinguish this from a warm
page cache, which is how the original misreading happened.

## What this stack supersedes

`ruff-16-watch-incremental/results/02-implementation.md` decision 3 attributed the same ~70 s to
`execute` failing to reuse the result cache **within one process**, and adopted per-generation re-exec
in watch on that basis. That diagnosis appears to be wrong on two counts:

- `execute` opens a fresh `ResultCache` per call (`Application.lean:1298`), and `loadedEntries` is
  created inside `open?`, so there is no retained in-process state that could go stale.
- The compared numbers were different workloads — cold-after-edit against an unchanged tree. An
  unchanged-tree run reproduces at 0.63 s here, matching the "0.52 s separate process" figure.

`RCI-SPEC` owns amending that record, the matching uncertainty entry in `ruff-16`'s
`results/03-acceptance.md`, the inherited notes in `ruff-17-lsp` and `ruff-19-performance`
`state/current.md`, and the superseded bullet in `ruff-19-performance/roadmap.md` (added in `442478c`,
before this diagnosis existed).

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
  A module's `.trace` records `deps.imports` per-import transitive hashes, its own source hash, and
  `depHash`. `RCI-SPEC` must verify that reading — it comes from sampled trace files, not from the Lake
  sources — before any design depends on it.
- **This stack carries the repository's first theorem claims.** It still sets
  `blueprint_tracked: false`: that flag records membership in a blueprint node graph, not the presence
  of theorems, and `lean-fmt` has no blueprint document. The scope is
  narrow and stated in `notes/01-what-is-provable.md`: the direct claim "the cache is always valid" is
  not provable at all, because the decision is `IO` and Lean models no filesystem. What is provable is a
  soundness/completeness pair for a pure decision function over an explicit observation, under four
  named hypotheses — digest injectivity, observation faithfulness (**false in general**; a bounded
  TOCTOU race), Lake trace fidelity, and analysis purity. Enumerating those hypotheses is the point.
- A module's stored `depHash` records what it was **built against**, not whether that is still true.
  Read alone it falsely hits in exactly the stale case that matters. This is the trap the design
  comparison in `RCI-SPEC` exists to catch.
