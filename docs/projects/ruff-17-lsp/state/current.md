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

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
