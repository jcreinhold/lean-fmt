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
| 02-implementation | RCI-IMPL | planned | RCI-SPEC |
| 03-acceptance | RCI-FINAL | planned | RCI-IMPL |

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
- The naive fix is unsafe and is the stack's central risk: per-entry identity already carries the
  target's own source digest, so removing project sources from `environment` without replacing them with
  closure coverage converts whole-project invalidation into **silent stale hits** whenever a module's
  transitive import changes and its own bytes do not.
