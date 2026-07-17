# RFX-IMPL — Applicability-aware planning and publication

**Verified.** The design is `notes/01-model.md` (frozen under `RFX-SPEC`). This records what was built,
what was run, what it showed, and the two note refinements execution forced.

The whole model from the note now exists in code and is exercised end to end: a finding carries a
`Fix { applicability, edits }`, `fix` applies safe fixes only, `--unsafe-fixes` opts into unsafe,
`extend-safe-fixes`/`extend-unsafe-fixes` reclassify per rule as a plan projection, a rule in both is a
config error, and a conflict names both rules and both finding ranges. File atomicity, stale-source,
and permission preservation are unchanged — this stack added a per-*fix* admission gate above the
existing per-*file* transaction, not a new transaction scope.

## The headline

**`fix? : Option Edit` became `fix? : Option Fix`, and admission is one function the whole product
shares.** `Applicability.admitted unsafeFixes` (`ArtifactModel.lean:44`) is the single rule `format`,
`diff`, and `fix` all consult, so a preview shows exactly what a write would do. The reported
applicability and the admission decision are deliberately separate: `RulePlan.findings`
(`Config.lean:244`) rewrites each surviving fix to its *effective* applicability (what a user sees), and
admission downstream decides which of those `fix` applies.

## Commands run

```sh
LEAN_NUM_THREADS=1 lake build                       # exit 0 (36 jobs)
LEAN_NUM_THREADS=1 lake build lean-fmt-tests        # exit 0
.lake/build/bin/lean-fmt-tests                      # "module-artifact tests passed"
bash tests/modes/run.sh                             # "product mode integration tests passed"
bash tests/boundary/run.sh                          # "native module and dependency boundary passed"
bash tests/check/run.sh                             # "check integration tests passed"
bash tests/service/run.sh                           # "editor service integration tests passed"
git diff --check                                    # no output
check_stack.py    docs/projects/ruff-06-fix-safety --structural   # OK
write_next.py --check docs/projects/ruff-06-fix-safety            # matches
```

Environment: base commit `9af2d2b`, `leanprover/lean4:v4.32.0`, Darwin 25.5.0 arm64. No new
performance claim: the change adds a bounded filter over already-computed findings and one enum field
to the serialized `Finding`; the service suite's RSS envelope (`peak_rss_kib ≈ 1.02 GiB` over 100
requests) is unchanged within noise from the `RFX-SPEC` baseline.

## What was built

**1. The type (`ArtifactModel.lean:26-82`).** `Applicability := safe | «unsafe» | displayOnly` with a
kebab-cased wire spelling (`toWire`), `admitted`, and hand-written `ToJson`/`FromJson` so a stale or
bogus wire value errors rather than silently defaulting. `Fix { applicability, edits : Array Edit }`;
`Finding.fix?` is now `Option Fix`. Because `Finding` serializes through the result cache,
`semanticResultSchema` bumped to `v3` (`Semantic.lean`) — the note §7 said "no schema bump", which was
wrong, and this is the correction (see below).

**2. Reclassification as a projection (`Config.lean`).** `FormatterConfig` gains
`extendSafeFixes`/`extendUnsafeFixes`; `RulePlan` gains `extendSafe`/`extendUnsafe`;
`FormatterConfig.rulePlan` expands both, rejects a code in both (`:213`), and `effectiveApplicability`
(`:231`) applies the display-only floor then promotes/demotes. No rule reads any of this — like
selection, it lives in the plan.

**3. Admission and withholding (`Application.lean`).** `RunRequest.unsafeFixes` (`:56`) threads to
`prepareFile`, which strips non-admitted fixes before `preparePatch` and counts `withheldUnsafe`
(`:72,83,590`) — reported unsafe fixes a run declined to apply. All four execute call sites and every
report branch carry it.

**4. Conflict provenance (`Edit.lean:15,96`).** `PatchError.conflict` now carries
`(leftCode rightCode : String) (left right : SourceRange)`; a private `ProvenancedEdit` threads each
edit's originating rule code and finding range past the flatten that used to discard them, so the error
reads `fixes from FMT001 (...) and FMT002 (...) conflict` instead of naming array indices.

**5. CLI surface (`Cli.lean`).** `--unsafe-fixes` flag; finding lines tag applicability
(`FMT001 ... [unsafe]`); `fix` prints a withheld-count line; summary/statistics lines add
`withheld_unsafe=`.

## Tests added

- `LeanFmtTest.lean:testApplicability` — admission truth table, wire round-trip and bogus-value
  rejection, `effectiveApplicability` promotion/demotion/unlisted/display-only-floor, the findings
  projection demoting a real FMT001 fix, conflict error naming both rule codes, and the both-lists
  config contradiction. `testRules` additionally asserts every shipped fix is `safe`.
- `tests/modes/run.sh` — `check` reports `fix.applicability`; `extend-unsafe-fixes` demotes FMT001, and
  then default `fix` withholds it with no write while `--unsafe-fixes` applies it (source metadata
  compared before/after to prove the withhold touched nothing); both-lists config exits 2.

## Decisions changed during execution

**The note §7 "no schema bump" was wrong; bumped to `v3`.** §7 reasoned the artifact is facts-only so
nothing versioned. True for the `.olean` artifact — but `Finding` also serializes through
`SemanticResult` (the result cache), and its `fix?` shape changed. A `v2` payload decoded as `v3` would
drop fixes through field defaults and describe a clean file, the exact silent-staleness class
`semanticResultSchema`'s own docstring names. Corrected in code and here.

**`rules` output keeps `fixable` (boolean).** The note §6 vocabulary is per-fix applicability, but the
`rules` subcommand does not run rules and applicability is a property of an emitted fix, not of a rule
declaration. A rule can emit fixes of differing applicability (and reclassification is per-run config),
so there is no single applicability to report there. `fixable` stays; the `rules` JSON is unchanged.

**`--unsafe-fixes` governs admission for every patch-building mode**, not just `fix`. `format` and
`diff` build patches too, and if they admitted unsafe fixes the preview would diverge from what `fix`
writes. Threading `unsafeFixes` through `prepareFile` (shared by all three) keeps them identical;
`checkSnapshot` passes `false` since `check` proposes nothing.

## Files changed

```
LeanFmt/ArtifactModel.lean      Applicability, Fix, Finding.fix? : Option Fix
LeanFmt/Rules.lean              FMT001/FMT002 emit safe fixes
LeanFmt/Edit.lean               ProvenancedEdit, conflict provenance
LeanFmt/Semantic.lean           result-cache schema v2 -> v3
LeanFmt/Config.lean             extend-*-fixes, effectiveApplicability, findings projection
LeanFmt/Application.lean        unsafeFixes admission, withheldUnsafe
LeanFmt/Cli.lean                --unsafe-fixes, applicability tag, withheld line
LeanFmtTest.lean                testApplicability; testRules safe-fix assertion
docs/adding-a-rule.md           applicability section
tests/modes/run.sh              applicability + --unsafe-fixes coverage; summary-line goldens
docs/projects/ruff-06-fix-safety/{results/02,prompts/02,state/current,state/next}
```

## Checks read

Every suite above passed. `git diff --check` is silent (the diff golden trailing-whitespace lines are
assembled in Python, not literal). The structural checker and `write_next.py --check` pass with
`02-transaction` verified and `first_unresolved` advanced to `03-acceptance`.

## Remaining uncertainty

- **Multi-edit fixes** (`edits : Array Edit`) are built and validated as a set, but no shipped rule
  emits more than one edit; the assembler path for `>1` edit per fix is covered only by `testEdits`'
  synthetic cases until a real producer arrives (plausibly `ruff-09`).
- **Syntax-tier fix composition** (re-project canonical text, note §3) is specified and unexercised —
  no shipped rule is syntax-tier. `RFX-FINAL` is where the adversarial cases (overlap, UTF-8
  boundaries, promoted/demoted applicability under formatter composition, crash-before-rename) get
  their gate.
