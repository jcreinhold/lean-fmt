---
kind: state
first_unresolved: 01-catalog
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are
`ruff-05-rule-engine`, `ruff-06-fix-safety`. Before starting, confirm those roadmaps are verified and their live
implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-catalog | RSR-SPEC | planned | — |
| 02-implementation | RSR-IMPL | planned | RSR-SPEC |
| 03-acceptance | RSR-FINAL | planned | RSR-IMPL |

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
