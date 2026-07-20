---
kind: state
first_unresolved: 01-contract
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are
`ruff-13-config-discovery`, `ruff-15-reporting`. Before starting, confirm those roadmaps are verified and their live
implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-contract | RWI-SPEC | planned | — |
| 02-implementation | RWI-IMPL | planned | RWI-SPEC |
| 03-acceptance | RWI-FINAL | planned | RWI-IMPL |

## Inherited from `ruff-15-reporting` (verified)

- **"Output framing" in `RWI-SPEC` is now a per-format question, not one decision.** `ruff-15` shipped
  six `--output-format` values, and they do not all frame the same way. `text`, `concise`, and `github`
  are line-oriented and append cleanly, so a generation boundary is a separator. `json`, `sarif`, and
  `junit` each emit **one complete document per run** — a SARIF log has a single `runs` array and a
  JUnit file a single root element — so concatenating generations produces something no parser accepts.
  `RWI-SPEC` must decide explicitly: one document per generation (rewriting `--output-file` atomically,
  which `ruff-15` already made safe for a polling consumer), or the document formats rejected in watch
  mode the way `ruff-14`/`ruff-15` reject a flag a mode cannot honor. Do not default into
  concatenation.
- **Rendering is not a per-generation cost worth designing around.** A 10,000-finding report renders in
  1–312 ms depending on format (`ruff-15/evidence/03-report-scale.md`); a realistic generation is far
  smaller. Coalescing and invalidation decisions should be driven by analysis cost, not render cost.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
