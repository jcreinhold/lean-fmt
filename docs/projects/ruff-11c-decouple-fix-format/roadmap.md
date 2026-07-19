---
kind: roadmap
topic: "Decouple lint-fix from formatting: fix applies at original coordinates, format reflows only"
main_results: [RDF-FINAL]
prereq_stacks: [ruff-06-fix-safety, ruff-09-import-rules, ruff-10b-syntax-fix-composition, ruff-11b-owned-semantic-fix]
blueprint_tracked: false
---

# Decouple lint-fix from formatting

## Goal

Give `lean-fmt` the Ruff separation the product intends: **`format`/`diff` reflow only** (canonical
layout, no rule fix ever applied or previewed), and **`fix`/`check --fix` apply admitted lint fixes
only** (at the file's own original coordinates, no reflow). A user composes them exactly as
`ruff check --fix && ruff format`.

A first-hand characterization during RDF-SPEC forced a second, coupled concern into this stack (RDF-SPEC
§4, product decision made with the owner): the canonical printer does **not** subsume the source-tier
trailing-whitespace/final-newline normalizations — it emits the last token's trailing run and every
verbatim-token slot *verbatim* (`Printer.lean:222-236`), so today's clean `format` output for
whitespace/newline comes **entirely** from FMT001/FMT002's fixes composed onto the canonical patch. A
fix-free `format` would therefore regress (leave trailing whitespace, drop the final newline) unless the
reflow is made to own that normalization. Per the product principle *"anything that reflows should be a
formatter or have a formatting equivalent"* (and matching `ruff format`, which trims trailing whitespace
and adds a final newline as formatting, not as a lint fix), this stack **moves trailing-whitespace and
final-newline normalization into the formatter's layout** — extending the canonical trivia model to trim
the trailing horizontal whitespace it emits (string/token content is untouched *by construction*: the
printer only trims the whitespace *trivia* it itself lays down, never token text) and to guarantee a
single final newline — and **retires FMT001 and FMT002 as lint rules**, leaving the formatter their sole
sound owner. This also removes a pre-existing FMT001 soundness defect RDF-SPEC found first-hand: FMT001's
byte-level trim deletes trailing whitespace *inside multi-line string literals* (`"a   \nb"` → `"a\nb"`,
a silent value change the re-elaboration validator does not catch because the file still elaborates).
The formatter's trivia-only trim cannot commit that error. FMT003/FMT004 (the report-only source-tier
security rules) are unaffected; retiring FMT001/FMT002 removes the only source-tier *fixable* rules, so
every test that used FMT001/FMT002 as its fixable-source vehicle migrates onto a surviving import/syntax/
semantic rule (RDF-LAYOUT owns that migration).

Today the two are **fused**: `format`, `diff`, and `fix` all set
`RunMode.rendersCanonical := true` and share one `prepareFile` patch drawn from `result.canonical?`'s
findings (`LeanFmt/Application.lean:848,865-872`), so `format` silently composes admitted lint fixes
onto reflowed bytes and `fix` reflows while it fixes. This stack splits the single `renderCanonical`
patch decision into two independent concerns — **layout** and **lint-fix** — and re-homes every rule
fix onto original coordinates, retiring the canonical-coordinate fix machinery that existed only to
carry fixes across the reflow.

## Origin

The fusion is not one stack's invention; it accreted across four:

- **`ruff-04`/`ruff-06`** made `format` a canonical render that *also* applies admitted fixes — the
  `RunMode.rendersCanonical` gate and the shared `Applicability.admitted unsafeFixes` admission that
  makes "a preview shows exactly what a write would do" (`prepareFile`, `Application.lean:843-847`).
  `ruff-06`'s RFX-SPEC froze "fixes compose onto canonical text."
- **`ruff-09`** (RIR-IMPL, commit `4943080`) recomputes the FMT005 duplicate-import fix at **canonical
  coordinates** because the printer reflows but does not dedup the header (`patchDuplicateFindings`,
  `Application.lean:819-828`). This is the first fix that rides `canonical.findings`.
- **`ruff-10b`** (RYC-IMPL) built `ExactRun.reprojectCanonical` (`Application.lean:418`) so a
  *syntax*-tier `.safe` fix is re-projected onto the reflowed bytes.
- **`ruff-11b`** (ROS-IMPL) extended `reprojectCanonical` with `(captureSemantic captureOccurrences)`
  so FMT014's *semantic* rename also lands at canonical coordinates — the "decision changed during
  execution" ROS-IMPL recorded (`ruff-11b/results/02-impl.md` §2).

So the coordinate coupling is a shared, load-bearing decision. A `git revert` of 10b/11b would delete
their fix capabilities while leaving the coupling (FMT005 still rides `canonical.findings`, `format`
still applies fixes) intact — it removes the wrong half. The decoupled end state — **fix at original
coordinates, format fix-free** — is a state no prior commit occupied; only forward work reaches it.
This stack is that forward work: it keeps every 10b/11b fix (the syntax `.safe` composition, FMT014's
validated rename, the info-tree capability split) and re-homes them onto original coordinates and onto
`fix` alone.

## The two concerns, made independent

`prepareFile` (`Application.lean:848`) today conflates two things through one `renderCanonical` bool:

1. **Layout** — the reflow: `base := canonical.text` (`Application.lean:870`).
2. **Lint-fix** — admitted rule fixes composed on that base: `baseFindings := canonical.findings ++
   patchImports`, gated by `Applicability.admitted` (`Application.lean:871,873-875`).

These change independently and belong to different commands. This stack separates them:

- **Layout patch** (`format`, `diff`): `base := canonical.text`, **zero** rule fixes. The formatter's
  answer is the reflow and nothing else. Trailing-whitespace and final-newline normalization — which the
  canonical trivia model does **not** perform today (RDF-SPEC §4: the printer emits its trailing runs and
  verbatim-token slots verbatim, so today's clean `format` output for those comes from FMT001/FMT002's
  composed fixes) — is **moved into the reflow** by RDF-LAYOUT (a trivia-only trim + guaranteed final
  newline) and FMT001/FMT002 retire, so the layout patch's fix-free reflow is still whitespace/newline
  clean.
- **Fix patch** (`fix`): `base := normalized` (original coordinates), admitted fixes drawn from the
  original-coordinate `result.findings ++ reportImports`, **no reflow**. `RunMode.rendersCanonical`
  becomes false for `fix`.
- **`check`**: unchanged — report only, no patch published.

Shared parsing/analysis infrastructure stays shared: both `format` and `fix` still run the exact
frontend (`analyzeExact`) and, when a rule needs it, the canonical printer. Decoupling is about which
fixes ride which coordinates on which command — not about duplicating the frontend or the printer.

## What retires

The report (`FileReport.findings`) is drawn from `result.findings` at **original** coordinates in every
mode (`prepareFile:856`); `reprojectCanonical` only ever rewrites `canonical.findings` (`:427`), which
feeds **only the patch** (`:871`). So once `format` carries no fixes, `reprojectCanonical` has no
remaining consumer — the canonical *text* is produced by `renderCanonicalText`/`canonicalAnalysis`
without it — and the coordinate-translation machinery built to carry fixes collapses **entirely**:

- `ExactRun.reprojectCanonical` (`Application.lean:418`) and its `(captureSemantic captureOccurrences)`
  parameters — deleted, not narrowed to a render-only role (there is none). FMT014's occurrences are
  captured once in the base `analyzeExact` at original coordinates, which is exactly where `fix` now
  applies the rename. This directly unwinds ROS-IMPL §2 without reverting ROS-IMPL's sound work.
- `availableAnalysis`'s `renderCanonical && requiredTier == .syntax` branch (`Application.lean:511-517`),
  which today *forces* the ExactRun+reproject path so a canonical-rendering syntax run gets its fix at
  canonical coordinates. With `format` fix-free this branch would keep `format` paying a second frontend
  run for findings it discards; it is removed, so `format --select FMT01x` takes the cheap artifact path
  (`:518`) and reports original-coordinate findings.
- `patchDuplicateFindings` / the canonical `patchImports` recomputation (`Application.lean:819-828`):
  FMT005's fix comes from the original-coordinate `duplicateFindings` already in `selected`.
- The `result.canonical?`-as-patch-source branch of `prepareFile`, and any now-dead `CanonicalText.findings`
  / `renderCanonicalText`'s `runSourceRules` surface that only fed it.

The occurrence demand (`RulePlan.demandedCaps`, consulted at `availableAnalysis:493`) is **rewired**:
today it keys on `renderCanonical`; it must key on the *apply* signal so a `fix` selecting FMT014 with
an admissible fix demands the info-tree walk while a `format --select FMT014` demands nothing.

Net effect on the critical path is a **win**: `format` drops its second frontend run, and `fix`
(no longer rendering canonical) becomes eligible for the source-only fast shortcut (`:495-510`) it was
locked out of while it rendered.

## What is preserved unchanged

- The **`ruff-11b` capability split** (`SemanticCaps`, `SemanticResult` capability field,
  `cacheHitServes` requiring `demandedCaps ⊆ caps`). It is a cache-soundness gate orthogonal to
  coordinates; the info-tree walk is still paid only under an occurrence demand — now triggered by a
  `fix`/`check` selecting FMT014 against the base analysis rather than by a canonical re-projection.
- The **`ruff-06` fix machinery**: applicability, conflict rejection, the atomic transaction, the
  output re-elaboration validator, the stale-source pre-check. `fix` still validates every write.
- The **`ruff-11b` fixable predicate** `spelled == occurrenceDisplay declName` and every rule's
  report-only vs fixable classification.
- Exact ordered imports, search-path precedence, file-local syntax effects, validation identity,
  private application boundaries, and atomic writes. `check`, `format`, and `diff` never write source;
  only `fix` writes.
- Every rule **other than FMT001/FMT002**: their reports, tiers, and fixes are untouched. FMT003/FMT004
  (report-only source-tier security rules) keep the source-only fast path they anchor — so a default
  `check`/`format` still shortcuts to source-tier facts (retiring FMT001/FMT002 does **not** raise the
  default `requiredTier`). The formatter's ws/newline normalization is layout, not a rule, so it adds no
  rule and touches no cache identity a rule would.

## Work order

1. **RDF-SPEC — Freeze the decoupled patch interface and the formatter/lint boundary.** Characterize
   first-hand the current fusion (`prepareFile` base/`baseFindings` selection, `RunMode.rendersCanonical`,
   `reprojectCanonical` and its 11b extension, `patchDuplicateFindings`, the `admitted`/`unsafeFixes`
   gate) with a reproducible probe showing `format` composing a lint fix today. Freeze the two concerns
   and the mode→patch mapping: layout patch (`format`/`diff`: canonical base, no fixes), fix patch
   (`fix`: normalized base, admitted fixes at original coordinates), `check` unchanged. Design the
   boundary **twice** — a `PatchKind` discriminator inside `prepareFile` vs a split into
   `prepareLayout`/`prepareFix` chosen at the caller — and compare on caller knowledge, invariants
   hidden, error surface, cache identity, critical path, and what retires. **Characterize first-hand
   whether the canonical reflow subsumes source-tier trailing-whitespace/final-newline normalization; it
   does not** (printer verbatim-trailing runs) — and it also surfaces the pre-existing FMT001
   string-literal corruption. Freeze the resolution (product decision, owner-confirmed): the **formatter
   subsumes ws/newline as layout** and **FMT001/FMT002 retire as lint rules** (RDF-LAYOUT owns it). Name
   what retires, prove the capability split and validator are untouched, and enumerate the adversarial
   cases RDF-FINAL must drive.
2. **RDF-LAYOUT — Move ws/newline into the formatter; retire FMT001/FMT002.** Extend the canonical
   trivia model so `Printer.format`'s output trims the trailing horizontal whitespace it lays down (in
   the trivia it emits — never token text, so string literals are safe by construction) and ends with
   exactly one final newline. Retire FMT001 and FMT002 from `ruleRegistry` and delete their rule
   definitions; the formatter is now their sole owner. Migrate every persistent test that used
   FMT001/FMT002 as its fixable-source vehicle (`extend-safe-fixes`/`extend-unsafe-fixes` applicability,
   suppression per-file/directive, `tests/modes`, conflict rejection, `LeanFmtTest.lean`) onto a
   surviving import/syntax/semantic rule. Land this **before** the patch split so `format` never
   regresses: while `format` still composes fixes (pre-split), the printer already owns ws/newline, and
   FMT001/FMT002 are gone. Add regression tests: `format` alone trims trailing whitespace and adds a
   final newline with **no** rule selected; an in-string-trailing-whitespace fixture keeps its string
   value under `format` (the old FMT001 corruption cannot recur). The residual FMT001 *lint-path*
   soundness (a `fix`-owned in-string trim) no longer exists once FMT001 is retired, so this stack
   closes the defect outright rather than deferring it.
3. **RDF-IMPL — Implement the patch split.** `RunMode.rendersCanonical := false` for `fix`; split
   `prepareFile`'s patch decision into the layout and fix concerns; move FMT014's occurrence capture
   and every rule fix onto the base (original-coordinate) analysis; retire `reprojectCanonical`'s
   fix/occurrence role, the 11b reproject parameters, and `patchDuplicateFindings`. Remove the retired
   path rather than leaving a parallel one. Keep the capability split, the validator, the stale check,
   atomic writes, and the surfaced reports. Update persistent tests at the owning layer so `format`
   reflows without applying any lint fix and `fix` applies fixes at original coordinates without
   reflowing.
4. **RDF-FINAL — Adversarial acceptance.** Drive the independence matrix: `format`/`diff` never write
   or preview a rule fix at any tier (syntax FMT008-class, semantic FMT014; note the source tier no
   longer carries a fixable rule after RDF-LAYOUT — imports FMT005 is the lowest fixable tier); `fix`
   applies each at original coordinates and re-`check`s clean without reflowing; `format` alone still
   trims trailing whitespace and adds a final newline as layout (the retired-rule normalization now
   lives in the reflow) and never corrupts an in-string whitespace value; `fix` then `format` and
   `format` then `fix` both compose and their convergence (or a documented divergence) is pinned;
   idempotence of each; the 11b capability demand-gating and monolithic-era miss still hold; the
   FMT005/syntax/semantic fixes land at exact original bytes (the `namespace     Alpha` gap `RFP-SPEC`
   measured no longer moves a fix); `diff` equals a `format` preview; and a frozen-sample read-only
   review. Prove `reprojectCanonical`'s fix role is gone (grep), any surviving use is render-only, and
   FMT001/FMT002 are absent from the registry.

## Evidence and verification

Every prompt writes `results/<stem>.md` with commands, raw outputs or evidence locators, changed
decisions, files changed, checks read, and remaining uncertainty. Use focused fixtures, the frozen
representative mathlib sample, and named stress files. Do not run complete mathlib in this stack.

Run `LEAN_NUM_THREADS=1 lake build`, `lake exe lean-fmt-tests`, and the touched integration suites
(`tests/modes/run.sh`, `tests/check/run.sh`, `tests/syntax/run.sh`, `tests/semantic/run.sh`,
`tests/lossless/run.sh`, `tests/boundary/run.sh`, `tests/printer/run.sh`, `tests/suppression/run.sh`,
`tests/imports/run.sh`, and any suite named by a touched module — RDF-LAYOUT touches the printer and the
FMT001/FMT002-vehicle suites broadly), this stack's structural checker, `write_next.py --check`, and
`git diff --check`.

## Blueprint

This is genuine formatter repository maintenance and introduces no mathematical theorem claim.
Therefore this roadmap sets `blueprint_tracked: false`.

## Stop rules

- `format`/`diff` must never apply or preview a rule fix, at any tier. `fix` must never reflow. If a
  test cannot separate the two, stop and repair the interface rather than blending them back.
- No rule fix may be computed or applied at canonical coordinates after this stack. Every fix rides the
  file's own normalized bytes and is validated by output re-elaboration before any write.
- The formatter's ws/newline normalization is **layout, not a rule fix**: it trims only the whitespace
  trivia the printer itself emits and never token text, so it cannot alter a string-literal value (the
  FMT001 corruption RDF-SPEC found must not recur). It is unconditional (no `--unsafe-fixes` gate) and is
  the formatter's answer, so it does not reintroduce a "format applies a fix" coupling. FMT001/FMT002 are
  fully retired — not left dormant in the registry.
- Preserve the `ruff-11b` capability split and soundness (`demandedCaps ⊆ caps`, `Tier.satisfies`),
  the `ruff-06` validator/transaction/stale-check, the fixable predicate, exact ordered imports,
  search-path precedence, file-local syntax effects, validation identity, private application
  boundaries, and atomic writes. Only `fix` writes.
- Do not restore the retired canonical-coordinate fix path once removed. Do not give rules parser or
  application-lifecycle authority; `LeanFmt.Rules` stays out of the compiler-plugin closure and its
  library globs. No `Environment`, `InfoTree`, `Position`, or `FileMap` crosses into a rule.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap. Do not run
  complete mathlib in this stack. Prefer pure Lean; another language needs a named unavailable Lean
  capability and a measured benefit.
