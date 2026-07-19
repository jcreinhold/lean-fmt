# RDF-FINAL results — adversarial acceptance of the layout/fix split

Status: **verified** (acceptance prompt). The decoupling holds under adversarial drive: `format`/`diff`
never write or preview a rule fix at any tier; `fix` applies every fix at original coordinates and
re-`check`s clean without reflowing; the two compose to the same fixed point in both orders; the
`ruff-11b` capability split and validator still hold; and the retired canonical-coordinate fix machinery
is gone by grep. One code change fell out of the acceptance — a source-false comment in `availableAnalysis`
that mis-described `format` as taking the artifact path — corrected below.

## Commands run

- `LEAN_NUM_THREADS=1 lake build` → clean, 42 jobs.
- `lake exe lean-fmt-tests` → `lean-fmt module-artifact tests passed`.
- Focused suites, all pass: `tests/modes/run.sh` (carries the new confluence acceptance),
  `tests/check/run.sh` (carries the new efficiency acceptance), `tests/syntax/run.sh`,
  `tests/semantic/run.sh`, `tests/lossless/run.sh`, `tests/boundary/run.sh`.
- `uv run --script .../check_prompt_architecture.py docs/projects/ruff-11c-decouple-fix-format` →
  `checked 1 stack(s): 0 error(s), 0 warning(s)`.
- `write_next.py --check` → matches `first_unresolved`; `git diff --check` → `OK: no whitespace errors`.

## The nine adversarial cases (`notes/01-model.md §9`) and where each is driven

1. **`format`/`diff` fix-free at every surviving tier.** Import FMT005: `tests/imports/run.sh:183`,
   `tests/modes/run.sh:540` (format keeps both imports, reports FMT005). Syntax `.safe` FMT013:
   `tests/syntax/run.sh:194` (format reports FMT013, leaves `((1))`). Semantic FMT014:
   `tests/semantic/run.sh:411` (format renders layout, never renames; `--unsafe-fixes` is a no-op for
   format). In each the finding survives a post-`format` `check`.
2. **`fix` at original coordinates, no reflow, layout-dirty preserved, re-check clean.** `tests/modes`
   mixed fixture (`namespace␣␣␣␣␣Alpha` kept, import deduped, `:593` re-check clean); per-tier at
   `tests/imports:183` (trailing ws untouched), `tests/syntax:189`, `tests/semantic:385`.
3. **Coordinate exactness on the interior-gap fixture.** `tests/modes` mixed fixture: `fix` removes the
   duplicate import and leaves `namespace     Alpha`'s five spaces byte-for-byte (`:588`).
4. **Composition confluence, both orders (NEW).** `tests/modes/run.sh` RDF-FINAL block: `fix; format`
   and `format; fix` both reach the identical canonical bytes, materialized and compared (`format` is a
   stdout preview, so order B captures its `formatted` to disk before `fix`). Each end state is a fixed
   point — a fresh `format` is idempotent (clean) and a fresh `check` is clean. This is a genuine
   confluence: `fix` touches only rule-defect bytes, `format` only layout bytes, so neither reopens the
   other's concern.
5. **Unsafe gating + idempotence.** `tests/semantic/run.sh:365` (`withheldUnsafe >= 1`, byte-identical),
   `:410` (second `fix` no-op); `tests/modes`/`tests/syntax` second-`format`/`fix` no-ops.
6. **Capability split intact.** `tests/semantic/run.sh:195` (info-tree fold absent from the plain
   semantic capture, present only under the occurrences capability — both directions); the
   monolithic-era cache entry still misses a fixable-FMT014 demand via `SemanticCaps.subset`
   (`cacheHitServes`). Occurrence capture now keys off `applies` (`Config.lean:333`), so it is absent
   from `format`.
7. **Retirement proof by grep.** `git grep` over `LeanFmt/*.lean`: no live `def`/call of
   `reprojectCanonical`, `patchDuplicateFindings`, or `patchImportsFor` — only retirement rationale in
   three docstrings (`Application.lean:368,394,480`). `availableAnalysis`'s `renderCanonical &&
   requiredTier == .syntax` branch is gone; `CanonicalText.findings` is deleted; the only surviving
   `result.canonical?` read (`Application.lean:447`) is the legitimate cache-serve gate (a rendering hit
   needs a cached entry that carries canonical text), not a patch source. `RulePlan.demandedCaps` no
   longer reads `renderCanonical` for `occurrences`.
8. **Formatter owns ws/newline.** `tests/modes/run.sh:618` (no rule selected: reflow trims + terminates,
   `findings == 0`), `:648` (in-string trailing whitespace preserved under both `format` and `fix` — the
   retired-FMT001 corruption cannot recur), `:674` (verbatim `#exit` tail). `git grep FMT001\|FMT002`
   returns only retirement prose; `LeanFmtTest.lean:59` asserts neither ever fires.
9. **Efficiency — the split is a net win (NEW acceptance).** `tests/check/run.sh` RDF-FINAL block:
   (a) `fix --select FMT005` (source-only) takes the source shortcut — with both the analyzer and the
   artifact disabled the dedup still applies, so it consulted neither a frontend child nor an artifact;
   (b) plain `format` and `format --select FMT013` each reach the frontend **exactly once** (one
   infrastructure failure with the analyzer disabled), never twice — the retired `reprojectCanonical` no
   longer adds a second re-projection pass. See the correction below for what `format` actually does.

## Decisions changed during execution

- **Corrected a source-false comment in `availableAnalysis` (`Application.lean:476`).** RDF-IMPL left a
  comment claiming a canonical-rendering syntax run (`format --select FMT01x`) "takes this artifact
  path." Adversarial probing showed it does not: `format` demands `.semantic` for notation-aware layout
  (`RulePlan.demandedTier` maxes to `.semantic` whenever `renderCanonical`), the plugin artifact never
  carries `semantic` (`ruff-05b`), so the driver fetches no artifact for a rendering run and it takes its
  single `analyzeExact` run. The artifact branch serves **non-rendering** syntax runs — `check`/`fix
  --select FMT01x` — which `tests/check/run.sh:160` already exercises. The efficiency win is 2 → 1
  frontend runs (the retired second re-projection), **not** frontend → artifact. Comment rewritten to say
  exactly that; no behavior changed (the code already did the right thing).
- **Confluence is materialized, not assumed.** Because `format` never writes (it prints canonical output
  to stdout; `fix` is the sole writer — `Cli.lean:163`, `Application.lean:910`), the `format; fix` order
  captures `format`'s preview to disk before `fix`. Both orders are then compared byte-for-byte rather
  than asserted equal by construction.
- **Frozen-sample review is read-only and frontend-free by necessity.** The frozen syntax sample
  (`experiments/results/syntax-rule-sample-20260718T212144Z`) has exactly one real fixable finding: FMT013
  `((ϕ i x))` (redundant nested parens, a UTF-8 boundary) in `Mathlib/GroupTheory/NoncommPiCoprod.lean`.
  The shape is still present in the current checkout, moved to normalized byte offset 7076 (the checkout
  has advanced past `mathlib-v4.32.0-sample`, so the recorded 6977 is stale — a re-projection against
  moved bytes would be meaningless). The module's `.olean` is absent, so a frontend run would rebuild the
  mathlib dependency closure, which the project constraints forbid. This exact shape is reproduced as the
  `NestedParenUtf8` miniature (`((ϕ))`) in `tests/syntax/run.sh:199`, driven through the **real** frontend,
  where `fix` deletes the outer parens at original UTF-8-boundary coordinates and `format` leaves `((ϕ))`
  untouched — the frozen-sample behavior, proven on the real parser without a mathlib build.

## Checks read, and remaining uncertainty

- Manual review of every applied fix in the new tests: the occurrence/edit text, its original coordinates,
  and the re-`check`. No `Environment`/`InfoTree`/`Position`/`FileMap` crosses into a rule (rules run over
  facts only; `tests/boundary` passes).
- **Pre-existing, out of scope:** `tests/printer/run.sh`'s stale-evidence census (541 recorded vs 660
  live commands) against a frozen ruff-03 record the stack forbids rewriting — carried from RDF-LAYOUT,
  not introduced here.
- Full mathlib was not run; the frozen sample and named stress cases cover the coordinate/UTF-8/multi-edit
  shapes. No remaining uncertainty on the decoupling — the stack is complete.
