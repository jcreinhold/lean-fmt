---
claim_id: RDF-FINAL
status: planned
depends_on: [RDF-IMPL]
---

# Adversarial acceptance for the layout/fix split

## Task

Deliver **RDF-FINAL**: Accept the decoupling adversarially. `format`/`diff` never write or preview a
rule fix at any tier; `fix` applies every fix at original coordinates and re-`check`s clean without
reflowing; the two compose in both orders; the `ruff-11b` capability split and validator still hold; and
the retired canonical-coordinate fix machinery is gone. Prove it through the product CLI and persistent
tests at the owning layer, and by direct inspection of the surviving surface.

Read `roadmap.md`, `notes/01-model.md`, `results/01-spec.md`, `results/02-impl.md`, `AGENTS.md`, and the
current implementation and tests before changing an interface. Write characterization tests before any
adjustment where the behavior is not already frozen.

## Target

Drive, through the product `check`/`format`/`diff`/`fix` CLI and persistent tests at the owning layer:

- **`format`/`diff` are fix-free at every tier.** On fixtures whose only defect is (a) a source-tier
  fixable finding, (b) a syntax-tier `.safe` fix (FMT008-class), and (c) FMT014's semantic rename,
  `format` reflows and `diff` previews the reflow, and **neither applies the fix** — the finding
  survives a post-`format` `check`. Applies with and without `--unsafe-fixes`.
- **`fix` applies at original coordinates, no reflow.** Each of (a)/(b)/(c), admitted, is rewritten by
  `fix` at the file's own bytes; the surrounding layout is **unchanged** (a badly-laid-out but
  otherwise-only-that-defect fixture keeps its layout); a fresh `check` of the written file is clean.
- **Coordinate exactness.** A fix on a fixture with an interior layout gap the printer would close
  (e.g. `namespace     Alpha`, `RFP-SPEC`'s measured four-byte deletion) lands on the correct original
  bytes — because it now indexes the same normalized string it is reported against, never reflowed text.
- **Composition, both orders.** `fix` then `format` and `format` then `fix` each reach a fixed point;
  pin their convergence, or record a specific, understood divergence (a fix whose bytes the reflow then
  re-lays-out) rather than asserting a false confluence.
- **Unsafe gating and idempotence.** `fix` without admission withholds an unsafe fix (reported,
  byte-identical, `withheldUnsafe >= 1`); a second `fix` is a no-op; a second `format` is a no-op.
- **Capability split intact.** The info-tree walk is absent from a plain `format` and from a
  surfaced-only FMT014 `check`, and present only under the fixable demand (now on the base analysis);
  the monolithic-era cache entry still **misses** a fixable-FMT014 demand rather than serving a false
  clean (`SemanticCaps.subset` at the predicate layer).
- **Retirement proof.** `reprojectCanonical` is gone entirely (grep returns nothing), along with its
  `(captureSemantic captureOccurrences)` parameters, `availableAnalysis`'s `renderCanonical &&
  requiredTier == .syntax` branch, `patchDuplicateFindings`, the `result.canonical?`-as-patch-source
  branch, and any dead `CanonicalText.findings` surface. `RulePlan.demandedCaps` no longer reads
  `renderCanonical`.
- **Efficiency (the decoupling is a net win, not just neutral).** Confirm `format --select FMT01x` no
  longer forces a second frontend run (it takes the artifact path): count the exact-frontend invocations
  or wall-time delta on a named stress file, `format` before vs after. Confirm `fix` on a source-only
  selection now takes the source shortcut. Report both against the 8 GiB / pressure / swap envelope; do
  not run complete mathlib.
- **Frozen-sample read-only review.** On the frozen representative sample, confirm `format` output is
  reflow-only (no rule fix applied) and that a `fix` of any real fixable finding there lands at original
  coordinates. Do not run complete mathlib.

Manually review every applied fix for exactness — the occurrence/edit text, its coordinates, and the
re-`check` — and confirm no `Environment`/`InfoTree`/`Position`/`FileMap` crosses into a rule.

## Plan

1. Build the tier-crossed fixtures (source/syntax/semantic × layout-dirty) and the composition/order
   cases.
2. Drive each through the product CLI and pin it with a persistent regression test at the owning layer.
3. Exercise positive, negative, unsafe-gated, idempotent, stale, custom-syntax, and Unicode cases, plus
   the capability demand-gating both directions.
4. Prove the retirement by inspection and grep; inspect callers and docs for any surviving claim that
   `format` applies fixes.

## Stop

- No `format`/`diff` write or preview of any rule fix; no `fix` reflow; no fix at canonical coordinates.
- The capability split, `Tier.satisfies` soundness, the validator, exact semantics, write safety, and
  cache identity must all still hold. `check`/`format`/`diff` never write.
- No full mathlib run in this stack. Stop rather than weakening any preserved invariant.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused suites (`tests/modes/run.sh`, `tests/check/run.sh`,
  `tests/syntax/run.sh`, `tests/semantic/run.sh`, `tests/lossless/run.sh`, `lake exe lean-fmt-tests`).
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-11c-decouple-fix-format`.
- Run `git diff --check` and read all output before marking RDF-FINAL verified. Write `results/03-final.md`
  with exact commands, raw outputs or evidence locators, decisions changed during execution, and
  remaining uncertainty; update `state/current.md` after reading the checks, then regenerate
  `state/next.md`.
