---
kind: state
first_unresolved: 01-protocol
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are
`ruff-06-fix-safety`, `ruff-07-suppressions`, `ruff-13-config-discovery`, `ruff-14-stream-range`. Before starting, confirm those roadmaps are verified and their live
implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-protocol | RLP-PROTOCOL | planned | — |
| 02-documents | RLP-DOCUMENTS | planned | RLP-PROTOCOL |
| 03-features | RLP-FEATURES | planned | RLP-DOCUMENTS |
| 04-acceptance | RLP-FINAL | planned | RLP-FEATURES |

## Inherited from `ruff-14-stream-range` (verified)

Measured there, and design input here rather than trivia to rediscover:

- **A range is not cheaper than the whole buffer** (`ruff-14/evidence/03-stream-cost.txt`). The cost of
  a request is one exact frontend run over the whole document, which a range cannot skip without
  giving up exactness. `textDocument/rangeFormatting` is not the fast path it is usually assumed to
  be, so debounce, cancellation, and capacity decisions must not be built on the assumption that a
  small selection is a small request.
- **Comment ownership at a unit boundary is trailing-greedy.** A comment written *above* a declaration
  belongs to the **earlier** unit, so range-formatting a declaration does not include the comment a
  user would say belongs to it. This is user-visible in an editor in a way it is not in a pipeline;
  decide deliberately whether the LSP surface explains it, and do not "fix" it here — it is
  `RLC-SPEC`'s frozen verdict and `ruff-14` re-confirmed it on real source.
- **The forward-extension clause is real but never fires on idiomatic Lean**: 0 of 2,854 layout units
  on the frozen mathlib sample (`ruff-14/evidence/03-range-unit-census.txt`). Practical consequence for
  this stack is small — the actual range must be reported either way — but do not "simplify" the
  expansion rule on the strength of a client never having observed it widening.

## Inherited from `ruff-15-reporting` (verified)

- **`Application.PositionIndex` is not this stack's conversion layer, and reaching for it would be
  silently wrong.** `ruff-15` added a byte-offset → (line, column) index, but its columns are 1-based
  **codepoints**, the encoding `ruff-14` froze for `--range-lines`. LSP positions are UTF-16 code
  units. The two agree on everything in the BMP and disagree outside it, which is why the difference
  survives casual testing: `ruff-15`'s astral fixture (`𝔘`, 4 bytes / 2 UTF-16 units / 1 codepoint)
  reports column **34**, where a byte column is 37 and a UTF-16 column is 35
  (`tests/reporting/run.sh`, "codepoint columns are neither bytes nor UTF-16"). The roadmap already
  requires "one tested conversion layer"; this is the concrete trap it has to avoid, and the astral
  fixture is the shape of test that catches it. `PositionIndex` is reusable as a *pattern* — resolve
  only the offsets the answer names, in one forward pass — not as an implementation.

## Inherited from `ruff-16-watch-incremental` (verified)

> **[REFUTED by `ruff-16b-cache-identity` `RCI-SPEC`, 2026-07-20. The in-process framing below is
> wrong; do not act on it.]** There is no in-process cache-reuse defect. `execute` opens a fresh
> `ResultCache` per call (`Application.lean:1298`) and `loadedEntries` is created inside `open?`
> (`Cache.lean:267`), so nothing is retained between calls to go stale. The compared numbers were
> different workloads: cold-after-edit against an unchanged tree.
>
> The confirmed defect is whole-project cache-key invalidation, and it is **process-independent**.
> `Cache.environmentDigest?` folds every project source's bytes into `environment`, which feeds
> `baseDigest`, which names the index file — so one edit renames the index and orphans every entry,
> in a fresh process just as much as a reused one. Reproduced at entry granularity: after appending
> one comment to one file, **0 of 112 entries hit**, not 111
> (`ruff-16b-cache-identity/results/01-contract.md`). The 135× figure below is real; its
> attribution is not.

- **`execute` does not reuse the result cache when called twice in one process.** Measured
  (`ruff-16/results/02-implementation.md`, decision 3): a second in-process `execute` after a
  one-file edit took **~70 s** — the full cold-cache price — where a *separate* process handling the
  identical edit took **0.52 s**. A 135× penalty. `ruff-16` routed around it by making every watch
  generation a fresh child process; nothing fixes it, and the root cause was not investigated because
  it lives in `Cache`/`Application`.

  **This stack is the one that cannot route around it.** An LSP server is by definition a long-running
  process answering many requests, so if its request path reaches `execute` it will pay the cold price
  on every request after the first. `LeanFmt.Service` already avoids this by holding one
  `Project.load` per session and answering through `Application.ExactRun` rather than `execute`
  (`ruff-14`) — `01-protocol` should confirm that the LSP path inherits that route and never calls
  `execute` per request, and should treat any design that does as blocked on the defect above.

> **Unblocked by `ruff-16b-cache-identity` `RCI-IMPL` (2026-07-20).** The underlying defect is fixed,
> not merely re-attributed. Entries are keyed per file on their import closure's build artifacts, so an
> edit invalidates that file and its dependents instead of the whole project, in any process. On this
> repository a warm re-run serves 119/119 in 0.52 s, and editing one file leaves every unrelated entry
> hitting.
>
> There was never an in-process penalty to inherit — `execute` opens a fresh `ResultCache` per call —
> so an LSP path that reaches `execute` is no longer choosing between correctness and the cold price.
> `LeanFmt.Service`'s route stays the right one for *unsaved* buffers, which is a different problem:
> disk-state evidence cannot answer for bytes that are not on disk. Confirm that, not the cache.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
