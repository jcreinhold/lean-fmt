---
claim_id: RDF-IMPL
status: planned
depends_on: [RDF-SPEC]
---

# Implement the layout/fix split

## Task

Deliver **RDF-IMPL**: Implement the frozen split. `format`/`diff` render canonical layout and apply
**no** rule fix; `fix` applies admitted fixes at original coordinates and does **not** reflow; `check`
is unchanged. Move every rule fix and FMT014's occurrence capture onto the base (original-coordinate)
analysis, retire the canonical-coordinate fix machinery, and keep the `ruff-11b` capability split and
the `ruff-06` validator/transaction intact. Remove the retired path; do not leave a parallel one.

Read `roadmap.md`, `results/01-spec.md` (the frozen interface and the chosen design), `notes/01-model.md`,
`AGENTS.md`, and the current implementation and tests before changing an interface. Write or update the
characterization tests that pin `format`-applies-no-fix and `fix`-at-original-coordinates before the
implementation where the behavior is not already frozen.

## Target

- Implement behind the private `Application` boundary; keep CLI presentation in `LeanFmt.Cli` and
  lifecycle/cache/project complexity below callers.
- `LeanFmt/Application.lean`:
  - `RunMode.rendersCanonical`: `fix` becomes `false`; only `format`/`diff` render canonical.
  - `prepareFile` (or the `prepareLayout`/`prepareFix` split the spec chose): a **layout** patch bases
    on `canonical.text` and carries no rule fix; a **fix** patch bases on `normalized` and carries the
    admitted fixes from the original-coordinate `result.findings ++ reportImports`. Admission stays
    `Applicability.admitted unsafeFixes`; the conflict/transaction/validator path is unchanged.
  - Retire `ExactRun.reprojectCanonical`'s fix-carrying and occurrence/semantic re-capture role and its
    `(captureSemantic captureOccurrences)` parameters, `patchDuplicateFindings`/the canonical
    `patchImports` recomputation, and the `result.canonical?`-as-patch-source branch. If
    `reprojectCanonical` (or `canonicalAnalysis`'s syntax re-projection) has no remaining render-only
    caller, remove it; if it retains a render-only role, narrow it to that.
- `LeanFmt/Analysis.lean`: FMT014's occurrences are captured in the base `analyzeExact` under demand at
  original coordinates (the walk already runs there for diagnostics); the rename attaches to the
  original-coordinate finding. The occurrence demand trigger becomes a `fix`/`check` selecting FMT014
  against the base analysis, not a canonical re-projection.
- Preserve unchanged: the `ruff-11b` capability split (`SemanticCaps`, the `SemanticResult` capability
  field, `cacheHitServes` `demandedCaps ⊆ caps`, `Tier.satisfies`); the `ruff-11b` fixable predicate
  `spelled == occurrenceDisplay declName`; the `ruff-06` applicability, conflict rejection, atomic
  transaction, output re-elaboration validator, and stale-source pre-check; every rule's report; and
  the invariant that `check`/`format`/`diff` never write source.
- Add or update persistent regression tests at the owning layer (`LeanFmtTest.lean`, `tests/modes`,
  `tests/check`, `tests/syntax`, `tests/semantic`, `tests/lossless`): a mixed fixture (bad layout **and**
  an admitted fixable finding) where `format` reflows but leaves the finding and `fix` applies the
  finding at original coordinates without reflowing; FMT005, a syntax `.safe` fix, and FMT014's rename
  each applied by `fix` at original coordinates and absent from `format`; `diff` equals a `format`
  preview.

## Plan

1. Write/adjust the characterization tests that separate layout from fix (they should fail against the
   current fused behavior).
2. Flip `RunMode.rendersCanonical` for `fix` and rebase the fix patch onto normalized coordinates.
3. Make `format`/`diff` patches carry no rule fix.
4. Move FMT014 occurrence capture to the base analysis; retire the reproject fix/occurrence parameters,
   `patchDuplicateFindings`, and the canonical patch-source branch.
5. Re-run the affected suites; inspect every touched boundary for a leaked mechanism or a parallel
   retired path left behind.

## Stop

- `format`/`diff` must apply no rule fix; `fix` must not reflow. Do not blend them to make a test pass.
- No fix computed or applied at canonical coordinates. Do not weaken the capability split, the
  validator, exact semantics, write safety, or cache identity.
- Stop rather than leaving both the new and the retired path live, or giving rules lifecycle authority.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused suites named by touched modules
  (`tests/modes/run.sh`, `tests/check/run.sh`, `tests/syntax/run.sh`, `tests/semantic/run.sh`,
  `tests/lossless/run.sh`, `lake exe lean-fmt-tests`).
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-11c-decouple-fix-format`.
- Run `git diff --check` and read all output before marking RDF-IMPL verified. Write `results/02-impl.md`
  with commands, outputs or evidence locators, decisions changed during execution, files changed, checks
  read, and remaining uncertainty; update `state/current.md` after reading the checks, then regenerate
  `state/next.md`.
