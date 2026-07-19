---
kind: state
first_unresolved: 01-spec
---

# Current state

**Freshly scaffolded — no prompt run yet.** This successor stack holds the one deferral `ruff-11`'s
RMR-SPEC named and no later stack owns: the **owned, fixable FMT014** (a validated `unsafe` rename of a
bare-identifier deprecated-declaration occurrence to its replacement) and the **info-tree capability
split** (`ruff-11-semantic-rules/notes/01-authority.md` §§6,8). FMT014 ships today as a *surfaced*,
report-only rule (`fixable:false`); its structured fix is deferred behind the whole-file info-tree
capture pitfall, and Design B (the capability split that keeps that expensive walk off every `format`
run) is frozen but unimplemented. This is the semantic analog of `ruff-10b`, which held the
`fix`-composition wiring `ruff-06` specified until a real syntax rule could drive it; here `ruff-11`'s
FMT014 is the real rule.

The substrate is characterized and verified in RMR-SPEC: `deprecatedAttr.getParam? env declName`
returns `{newName?, since?, text?}` from `Environment` data retained for imported public decls
(`Elab/Deprecated.lean`, `Attributes.lean`), demonstrated in
`ruff-11-semantic-rules/evidence/01-semantic-diagnostics.txt`; the per-occurrence resolution needs the
info tree (`TermInfo`/`addConstInfo`, `InfoTree/Main.lean:344-353`); and the capability model
(`SemanticCaps`, `Option` sub-fields, `SemanticResult v6 → v7`, `cacheHitServes` `demandedCaps ⊆ caps`)
is sketched in RMR-SPEC §6. ROS-SPEC re-derives these first-hand against the live compiler and product
seams rather than trusting recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | ROS-SPEC | planned | — |
| 02-impl | ROS-IMPL | planned | ROS-SPEC |
| 03-final | ROS-FINAL | planned | ROS-IMPL |

## Scope

- **In scope:** the owned deprecation-occurrence fact (whole-file info-tree capture, gated on demand),
  FMT014's `unsafe` rename through `ruff-06`'s applicability/conflict/transaction/validator path, and
  the Design-B capability split (`SemanticCaps`, schema bumps, `cacheHitServes` `⊆`).
- **Out of scope:** the four surfaced semantic rules FMT014–FMT017's report behavior (owned by
  `ruff-11`, unchanged); rule authoring and lifecycle/fixability *controls* (owned by `ruff-12`); the
  incremental cache (`ruff-16`) and the default-run cost budget (`ruff-19`). This stack owns the owned
  fact, its fix, and the capability that gates its capture.

## Blockers and prerequisites

- No blocker. Prerequisites `ruff-06-fix-safety`, `ruff-10b-syntax-fix-composition`, and
  `ruff-11-semantic-rules` are all verified. The fix-composition model (`ruff-06` RFX-SPEC), the
  non-source-tier fix wiring (`ruff-10b` RYC), and the owned-fact/capability model (`ruff-11` RMR-SPEC
  §§6,8) are frozen; this stack holds their union — the info-tree capture, the applied rename, and the
  split.
- If live code contradicts a prerequisite result, reopen the owning prerequisite rather than patching
  around it. Full mathlib is not development evidence; use the frozen sample and named stress cases.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful
evidence, and state agrees with live code. Missing, stale, unsupported, or unread checks are failures
to verify.
