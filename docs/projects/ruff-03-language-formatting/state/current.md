---
kind: state
first_unresolved: 01-commands
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are
`ruff-02-layout-core`. Before starting, confirm those roadmaps are verified and their live
implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-commands | RLF-COMMANDS | planned | — |
| 02-expressions | RLF-EXPRESSIONS | planned | RLF-COMMANDS |
| 03-tactics | RLF-TACTICS | planned | RLF-EXPRESSIONS |
| 04-extensions | RLF-EXTENSIONS | planned | RLF-TACTICS |
| 05-corpus | RLF-FINAL | planned | RLF-EXTENSIONS |

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
