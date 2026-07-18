---
kind: state
first_unresolved: 02-implementation
---

# Current state

`RIR-SPEC` is **verified**: the import-rule catalog is frozen in `notes/01-semantics.md`, measured by
`evidence/01-semantics.lean` (transcript `evidence/01-semantics.txt`). No production code changed —
the correct footprint for a spec prompt. The external prerequisite stacks
`ruff-01-lossless-source`, `ruff-05-rule-engine`, and `ruff-06-fix-safety` remain verified and their
live implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-semantics | RIR-SPEC | verified | — |
| 02-implementation | RIR-IMPL | planned | RIR-SPEC |
| 03-acceptance | RIR-FINAL | planned | RIR-IMPL |

## What the spec froze (for 02-implementation to build against)

- Three rules in a new `imports` category: **FMT005** duplicate (fixable/safe), **FMT006** redundant
  (report-only, withholding), **FMT007** order/grouping (report-only, fix opt-in), plus **one private
  organizer** operation exposed to CLI + LSP without graph internals.
- Import rules read the **surface header** `[0, headerStop)` (via the existing header model), never
  `parseImports'.imports` — the abstract list injects phantom `Init` and drops ranges/comments/order.
- Redundancy is **not** a `RuleImpl` (rules are pure/IO-free): it is a private `Project`-graph finding
  from `transImports`/`input` no-build facets, threaded in beside the pure header rules.

## Blockers and prerequisites

- No blocker recorded. The "lossless header model" `RIR-IMPL` needs already exists (printer header
  groups + `Suppression.headerComments` + `LosslessSource.headerStop`).
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching
  around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful
evidence, and state agrees with live code. Missing, stale, unsupported, or unread checks are failures
to verify.
