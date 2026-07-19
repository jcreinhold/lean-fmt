---
claim_id: RRL-FINAL
status: verified
---

# RRL-FINAL — audit the complete rule catalog

Runs the acceptance matrix over the RRL-IMPL catalog: metadata invariants, executable examples,
selector precedence, preview/deprecation migrations, suppression interaction, and documentation link
checks. The audit found and fixed one frozen-spec gap (retired-only suppression inertness, §7), added
persistent regressions for the previously-uncovered precedence edges and the migration/link surfaces,
and — on the promotion question the lifecycle model deliberately left open (§4/§12) — **promotes no
FMT008–FMT017 preview rule to stable or default-on**, on the reasoning below.

## Audit dimensions and coverage

| Dimension (prompt) | Where enforced | Result |
| --- | --- | --- |
| Metadata invariants | `LeanFmtTest.testCatalogInvariants` | pass (code shape/uniqueness, namespace disjointness, lifecycle/default coherence, doc-count, schema-vocabulary coverage) |
| Executable examples | `tests/catalog/run.sh` | pass — 12 examples across 15 live rules through the exact frontend; each `bad` fires only its rule, each fixable `fix` yields `good` and is idempotent |
| Selector precedence matrix | `LeanFmtTest.testConfig` | pass — exact>category>all/default, tie→ignore, CLI-replaces-config, extend-select-adds-across-layers, all-vs-default, preview gate on category and exact code, fixability axis |
| Preview/deprecation migration | `testConfig` + `tests/catalog/run.sh` | pass — preview gate (exact→error, category→omit), retired-selector notice, `explain` on live/retired/unknown; deprecated-notice path implemented (`Config.lean:340`) though no live rule is deprecated |
| Suppression interaction | `testSuppression` + `tests/suppression/RetiredInert.lean` | pass — retired-only directive inert (no FMT900), mixed retired+live keeps per-code analysis, retired code never named in the unused report |
| Documentation link check | `tests/catalog/run.sh` | pass — every index link resolves, every live rule has a linked page, `schema.json` referenced and present |

## Gap found and fixed — retired-only suppression inertness (§7)

`notes/01-schema.md` §7 froze a non-breaking floor: *a suppression naming only reserved/retired codes is
inert — it suppresses nothing and is not FMT900-flagged.* RRL-IMPL implemented the **selector** half of
§7 (accept-with-notice) but not the **suppression** half: `-- lean-fmt: ignore[FMT001]` was still
reported unused (FMT900), the exact misleading nag §7 forbids.

Fixed in `LeanFmt/Suppression.lean`: the unused analysis excludes reserved codes from the dead set
(`!isReservedCode code`) and preserves them in any list-trim (`keep = used ++ reserved`). A retired-only
directive now raises nothing; a mixed directive keeps normal per-code analysis for its live codes and
never names the inert retired one. Covered by four new `testSuppression` cases and the real-frontend
`tests/suppression/RetiredInert.lean` (FMT005 still reports, suppressed 0, no FMT900). This is the §7
non-breaking floor, not a scope expansion.

## Promotion decision — no graduation this stack

The lifecycle model (§4) leaves stable/default-on promotion to RRL-FINAL "on reviewed frozen-sample
precision." Decision: **FMT008–FMT017 stay preview / default-off.** Reasons, independent of a fresh run:

1. **Default-on is the frontend-free correctness/security floor.** The default set (FMT003–FMT007) is
   source-tier and needs no compiler frontend. Every preview rule is syntax- or semantic-tier; ruff-10's
   own RYR-IMPL note flagged that a default-on syntax rule "forces all files onto the exact frontend" — a
   per-file cost that belongs to `ruff-16`/`ruff-19`, not a lifecycle default. FMT008–FMT017 are also
   *opinionated* (require a module docstring, forbid dev `set_option`, strip redundant parens, flag
   unused binders/naming) — appropriately opt-in, as the equivalents are in ruff.
2. **`stable` is a meaning-freeze promise not yet earned.** Each preview rule's *correctness* was
   reviewed on the frozen 62-module sample by its owning stack (ruff-10 RYR-FINAL: FMT008–013, 1 TP + 1
   FP fixed, 0 broken; ruff-11: FMT014–017). But `stable` promises the meaning will not change without a
   new code; these rules are newly integrated and carry no forcing reason to freeze now. `preview`
   honestly signals "may still evolve."

**Fresh frozen-sample re-run: now performed at `v4.33.0-rc1`.** `experiments/run-lifecycle-precision-sample.sh`
(new; extends ruff-10's `run-syntax-rule-sample.sh` to all ten preview rules with the `--preview` gate)
was originally blocked because the local `~/Code/mathlib4` had advanced to `leanprover/lean4:v4.33.0-rc1`
(HEAD `8c79cb4`) while this build was `v4.32.0` (`783ccda`) and lean-fmt's toolchain guard correctly
rejected the mismatch. That mismatch was resolved by bumping lean-fmt's own toolchain to
`v4.33.0-rc1` to match `mathlib4` (the maintainer's working version), rather than checking `mathlib4`
back to the pinned `v4.32.0` commit — so the run measures precision at the toolchain the project now
ships on, not a reproduction of the owning stacks' `v4.32.0` reviews. With both aligned and mathlib's
`v4.33.0-rc1` olean cache in place (`lake exe cache get`), the script ran clean over all 62 modules:
**0 broken, 0 infrastructure failures, and exactly one finding** — a single true-positive FMT013
(redundant nested parentheses) in `Mathlib/GroupTheory/NoncommPiCoprod.lean` (`((ϕ i x))`, where the
outer parens wrap a complete application already sitting as one argument). Every self-linted rule
(FMT008–012, FMT014–017) found nothing, and FMT013 — the one preview rule with no mathlib linter
equivalent — surfaced one genuine hit and no false positives. The measured false-positive count is
therefore **zero across the sample**, corroborating rather than altering the promotion decision: the
factors above (default-on cost/opinionation, premature-freeze) already decided it, and the fresh
numbers confirm the preview set is low-noise. `experiments/results/` is gitignored, so the raw
`findings.tsv`/`status.tsv`/`summary.txt` live under
`experiments/results/lifecycle-precision-sample-v4.33.0-rc1/` locally, not in the tree.

## Commands

```
$ LEAN_NUM_THREADS=1 lake build                 # success
$ lake exe lean-fmt-tests                        # passed (invariants + precedence matrix + §7 suppression)
$ tests/catalog/run.sh                           # examples + explain contract + docs drift + doc links; passed
$ tests/suppression/run.sh                       # passed (adds RetiredInert.lean)
$ tests/boundary/run.sh                          # Rules.lean out of the plugin closure; passed
$ tests/modes/run.sh  tests/check/run.sh         # passed
$ tests/syntax/run.sh tests/semantic/run.sh      # passed
$ tests/service/run.sh tests/lossless/run.sh tests/compiler/run.sh tests/scale/run.sh   # passed
$ STAMP=v4.33.0-rc1 experiments/run-lifecycle-precision-sample.sh  # 62 modules: 0 broken, 0 infra, 1 finding (FMT013 TP), 0 FP
```

Evidence cited: `docs/projects/ruff-10-syntax-rules/results/03-acceptance.md` (frozen-sample review,
FMT008–013), `docs/projects/ruff-11-semantic-rules/` (FMT014–017).

## Decisions changed during execution

- **Retired-only suppression inertness was unimplemented** (RRL-IMPL delivered only the §7 selector
  half). Implemented here rather than deferred — it is the frozen non-breaking floor and a small,
  well-specified fix.
- **The promotion decision is policy-driven, and now also run-confirmed.** The fresh frozen-sample run
  was initially blocked by toolchain drift, so the decision was first made on policy (default-on
  cost/opinionation, premature-freeze) plus the owning-stack reviews. After the project's toolchain was
  bumped to `v4.33.0-rc1`, the run completed (0 FP, 1 FMT013 TP over 62 modules) and corroborates the
  decision without changing it.

## Remaining uncertainty

- **The `deprecated` lifecycle is implemented but unexercised by a live rule.** The notice/replacement
  path (`Config.lean:340–342`) is code-reviewed and shares the retired-notice mechanism, but no live rule
  is deprecated, so there is no end-to-end deprecated-rule migration fixture. It becomes testable the
  first time a rule is actually superseded.
- **Optional retired-only suppression advisory** (§7/§13, a distinct "names a retired rule" code) is
  deliberately not added; the non-breaking floor (silent acceptance) is the frozen requirement and is now
  met.
- **Fresh whole-sample precision numbers** are now measured at `v4.33.0-rc1` (0 FP, 1 FMT013 TP over 62
  modules), not at the pinned `v4.32.0` commit; the project moved up to match `mathlib4` rather than
  pinning it back. The owning-stack `v4.32.0` reviews remain the record for that toolchain; a `v4.32.0`
  reproduction would still require a `mathlib4` checkout at `783ccda`.
