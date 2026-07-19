# RDF-IMPL results — the layout/fix split

Status: **verified** (implementation prompt). `prepareFile`'s single canonical patch is split into a
**layout patch** (`format`/`diff`: reflow only, no rule fix applied or previewed) and a **fix patch**
(`fix`; `check` computes it for its report: admitted fixes at the file's own **original** coordinates, no
reflow). A user now composes the two exactly as `ruff check --fix && ruff format`. Every surviving fix
(import FMT005, syntax `.safe`, semantic FMT014) and the `ruff-11b` capability split are preserved;
`reprojectCanonical` and the canonical-coordinate fix composition are retired. Full build clean; every
touched suite passes; the architecture gate, `write_next.py --check`, and `git diff --check` are green.

## Commands run

- `LEAN_NUM_THREADS=1 lake build` → clean, 42 jobs.
- `lake exe lean-fmt-tests` → `lean-fmt module-artifact tests passed`.
- Focused suites named by the touched modules, all pass:
  - `tests/modes/run.sh` (the end-to-end split: `format`/`diff` reflow and report but apply nothing;
    `fix` applies at original coords and does not reflow; `diff` equals a `format` preview).
  - `tests/check/run.sh` (`format Findings.lean` now exits 0/clean yet reports the same finding as
    `check` — the report policy is frozen; only application differs).
  - `tests/syntax/run.sh` → `... syntax-tier rule integration tests passed` (FMT013 `.safe` applied by
    `fix` at original coords **and** absent from `format`; RYC-era `reprojectCanonical`/canonical-offset
    comments corrected to original-coordinate mechanics).
  - `tests/semantic/run.sh` → `... RMR-FINAL acceptance tests passed`; `mixed-tier: one run reported
    ['FMT013', 'FMT014']` (FMT014 rename applied by `fix` at original coords **and** absent from
    `format`; the two stale `reprojectCanonical`/"re-projected" comments corrected).
  - `tests/imports/run.sh` (FMT005 dedup applied by `fix` at original coords leaving trailing whitespace
    **untouched**; `format` trims the whitespace but keeps the duplicate and reports FMT005 — the two
    modes touch disjoint bytes).
  - `tests/suppression/run.sh`, `tests/service/run.sh`, `tests/lossless/run.sh`, `tests/scale/run.sh`,
    `tests/compiler/run.sh`, `tests/boundary/run.sh` — all pass.
- `tests/boundary/run.sh` → `lean-fmt native module and dependency boundary passed`; the changed module
  boundaries are `LeanFmt/Application.lean`, `LeanFmt/Config.lean`, `LeanFmt/Semantic.lean` only —
  inspected manually (below), no new cross-module dependency and no new public surface.
- `uv run --script .../check_prompt_architecture.py docs/projects/ruff-11c-decouple-fix-format` →
  `checked 1 stack(s): 0 error(s), 0 warning(s)`.
- `write_next.py --check` (below) and `git diff --check` → `OK: no whitespace errors`.

## What changed and why

**The apply signal is now distinct from the render signal.** `RunMode.rendersCanonical` is `true` for
`format`/`diff` only and `false` for `check`/`fix` (`Application.lean:45`). A new `applies := request.mode
== .fix` (`Application.lean:1000`) is the fix signal. `format`/`diff` render but apply nothing; `fix`
applies but does not render — the two are orthogonal, so neither one can proxy for the other.

**Occurrence capture keys off `applies`, not render.** `RulePlan.demandedCaps` takes both flags and sets
`occurrences := applies && plan.selectsOccurrenceRule` (`Config.lean:329-333`). FMT014's occurrence facts
are captured for `fix`/`check` (which needs them for its report), never for `format`/`diff`, which apply
no rename. `notations` still keys off `renderCanonical`. `cacheHitServes` gates on the same
`demandedCaps` (`Application.lean:455`).

**`CanonicalText` is layout only.** Its `findings` field is deleted (`Semantic.lean:19`): the layout
projection carries text, never findings. `renderCanonicalText` returns `{ text }` with no
`runSourceRules` pass (`Application.lean:372`). The serialized shape changed, so
`semanticResultSchema` bumped **v7 → v8** (`Semantic.lean:95`) with a changelog paragraph.

**`prepareFile` chooses the base by mode.** For `format`/`diff` the base is `canonical.text` carrying no
fix; for `fix`/`check` the base is the normalized original carrying the admitted fixes at original
coordinates. The retired `ExactRun.reprojectCanonical`, `patchDuplicateFindings`, `patchImportsFor`, the
`needsSyntax`/`patchImports` parameters, and the `result.canonical?`-as-patch-source branch are all
gone (grep below).

## Required regressions added (each fix applied by `fix` at original coordinates, absent from `format`)

- **FMT005 (import), `tests/imports/run.sh:183`.** One file with a duplicate import *and* trailing
  whitespace: `fix` removes the duplicate at original coords and leaves the trailing whitespace; `format`
  trims the whitespace, keeps both imports, and reports FMT005. Disjoint bytes — the split made visible.
- **Syntax `.safe` (FMT013), `tests/syntax/run.sh:194`.** `fix` rewrites `((1))` → `(1)`; `format
  --select FMT013` on the same already-layout-canonical fixture reports FMT013 but leaves `((1))`
  byte-for-byte.
- **Semantic FMT014 rename, `tests/semantic/run.sh:411`.** `fix --unsafe-fixes` publishes `oldName ->
  newName`; `format --unsafe-fixes --select FMT014` renders layout only and never renames — `useOld :=
  oldName` survives.
- **`diff` equals a `format` preview** and **`fix` does not reflow** are pinned in the `tests/modes`
  mixed fixture (namespace reflow appears in `diff`/`format`, never the import removal; `fix` removes the
  duplicate import and keeps `namespace     Alpha`'s five spaces).

## Changed module boundaries (manual inspection)

- `LeanFmt/Application.lean` — the driver, `prepareFile`, `availableAnalysis`, `analyzeSnapshot`,
  `renderCanonicalText`, `RunMode.rendersCanonical`. Deletions only widen no boundary; the three
  surviving `reprojectCanonical` mentions are retirement rationale in docstrings (lines 368, 394, 480),
  not live defs or calls.
- `LeanFmt/Config.lean` — `RulePlan.demandedCaps` gained the `applies` parameter; still pure projection
  over a plan, no execution-strategy leak.
- `LeanFmt/Semantic.lean` — `CanonicalText` shrank to `{ text }`; schema bumped. No new import.

The cache identity (`Cache.lean` hashes the whole `lean-fmt` binary) auto-invalidates every stale
`CanonicalText` entry from a prior binary; no migration code exists or is needed.

## Decisions changed during execution

- **`CanonicalText.findings`: delete the field, do not populate-with-empty.** On the user's "no cruft"
  instruction, the field is removed outright (driving the v7→v8 schema bump) rather than kept and fed an
  empty array.
- **Trailing-whitespace fixtures are built at runtime, never committed** (`printf` into scratch paths on
  the trap), because a committed trailing-ws fixture fails `git diff --check`. The FMT005 import
  regression and the suppression/modes movement fixtures all follow this.
- **RYC/RMR-era comments in `tests/syntax` and `tests/semantic` were source-false after the split**
  (they described `reprojectCanonical` and canonical-coordinate composition). Corrected in place to the
  original-coordinate mechanics; the tests already passed, but the prose would have rotted.

## Checks read, and remaining uncertainty

- Retired-symbol grep over `LeanFmt/`: no live `def`/call of `reprojectCanonical`,
  `patchDuplicateFindings`, `patchImportsFor`, or `CanonicalText.findings`; the only matches are
  retirement rationale in docstrings.
- **Pre-existing, out of scope:** `tests/printer/run.sh`'s stale-evidence census (541 recorded vs 660
  live commands) against a frozen ruff-03 record the stack forbids rewriting — carried forward from
  RDF-LAYOUT (`results/02-layout.md`), not introduced here; the load-bearing corpus walk is `failures=0`.
- Full mathlib was not run (development-evidence prohibition); the frozen sample and named stress cases
  cover the coordinate/UTF-8/multi-edit shapes.
- No remaining uncertainty on the split itself. The adversarial acceptance sweep is **04-final**
  (RDF-FINAL), which re-verifies the nine enumerated cases in `notes/01-model.md §9`.
