---
kind: state
first_unresolved: 03-final
---

# Current state

**RYC-SPEC and RYC-IMPL verified; `fix` now applies syntax fixes.** This successor stack holds the one
deferral
`ruff-10-syntax-rules` left open: `fix` applying a syntax-tier rule's `.safe` fix. `check` already
reports FMT010/011/013 fixes on original coordinates, but `format`/`fix` render canonical text and run
only `runSourceRules`, so a syntax fix is reported and never applied (`Application.renderCanonicalText`,
pinned by `tests/syntax/run.sh`).

RYC-SPEC characterized the live fix lifecycle and froze the composition interface (`notes/01-model.md`,
`results/01-spec.md`). The finding: the whole composition reduces to putting canonical-coordinate
syntax findings into `CanonicalText.findings` — `prepareFile` already builds the write patch from that
field (`Application.lean:805-812`), and admission, `Edit.validateConflicts`, atomic publication, and the
output re-elaboration validator already handle any-tier findings. Chosen **Design A**: when a
canonical-rendering run demands the syntax tier, `renderCanonicalText` re-projects the rendered text
through the exact frontend and uses the whole-registry findings as `CanonicalText.findings`; the edits
are then natively in canonical coordinates (ruff-06's "re-project, don't translate"). **Design B**
(parse-only projection) is rejected for v1 and named as the optimization if RYC-FINAL measures Design
A's elaboration cost as unacceptable.

The composition **model is already frozen** by `ruff-06-fix-safety`'s RFX-SPEC (`notes/01-model.md`
§3, verified): a syntax-tier fix composes by **re-projecting the canonical text** — parse the rendered
file, run the rule against that projection — never by translating original-coordinate edits onto moved
bytes, which would make the applied artifact depend on fix pass order. RFX-SPEC explicitly handed the
*wiring and adversarial exercise* forward to "the stack that ships the first syntax-tier rule with a
fix, with a real rule to drive them." `ruff-10` shipped those rules (FMT010/011/013); this stack is
that future stack.

RYC-IMPL wired Design A (`results/02-impl.md`): `ExactRun.reprojectCanonical` re-runs the frontend on
the rendered text and replaces `CanonicalText.findings` with the whole registry over that projection;
`analyzeSnapshot` gains `needsSyntax`, `availableAnalysis` forces the exact-run path for
`renderCanonical && requiredTier == .syntax`, and the result-cache schema bumped `v5 → v6`. Verified
end-to-end: `fix --select FMT013/FMT010/FMT011` writes the corrected bytes (`((1))→(1)`,
`@[simp, simp]→@[simp]`, `deriving Repr, Repr→deriving Repr`), `format` composes the fix into its
preview, and a re-`check` of every written file is clean. `tests/syntax/run.sh` retired the
fix-deferral pin for apply-and-verify cases; all twelve build/test gates pass.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | RYC-SPEC | verified | — |
| 02-impl | RYC-IMPL | verified | RYC-SPEC |
| 03-final | RYC-FINAL | planned | RYC-IMPL |

## Scope

- **In scope:** the `fix`/`format` write path only — re-project rendered canonical text when a selected
  rule needs it, route canonical-coordinate syntax fixes through `ruff-06`'s existing applicability/
  conflict/transaction machinery, gated exactly as `requiredTier` gates projection.
- **Out of scope:** `check` behavior and `SemanticResult` cache identity (unchanged); rule authoring
  (owned by `ruff-10`); graduating preview rules to default (owned by `ruff-12`); the incremental cache
  (`ruff-16`) and default-run cost budget (`ruff-19`).

## Blockers and prerequisites

- No blocker. Prerequisites `ruff-04-formatter-product`, `ruff-06-fix-safety`, and
  `ruff-10-syntax-rules` are all verified. The composition model is frozen; only the wiring and its
  adversarial exercise remain, which is this stack's whole job.
- If live code contradicts a prerequisite result, reopen the owning prerequisite rather than patching
  around it. Full mathlib is not development evidence; use the frozen sample and named stress cases.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful
evidence, and state agrees with live code. Missing, stale, unsupported, or unread checks are failures
to verify.
