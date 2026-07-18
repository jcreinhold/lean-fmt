---
kind: state
first_unresolved: 01-spec
---

# Current state

**Scaffolded, not started.** This successor stack holds the one deferral `ruff-10-syntax-rules` left
open: `fix` applying a syntax-tier rule's `.safe` fix. `check` already reports FMT010/011/013 fixes on
original coordinates, but `format`/`fix` render canonical text and run only `runSourceRules`, so a
syntax fix is reported and never applied (`Application.renderCanonicalText`, pinned by
`tests/syntax/run.sh`).

The composition **model is already frozen** by `ruff-06-fix-safety`'s RFX-SPEC (`notes/01-model.md`
§3, verified): a syntax-tier fix composes by **re-projecting the canonical text** — parse the rendered
file, run the rule against that projection — never by translating original-coordinate edits onto moved
bytes, which would make the applied artifact depend on fix pass order. RFX-SPEC explicitly handed the
*wiring and adversarial exercise* forward to "the stack that ships the first syntax-tier rule with a
fix, with a real rule to drive them." `ruff-10` shipped those rules (FMT010/011/013); this stack is
that future stack.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | RYC-SPEC | planned | — |
| 02-impl | RYC-IMPL | planned | RYC-SPEC |
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
