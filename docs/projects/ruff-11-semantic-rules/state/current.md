---
kind: state
first_unresolved: 02-implementation
---

# Current state

**RMR-SPEC is verified** (`results/01-authority.md`; design `notes/01-authority.md`; first-hand compiler
evidence `evidence/01-semantic-diagnostics.txt`). The three prerequisite stacks `ruff-05-rule-engine`,
`ruff-05b-semantic-facts`, and `ruff-06-fix-safety` are all verified, and this stack re-read their live
implementation rather than trusting recorded state (the foundation seams are cited by file:line in the
result note). `ruff-05b` is the foundation: `Tier.semantic` in the `source ≤ syntax ≤ semantic` lattice
(`Rules.lean:35-55`), `ModuleArtifact` `v4` with an optional `SemanticProjection`
(`ArtifactModel.lean:100-158`), and the `SemanticResult` cache `v6` recording `tier`
(`Semantic.lean:26-78`). Confirmed live: `Facts`/`RuleImpl` still have **no** `semantic` case and no rule
reaches `.semantic` — only the formatter demands it (`Config.lean:302-303`). RMR-IMPL extends that
machinery for `.semantic` rather than adding a parallel path.

**What RMR-SPEC froze.** Four semantic-tier rules, all *surfaced* (normalized from the MessageLog the
exact frontend already collects), all demonstrated firing first-hand on v4.32.0 with a stable `kind` tag
and exact range: FMT014 deprecated-declaration use (`Lean.Linter.deprecatedAttr`), FMT015 unused variable
(`linter.unusedVariables`), FMT016 unused section variable (`linter.unusedSectionVars`), FMT017
constructor-name variable (`linter.constructorNameAsVariable`). Report-only, default OFF (as FMT008–013).
The projection gains `Diagnostic`/`SemanticProjection.diagnostics` (`v4 → v5`); capture is monolithic
(Design A) so `Tier.satisfies`/`cacheHitServes` stay a sound gate. The owned/fixable FMT014 autofix and
its whole-file info-tree capture (the `waitForFinalCmdState?` pitfall) are specified but **deferred**,
together with the Design-B capability split. See `notes/01-authority.md` §§3,6,8,11.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-authority | RMR-SPEC | verified | — |
| 02-implementation | RMR-IMPL | planned | RMR-SPEC |
| 03-acceptance | RMR-FINAL | planned | RMR-IMPL |

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.
- RMR-IMPL owes the work list in `notes/01-authority.md` §11 and must carry the four remaining
  uncertainties in §12 (whole-line range recovery, macro-reattributed range clamping, suppression
  interaction, the deferred info-tree autofix).

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
