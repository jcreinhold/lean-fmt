# RIR-IMPL — Implement import diagnostics and organizer

**Verified.** The import family from `notes/01-semantics.md` ships: three `imports`-category
diagnostics (FMT005 duplicate with a safe fix, FMT006 redundant report-only, FMT007 order/grouping
report-only) and one private organizer exposed as the `organize` CLI command. This records what was
built, what was run, and what changed while running it.

## The headline

**The import rules live *outside* the linear-tier `RuleImpl` engine, and that is the whole design.**
The spec froze two facts that forced it (`notes/01-semantics.md` §1b, §7): import rules read the
surface header `[0, headerStop)`, but the syntax projection the `RuleImpl` engine runs over *drops*
exactly that region; and redundancy is a graph fact a pure, IO-free `RuleImpl` cannot compute. So the
import layer is a small IO seam of its own — `LeanFmt/Imports.lean` (pure header rules over the
existing header model) plus a private `Project` graph operation (`importClosures` over `transImports`)
— merged into the report *after* the cache/analyzer and *before* selection. FMT006 depends on **other
files** through the graph, so it must never enter the source-digest cache; import findings are
recomputed fresh every run.

## What was built

- **`LeanFmt/Imports.lean` (new).** Pure functions over the frozen header model: `duplicateFindings`
  (FMT005, `.safe` fix deleting the later line), `orderFindings` (FMT007, `fix? = none` —
  report-only), `redundantFindings … (closureOf)` returning `Array Finding × Nat` (FMT006 findings
  plus the withheld count), and `organize` (the sort/dedup rewrite over the surface header). No
  `RuleImpl`, no registry entry — the header region is invisible to the engine, so these are called
  directly.
- **Registry surface (`Rules.lean`, `Config.lean`).** `importRuleInfos` and `allRuleInfos :=
  ruleRegistry.map (·.info) ++ importRuleInfos`; `allRulesJson` projects import rules onto the
  `source` tier for the wire shape. Category selection (`isCategory`, `selectorsValid`,
  `expandSelector`) now folds over `allRuleInfos`, so `--select imports` and `--select FMT005/6/7` are
  registry-derived — the validator cannot drift from what actually runs.
- **Graph seam (`Project.lean`).** `importClosures (workspace) (names)` fetches `mod.transImports`
  under `startBuild`/`.wait`, one shared fetch across all target files (no per-file Lake work), a
  graceful `#[]` on a missing module.
- **Merge + coordinates (`Application.lean`).** Import findings are gated per rule on
  `plan.selected.contains` and merged into `result.findings` at `normalized` source coordinates. The
  FMT005 auto-fix is recomputed at `canonical.text` coordinates (`patchDuplicateFindings`), because
  the printer keeps duplicates — the same `result.findings` vs `canonical.findings` split the
  `RuleImpl` fixes already use. `RunReport`/`FileReport` gained `withheldRedundant`.
- **Organizer command (`Cli.lean`, `Application.lean`).** `organize` computes the candidate rewrite
  purely, and only spins up the exact-frontend validator (`withExactRun`) when a file actually
  changes, validating by re-elaboration before `publishAtomic`. Statuses: `would-organize` /
  `organized` / `clean` / `rejected`.

## What was run

All commands from the repository root.

- `LEAN_NUM_THREADS=1 lake build` — **Build completed successfully (42 jobs).**
- `.lake/build/bin/lean-fmt-tests` — **lean-fmt module-artifact tests passed** (`testImports` covers
  FMT005 exact-duplicate + safe-fix edit, `import all A` is *not* a duplicate, literal `import Init`
  twice fires, FMT007 fires report-only, blank-line grouping, FMT006 with a synthetic closure,
  `import all` withholding with the count recorded, `redundancyEligible`, the organizer sort/dedup,
  and the prelude no-phantom-`Init` case).
- `bash tests/imports/run.sh` — **lean-fmt import-rule integration tests passed.** New CLI-pipeline
  runner over committed `module` fixtures (`Duplicate.lean`, `Ordering.lean`, `Redundant.lean`):
  FMT005 with `safe` applicability, FMT007 report-only, FMT006 via the live Lake graph
  (`LeanFmt.Rules` inside `LeanFmt.Config`'s closure), `--select FMT005` suppressing FMT007,
  `organize --check` → `would-organize`/exit 1/unchanged, `organize` write → sorted + validated
  (restored via `cp -p`), and `fix --select imports` → deduped through the canonical patch. The
  committed fixtures are hash+mtime-snapshotted before/after and `cmp`-checked unmodified.
- `bash tests/boundary/run.sh` — **passed** (see decision 3 below).
- `bash tests/modes/run.sh`, `tests/check/run.sh`, `tests/suppression/run.sh`, `tests/service/run.sh`
  — all pass; the shared merge/selection/summary path carries no regression.
- `uv run … check_stack.py … --structural` — **OK: 3 prompt(s), 0 warning(s), no errors.**
- `uv run … write_next.py … --check`, `git diff --check` — clean.

## Decisions changed during execution

1. **Tests call `Imports.*` directly, not through a `runRulesOf` synthetic-registry seam.**
   `notes/01-semantics.md` §6 speculated the header rules would be characterized "via the `runRulesOf`
   synthetic-registry seam." That seam presupposes the rules are `RuleImpl`s in the engine — which §1b
   and §7 of the same note decided against. The implementation followed §1b/§7 (import rules are
   outside the engine), so `testImports` calls the pure `Imports.*` functions directly. The §6
   phrasing is stale spec prose; the frozen *decision* it contradicts is honored. No code owes the
   seam.
2. **A dedicated `tests/imports/` fixture directory.** §6 offered "`tests/check/` or a new
   `tests/imports/`"; the new directory is cleaner — the fixtures are `module` files importing real
   project modules so FMT006's graph resolves, and they must not perturb the `tests/check` goldens.
3. **The source-boundary gate was scoped to compiled sources.** `tests/boundary/run.sh` scans
   `git ls-files '*.lean'` and required every file to begin with `module`. The RIR-SPEC evidence probe
   `docs/…/evidence/01-semantics.lean` is legacy (non-`module`) *on purpose* — `parseImports'` is
   `meta`-gated under the module system (`notes/01-semantics.md`, and the probe's own header). It was
   committed in the RIR-SPEC commit, so the gate went red the moment that commit landed (the
   `results/01` "boundary passes" claim was true when run, because `git ls-files` does not see an
   untracked file, and false once committed). The gate's stated intent is "every *compiled* Lean
   source uses private-by-default modules"; `docs/` evidence probes are run by hand via
   `lake env lean` and are never globbed into the package, so they are not compiled sources. Fixed by
   excluding `docs/*` from the scan, with a comment naming the reason. This is a scoping correction to
   shared gate infrastructure, not a weakening — no compiled source is exempted.
4. **The `rules --json` catalog golden in `tests/modes/run.sh` grew to seven rules.** The catalog now
   lists FMT001–FMT007; the golden was updated to assert the full list plus the import family's
   properties (FMT005 fixable/`imports`, FMT006 & FMT007 report-only/`imports`, all default-enabled
   and source-indexed). Expected consequence of shipping three rules.

## Remaining uncertainty

- **FMT006 withholding is deliberately conservative** (frozen in §5): any `all`/`meta` modifier or a
  re-export makes redundancy unprovable from reachability, so those are withheld and only counted, not
  reported. `withheldRedundant` surfaces the count so RIR-FINAL can measure how often the conservative
  rule declines — this is the intended behavior to differentially probe, not a defect.
- **The organizer's default is display/opt-in, never an automatic reorder.** The compiler reads the
  header in order, so `fix` does not reorder; only the explicit `organize` command rewrites, and only
  after re-elaboration validates the result. RIR-FINAL owns the elaboration-significant-order and
  comment-preservation differentials.
- No per-file Lake subprocess is spawned; the single shared `importClosures` fetch is the only graph
  work, and a broken file drops its import findings before the merge (it throws in `prepareFile`).
