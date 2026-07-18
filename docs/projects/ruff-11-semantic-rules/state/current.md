---
kind: state
first_unresolved: 01-authority
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are
`ruff-05-rule-engine`, `ruff-05b-semantic-facts`, and `ruff-06-fix-safety` (per `roadmap.md`'s
`prereq_stacks`). **`ruff-05b-semantic-facts` is the foundation this stack builds on** — it produces the
`Tier.semantic` capture and the immutable semantic projection; `RMR-SPEC` characterizes the *rule-facing*
facts and consumes that tier rather than re-deriving it. Before starting, confirm those roadmaps are
verified and their live implementation still matches recorded state. The tier/cache/re-projection
machinery `RMR-IMPL` extends is now live for the source and syntax tiers (`requiredTier` gating,
`cacheHitServes` on `tier.satisfies`, and the `availableAnalysis`/`reprojectCanonical` render path, at
`SemanticResult` schema `v6` after `ruff-10`/`ruff-10b`); extend it for `.semantic` rather than adding a
parallel path.

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
