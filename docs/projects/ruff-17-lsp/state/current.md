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

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
