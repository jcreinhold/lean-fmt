---
kind: state
first_unresolved: 01-baseline
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are
`ruff-04-formatter-product`, `ruff-12-rule-lifecycle`, `ruff-17-lsp`. Before starting, confirm those roadmaps are verified and their live
implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-baseline | RPR-SPEC | planned | — |
| 02-optimize | RPR-IMPL | planned | RPR-SPEC |
| 03-regressions | RPR-FINAL | planned | RPR-IMPL |

## Inherited from `ruff-15-reporting` (verified)

The completion contract names **rendering** as a profiled phase. `ruff-15` produced its baseline, and
one result changes what to profile:

- **Rendering is linear in report size across three decades and is not a scale risk.** 100 / 1,000 /
  10,000 / 100,000 findings through all six formats; 10× the report costs ~10× the milliseconds in
  every one, `Lean.Json.pretty` over a 50 MB SARIF log included
  (`ruff-15/evidence/03-report-scale.md`, driver `lake exe lean-fmt-tests report-bench`).
- **The cost is the position index, not the serializers.** At 100,000 findings, position-free `text`
  renders 33× faster than `concise` *while emitting more bytes* (7.82 MB against 6.95 MB), and `json`
  serializes 14 MB with no lookups faster than `concise` serializes 7 MB with 200,000 of them. If this
  stack profiles rendering, the two `PositionIndex` lookups per finding are the line item — the
  serializer is not where the time is, which is the opposite of what `RRF-IMPL` assumed.
- **What the benchmark does not cover, and this stack could.** The fixture's lines are uniform, so it
  exercises index *lookup* but not index *build* on a pathological source (one enormous line, findings
  clustered at the end of a very large file). The build is one forward pass, O(source bytes) by
  construction, and is unmeasured.

## Inherited from `ruff-16-watch-incremental` (verified)

> **[DISPUTED by `ruff-16b-cache-identity`.]** The in-process framing below is likely wrong.
> `execute` opens a fresh `ResultCache` per call (`Application.lean:1298`), and the compared
> numbers were different workloads (cold-after-edit versus an unchanged tree). The real defect
> appears to be that `Cache.environmentDigest?` folds every project source into the index
> filename, so any edit invalidates the whole project in any process. `RCI-SPEC` owns the
> amendment; do not act on the paragraph below before reading that stack's `state/current.md`.

- **`execute` does not reuse the result cache when called twice in one process.** Measured
  (`ruff-16/results/02-implementation.md`, decision 3): a second in-process `execute` after a
  one-file edit took **~70 s** — the full cold-cache price — where a *separate* process handling the
  identical edit took **0.52 s**. A 135× penalty. `ruff-16` routed around it by making every watch
  generation a fresh child process; nothing fixes it, and the root cause was not investigated because
  it lives in `Cache`/`Application`.

  **This stack owns it, per the completion-contract bullet added for it** — `ruff-16` recorded the
  measurement but never diagnosed the cause, so "affects any caller that runs `execute` more than once
  per process" is an inference from one measurement, not an established fact. Diagnose before
  optimizing: a cache that misses when it should hit is a correctness bug wearing a performance
  costume. If it is fixed, the contract also asks whether watch's re-exec workaround comes out.

- **Watch's own costs are measured and small.** The poll walk is 34 ms and per-generation fixed cost is
  ~400 ms (`workspace_load` 301–344 ms + `discovery` + `cache_epoch`), independent of file count;
  1 file → 110 files adds ~70 ms warm. Watch parent RSS grew **16 KiB over 13 generations**. If the
  discovery walk approaches generation cost on the frozen mathlib sample, `ruff-16` `notes` §1's
  rejection of an event-driven watcher (Lean binds no `uv_fs_event`) should be reopened rather than
  worked around.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
