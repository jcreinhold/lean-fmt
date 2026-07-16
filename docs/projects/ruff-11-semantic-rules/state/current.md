---
kind: state
first_unresolved: 01-authority
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are
`ruff-05-rule-engine`, `ruff-06-fix-safety`. Before starting, confirm those roadmaps are verified and their live
implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-authority | RMR-SPEC | planned | — |
| 02-implementation | RMR-IMPL | planned | RMR-SPEC |
| 03-acceptance | RMR-FINAL | planned | RMR-IMPL |

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
