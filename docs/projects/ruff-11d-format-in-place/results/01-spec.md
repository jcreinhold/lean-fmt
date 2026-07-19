# Results 01 — FIP-SPEC (in-place-format interface frozen)

**Claim:** FIP-SPEC. Specification-only; no executable behavior changed. The frozen interface lives
in `notes/01-model.md`; the first-hand characterization of today's `format` in
`evidence/01-current-format.md`.

## Commands run

- `LEAN_NUM_THREADS=1 lake build lean-fmt Layout:leanFmtArtifact` → `Build completed successfully
  (57 jobs).`
- `app=$(lake -q query lean-fmt --text)`
- `$app format tests/check/Layout.lean` → stdout `=== path (63 bytes) ===` … dump, summary
  `written=0`, exit **1**. `md5` unchanged → **no write** (evidence §No write).
- `$app format --json tests/check/Layout.lean` → status `would-format`, `written:false`,
  `formatted` carries canonical text, exit 1.
- `$app format tests/check/Clean.lean` → `changed=0`, exit 0 (`clean`, no framing).
- Grep for the "format never writes" claim across `CLAUDE.md docs LeanFmt tests` (grep list, model
  §4).

## Frozen decisions (see `notes/01-model.md`)

1. **Writing `format`** reuses the entire `ruff-06` publish path (`prepareFile renderCanonical:=true`
   → `analyzeSnapshot validator:=true` → `validationReport` → `publishAtomic` →
   `denormalize`), through a new `formatFile` wrapper structurally identical to `fixFile`. Status
   `formatted`, `written:=true`. Renders the `ruff-11c` layout patch only — no rule fix.
2. **Validation is required, not elided** for the pure reflow: parity with `fix`/`organize`, the
   incoming CLAUDE.md invariant text, and because `RLF-REFLOW` made `Printer.format` move bytes
   across lines (unproven to preserve elaboration). Cost is one validator child per *changed* file.
3. **`format --check`** = today's `previewFile .format`, demoted from default to opt-in flag: writes
   nothing, no validator, `would-format`/`clean`, exit 1 if any file would change (ruff CI mode).
4. **Exit codes** (model §3): writing `format` exits 0 on a published change (joins `fix`);
   `format --check` exits 1 on a would-change (keeps `check`'s code). `reportExitCode` gains a
   writing-format branch keyed on the write disposition. `check`/`diff`/`fix` codes unchanged.
5. **JSON shape unchanged** — `written` bool distinguishes publish from preview; no new field.
6. **Driver disposition:** writing `format` is NOT a `preview?` (needs the validator child), so it
   falls through to `withExactRun` like `fix` and is excluded from the cache-only preview fast paths;
   `format --check` stays a `preview?` and keeps them. The one place `--check` must reach the driver.
7. **No new frontend run for the write:** `format` already demands `.semantic` (`demandedTier`
   renderCanonical), so it always took an `analyzeExact` render pass and fetched no artifact; the
   validator rides that same `ExactRun`. Net new cost over the old preview: one validator child per
   changed file.

## Invariant-change grep list (model §4)

- **Rewrite (live):** `CLAUDE.md:52`; `LeanFmt/Application.lean:788` (and light touch `:59`);
  `LeanFmt/Semantic.lean:10`; `tests/modes/run.sh:704/712/716` (confluence comments, migrated with
  the test). Code change (not comment): `Application.lean:1064` driver dispatch → `formatFile`.
- **Leave (frozen history / still true at the core-primitive layer):**
  `execution-core-v2/roadmap.md:114` and `prompts/09-modes.md:82` (govern the mode *primitive*
  `previewFile .format`, which still renders-only; the product *verb* composes publish on top);
  `ruff-11b/roadmap.md:68`, `ruff-11c/*` notes/prompts/results, `ruff-10b/results/03-final.md:76`
  (frozen point-in-time records). Rationale: the render primitive is genuinely unchanged; only the
  product-surface policy (CLAUDE.md) flips. Rewriting a completed stack's history would falsify it.

## Reuse-vs-new (model §6)

Reused unchanged: `prepareFile`, `PreparedFile.output/.changed`, `analyzeSnapshot(validator)`,
`validationReport`, `publishAtomic`, `denormalize`, the `withExactRun` driver block, `Project.load`
discovery. New: `formatFile` (~copy of `fixFile`), a `--check` flag/field, the driver write
disposition, the rewritten `Cli.lean` output arm + `reportExitCode` branch. The frozen interface is
buildable entirely from cited real `Application.lean` definitions — no missing lower layer.

## Files changed

- `docs/projects/ruff-11d-format-in-place/evidence/01-current-format.md` (new)
- `docs/projects/ruff-11d-format-in-place/notes/01-model.md` (new)
- `docs/projects/ruff-11d-format-in-place/results/01-spec.md` (new)
- `docs/projects/ruff-11d-format-in-place/state/current.md`, `state/next.md`,
  `prompts/01-spec.md` (status planned→verified)

## Checks read

`check_stack.py --structural`, `check_prompt_architecture.py`, `write_next.py --check`,
`git diff --check` — recorded in the commit. Build + `format` CLI runs above.

## Remaining uncertainty

- Whether `formatFile` and `fixFile` should collapse into one parameterized helper or stay two
  wrappers is left to FIP-IMPL taste; the publish path must not be duplicated either way.
- The exact `Cli.lean` per-file summary wording (writing path) is FIP-IMPL's; the spec pins only that
  it is a concise summary, not the file body, and `--json` is unchanged.
</content>
