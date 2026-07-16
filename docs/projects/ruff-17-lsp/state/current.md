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

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
