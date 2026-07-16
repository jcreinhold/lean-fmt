---
kind: state
first_unresolved: 01-schema
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are
`ruff-07-suppressions`, `ruff-08-source-rules`, `ruff-09-import-rules`, `ruff-10-syntax-rules`, `ruff-11-semantic-rules`. Before starting, confirm those roadmaps are verified and their live
implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-schema | RRL-SPEC | planned | — |
| 02-generation | RRL-IMPL | planned | RRL-SPEC |
| 03-acceptance | RRL-FINAL | planned | RRL-IMPL |

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
