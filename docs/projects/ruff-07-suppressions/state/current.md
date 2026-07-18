---
kind: state
first_unresolved: 02-implementation
---

# Current state

`RSP-SPEC` is **verified**. The design is `notes/01-spec.md`; what was run is `results/01-spec.md`,
and the current-boundary characterization is `evidence/01-no-suppression.txt`. The external
prerequisite stacks `ruff-05-rule-engine`, `ruff-05b-semantic-facts`, and `ruff-06-fix-safety` are
verified, and this stack re-read their live code (`Rules.lean`, `Config.lean`, `Comments.lean`,
`LosslessSource.lean`, `Application.lean`) rather than trusting recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | RSP-SPEC | verified | — |
| 02-implementation | RSP-IMPL | planned | RSP-SPEC |
| 03-acceptance | RSP-FINAL | planned | RSP-IMPL |

## Known evidence

- **No source-suppression layer exists.** A `lean-fmt:` comment is inert; the concept scan is empty and
  three genuine finding+directive fixtures all report the finding (`evidence/01-no-suppression.txt`).
- **Directives are comment trivia only.** The grammar is read from `Comment{lineComment|blockComment}`
  via `Comments.attach`, never by substring search, so strings, quotations, and doc comments are
  excluded by construction (`notes/01-spec.md` §1).
- **Suppression is a projection, not an engine change.** It filters `Array Finding` alongside
  `RulePlan`, must not enter the result cache key, and cannot reach infrastructure failures, which are
  never findings (`notes/01-spec.md` §6, §10).
- **Reserved codes** `FMT900` (unused suppression, safe removal fix) and `FMT901` (malformed
  suppression) in a `9xx` self-diagnostic band; `RSP-IMPL` confirms and finalizes.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
