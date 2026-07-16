---
kind: state
first_unresolved: 01-semantics
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are
`ruff-01-lossless-source`, `ruff-05-rule-engine`, `ruff-06-fix-safety`. Before starting, confirm those roadmaps are verified and their live
implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-semantics | RIR-SPEC | planned | — |
| 02-implementation | RIR-IMPL | planned | RIR-SPEC |
| 03-acceptance | RIR-FINAL | planned | RIR-IMPL |

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
