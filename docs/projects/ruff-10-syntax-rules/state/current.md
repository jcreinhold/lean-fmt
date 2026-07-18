---
kind: state
first_unresolved: 02-implementation
---

# Current state

`RYR-SPEC` is **verified**. The frozen catalog is `notes/01-catalog.md`; what was run is
`results/01-catalog.md`; the reproducible corpus evidence is `evidence/01-catalog.md`. Six syntax-tier
rules **FMT008–FMT013** are specified across the four roadmap families, each grounded in a syntax kind
cited to the pinned `leanprover/lean4:v4.32.0` compiler and, for adopted rules, a real Mathlib linter
(`~/Code/mathlib4` @ `783ccda4…`). This prompt changed no production code; the baseline build,
`tests/boundary/run.sh`, the structural checker, and `write_next --check` were all green on the
unmodified tree. The external prerequisite stacks `ruff-01-lossless-source`, `ruff-05-rule-engine`,
and `ruff-06-fix-safety` remain verified and their live code was re-read against this work
(`LosslessSource` carries the node kinds + parent/child structure + leaf text the six rules read;
`Rules.lean`'s `RuleImpl.syntax` and `SyntaxFacts` are the seam RYR-IMPL implements against).

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-catalog | RYR-SPEC | verified | — |
| 02-implementation | RYR-IMPL | planned | RYR-SPEC |
| 03-acceptance | RYR-FINAL | planned | RYR-IMPL |

## Catalog summary (frozen by RYR-SPEC)

| code | family | default | fix | applicability |
| --- | --- | --- | --- | --- |
| FMT008 module docstring required | docs | preview | — | report-only |
| FMT009 unclosed section/namespace | structure | enabled | — | report-only |
| FMT010 duplicate attribute in a list | redundancy | enabled | delete dup | `.safe` |
| FMT011 duplicate deriving class | redundancy | enabled | delete dup | `.safe` |
| FMT012 development-only `set_option` | debug | enabled | — | report-only |
| FMT013 redundant nested parentheses | redundancy | preview | drop outer | `.safe` |

## Blockers and prerequisites

- No blocker. RYR-IMPL's first task is the **first-syntax-tier wiring**, scoped in
  `notes/01-catalog.md` §5: `Application.renderCanonicalText` and `availableAnalysis`'s source-only
  shortcut currently assume every rule is `.source` (pinned by `testEngineTiers`), and must learn to
  fetch the projection when a selected rule demands `.syntax`. The projection already carries what the
  rules read, so this is integration, not a missing lower layer.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching
  around it. Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful
evidence, and state agrees with live code. Missing, stale, unsupported, or unread checks are failures
to verify.
