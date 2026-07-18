---
kind: state
first_unresolved: none
---

# Current state

`RYR-SPEC`, `RYR-IMPL`, and `RYR-FINAL` are **verified** — the stack is complete. The six syntax-tier
rules **FMT008–FMT013** frozen by the catalog (`notes/01-catalog.md`) are implemented, shipping — all
as **preview** (default-off) — and have passed a frozen-sample differential and false-positive review
(`results/03-acceptance.md`). What was run in implementation is `results/02-implementation.md`; the
design and the mid-implementation repair are `notes/02-implementation.md`. Rules are `RuleImpl.syntax`
bodies reading the `LosslessSource` projection through total helpers; FMT010/011/013 carry `.safe`
byte-range fixes reported on original coordinates, FMT008/009/012 are report-only. The first-syntax-tier
cache wiring is in place: a `SemanticResult.tier` tag (schema `v5`) with a `cacheHitServes` gate keeps a
source-only shortcut entry from serving a `.syntax` `--select` a false negative, while the universal
`.syntax` entry serves any selection. Selection gained a `default` selector (the `defaultEnabled` rules)
that the default config now uses instead of `"all"`.

RYR-FINAL ran the six rules over the frozen 62-module mathlib sample through the exact frontend and
reviewed every finding: **one true positive** (FMT013 `((ϕ i x))` in `NoncommPiCoprod.lean`, a genuine
redundant outer pair mathlib has no linter for) and **one false positive** (FMT009 miscounting
`end Alpha.Beta`), which was a real correctness bug in the shipped rule and was **fixed** here with
name-stack matching and two regression fixtures. Category coverage the prompt names — custom syntax,
quotations, generated syntax, comments, malformed, both applicability classes, and the FMT012
`set_option … in` scoped form — is closed by persistent fixtures. No rule was demoted; all six remain
preview. All twelve build/test gates are green, including `tests/syntax/run.sh`; the structural checker
and `write_next --check` pass; `git diff --check` is clean.

The one deliberate deferral: `format`/`fix` render canonical text and run only source rules, so a
syntax `.safe` fix is *reported* by `check` but not *applied* by `fix`. `ruff-06`'s RFX-SPEC already
*froze the model* for this — a syntax-tier fix composes by **re-projecting the canonical text**, not by
translating original-coordinate edits onto moved bytes — and handed the wiring and adversarial exercise
forward to the stack that ships the first syntax-tier rule with a fix. ruff-10 is that stack for
*reporting*; the `fix`-command *application* wiring is owned by the successor stack
**`ruff-10b-syntax-fix-composition`** (RYC-SPEC/IMPL/FINAL). The current limit is documented
(`Application.renderCanonicalText`) and pinned by `tests/syntax/run.sh`.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-catalog | RYR-SPEC | verified | — |
| 02-implementation | RYR-IMPL | verified | RYR-SPEC |
| 03-acceptance | RYR-FINAL | verified | RYR-IMPL |

## Catalog summary (frozen by RYR-SPEC)

| code | family | default | fix | applicability |
| --- | --- | --- | --- | --- |
| FMT008 module docstring required | docs | preview | — | report-only |
| FMT009 unclosed section/namespace | structure | preview | — | report-only |
| FMT010 duplicate attribute in a list | redundancy | preview | delete dup | `.safe` |
| FMT011 duplicate deriving class | redundancy | preview | delete dup | `.safe` |
| FMT012 development-only `set_option` | debug | preview | — | report-only |
| FMT013 redundant nested parentheses | redundancy | preview | drop outer | `.safe` |

All six ship preview; RYR-IMPL corrected FMT009–FMT012 off `enabled` (rationale:
`notes/01-catalog.md` §3, `results/02-implementation.md`).

## Blockers and prerequisites

- No blocker; the stack is complete. The first-syntax-tier wiring RYR-SPEC scoped as owed is done:
  `cacheHitServes` gates on `tier`, and `availableAnalysis` fetches the projection when a selected rule
  demands `.syntax`. RYR-FINAL closed the three questions it inherited: FMT013's frozen-sample
  prevalence is one true positive in 62 modules with zero false positives; FMT009's dotted-`end`
  scope counting is fixed and regression-pinned; FMT012 fires on the `set_option … in` scoped form
  uniformly (same command node, report-only). Full mathlib was not run — development evidence is the
  frozen sample and named stress cases (`CLAUDE.md`).
- Open deferral (not a blocker): canonical-coordinate syntax *fix application* is owned by the
  successor stack **`ruff-10b-syntax-fix-composition`**. `ruff-06`'s RFX-SPEC froze the composition
  model (re-project canonical text) and handed the wiring forward to the stack shipping the first
  syntax-tier rule with a fix; ruff-10 delivered the rules and reports the fixes, and ruff-10b wires the
  `fix`-command re-projection and exercises the adversarial cases. `fix` reports a syntax `.safe` fix
  but does not apply it; the limit is documented and pinned.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching
  around it. Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful
evidence, and state agrees with live code. Missing, stale, unsupported, or unread checks are failures
to verify.
