---
kind: state
first_unresolved: 03-acceptance
---

# Current state

`RYR-SPEC` and `RYR-IMPL` are **verified**. The six syntax-tier rules **FMT008–FMT013** frozen by the
catalog (`notes/01-catalog.md`) are implemented and shipping — all as **preview** (default-off). What
was run is `results/02-implementation.md`; the design and the mid-implementation repair are
`notes/02-implementation.md`. Rules are `RuleImpl.syntax` bodies reading the `LosslessSource`
projection through total helpers; FMT010/011/013 carry `.safe` byte-range fixes reported on original
coordinates, FMT008/009/012 are report-only. The first-syntax-tier cache wiring is in place: a
`SemanticResult.tier` tag (schema `v5`) with a `cacheHitServes` gate keeps a source-only shortcut entry
from serving a `.syntax` `--select` a false negative, while the universal `.syntax` entry serves any
selection. Selection gained a `default` selector (the `defaultEnabled` rules) that the default config
now uses instead of `"all"`. All eleven build/test gates are green, including the new
`tests/syntax/run.sh`; the structural checker and `write_next --check` pass; `git diff --check` is clean.

The one deliberate deferral: `format`/`fix` render canonical text and run only source rules, so a
syntax `.safe` fix is *reported* by `check` but not *applied* by `fix`. `ruff-06`'s RFX-SPEC owns
canonical-coordinate syntax fixing; the limit is documented (`Application.renderCanonicalText`) and
pinned by `tests/syntax/run.sh`.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-catalog | RYR-SPEC | verified | — |
| 02-implementation | RYR-IMPL | verified | RYR-SPEC |
| 03-acceptance | RYR-FINAL | planned | RYR-IMPL |

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

- No blocker. The first-syntax-tier wiring RYR-SPEC scoped as owed is done: `cacheHitServes` gates on
  `tier`, and `availableAnalysis` fetches the projection when a selected rule demands `.syntax`.
  RYR-FINAL is acceptance — measure FMT013's true prevalence on the frozen sample, assert the FMT009
  whole-file-section exclusion and near-misses at corpus scale, and decide FMT012's `set_option … in`
  coverage. Do **not** run full mathlib during development; use the frozen sample and named stress
  cases (`CLAUDE.md`).
- Open deferral (not a blocker): canonical-coordinate syntax *fix application* is owned by `ruff-06`'s
  RFX-SPEC. `fix` reports a syntax `.safe` fix but does not apply it; the limit is documented and
  pinned.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching
  around it. Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful
evidence, and state agrees with live code. Missing, stale, unsupported, or unread checks are failures
to verify.
