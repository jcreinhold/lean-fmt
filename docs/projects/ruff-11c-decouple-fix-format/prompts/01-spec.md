---
claim_id: RDF-SPEC
status: planned
depends_on: []
---

# Freeze the decoupled patch interface

## Task

Deliver **RDF-SPEC**: Specify the split of `prepareFile`'s single canonical patch into two independent
concerns — a **layout patch** (`format`/`diff`: canonical reflow, no rule fix) and a **fix patch**
(`fix`: admitted rule fixes at the file's own original coordinates, no reflow) — with `check`
unchanged. Freeze the mode→patch mapping, name every mechanism that retires because fixes no longer
cross the reflow, and prove the `ruff-11b` capability split and the `ruff-06` validator are untouched.
Change no observable rule report; change what each mode *writes and previews*.

Read `roadmap.md`; `ruff-06-fix-safety/notes/01-model.md` (the safe/unsafe/display-only applicability
model, the atomic transaction, and the output re-elaboration validator); `ruff-10b-syntax-fix-composition/notes/01-model.md`
(how a syntax `.safe` fix rides `reprojectCanonical` onto canonical text — the coordinate coupling this
stack unwinds); `ruff-11b-owned-semantic-fix/notes/01-model.md` and `results/02-impl.md` §2 (FMT014's
rename reaching `reprojectCanonical` with `captureOccurrences` — the decision this stack reverses in
direction while keeping its result) and `results/03-final.md` §1 (the frozen fixable predicate);
`ruff-04-formatter-product` and `ruff-09-import-rules` results for the origin of `RunMode.rendersCanonical`
and the FMT005 canonical-coordinate fix; `AGENTS.md`; and the live seams before specifying an interface:

- `LeanFmt/Application.lean`: `RunMode` and `RunMode.rendersCanonical` (23-44), `RunRequest.unsafeFixes`
  (55-59), `renderCanonicalText`/`canonicalAnalysis` (379-395), `ExactRun.reprojectCanonical` and its
  `(captureSemantic captureOccurrences)` gate (418-440), `cacheHitServes`/`availableAnalysis`
  (469-519), `patchDuplicateFindings` (819-828), `prepareFile` with its `base`/`baseFindings` branch
  and the `admitted` gate (830-888), `RunMode.preview?` (890-899).
- `LeanFmt/Analysis.lean`: `analyzeExact`, `captureDeprecatedOccurrences`, `occurrenceOfInfo` — where
  the whole-file info trees are walked and occurrences resolved in normalized-source coordinates.
- `LeanFmt/ArtifactModel.lean`/`LeanFmt/Semantic.lean`: `SemanticResult`, `SemanticCaps`, the canonical
  sub-result (`result.canonical?`), and the capability field.

## Target

- Specify the split behind the private `Application` boundary; keep CLI presentation in `LeanFmt.Cli`.
  No `Environment`, `InfoTree`, `Position`, or `FileMap` crosses into a rule; rules gain no lifecycle
  authority.
- Reproduce the fusion first-hand: a fixture that is **both** badly laid out **and** carries an admitted
  lint fix, run through `format`, showing today's output composes the fix onto the reflow (and through
  `fix`, showing it reflows). Record the exact `prepareFile` lines that make this happen.
- Freeze the two concerns and the mode→patch mapping:
  - **Layout patch** — `format`, `diff`: `base := canonical.text`, patch carries **no** rule fix. The
    render is the whole answer.
  - **Fix patch** — `fix`: `base := normalized` (original coordinates), patch carries the admitted
    fixes from the original-coordinate `result.findings ++ reportImports`; `RunMode.rendersCanonical`
    is **false** for `fix`.
  - **`check`** — unchanged: report only, no published patch.
- Characterize first-hand whether the canonical reflow already subsumes source-tier *formatting* fixes
  (trailing whitespace FMT001, final newline, etc.) — including inside verbatim-fallback regions. The
  answer, settled first-hand and frozen here: **it does not.** `Printer.format` emits the last token's
  trailing run and every verbatim-token slot verbatim (`Printer.lean:222-236`), so today's clean
  `format` output for trailing-whitespace/final-newline comes **entirely** from FMT001/FMT002's fixes
  composed onto the canonical patch (`renderCanonicalText`'s `runSourceRules text`). Prove this with a
  probe that deselects FMT001/FMT002 and shows `format` leaving trailing whitespace and no final newline.
  Also record the pre-existing FMT001 soundness defect the probe surfaces: FMT001's byte-level trim
  deletes trailing whitespace *inside multi-line string literals*, a silent value change the validator
  does not catch. **Freeze the resolution (product decision, owner-confirmed):** trailing-whitespace and
  final-newline normalization move **into the formatter's layout** (RDF-LAYOUT extends the canonical
  trivia model to trim only the whitespace trivia the printer emits — string/token content untouched by
  construction — and to guarantee one final newline), and **FMT001/FMT002 retire as lint rules**, so a
  fix-free `format` is still whitespace/newline clean and the string-corruption defect cannot recur. Name
  the retirement's blast radius (FMT001/FMT002 are the fixable-source vehicle across the persistent
  suite; FMT003/FMT004 stay report-only, keeping the default source-only fast path) and hand the printer
  change + test migration to RDF-LAYOUT.
- **Freeze `format`'s report policy explicitly** — this is a product decision, not an implementation
  detail. Confirm first-hand that `FileReport.findings` is drawn from `result.findings` at original
  coordinates in every mode (`prepareFile:856`), so the report is already invariant under the patch
  change. Freeze the decision that `format`/`diff` **keep reporting** their original-coordinate findings
  (only the patch loses fixes), and name the rejected alternative (`format` reports nothing about lint,
  Ruff-style) with the reason it is deferred rather than taken here.
- Freeze what retires and why it is safe, naming each edit site so the implementer cannot leave a
  wasted path live:
  - `reprojectCanonical` (`:418`) and its `(captureSemantic captureOccurrences)` parameters — deleted
    entirely (it rewrites only `canonical.findings` at `:427`, which only the patch reads, so a fix-free
    `format` has no consumer). Confirm there is no render-only survivor.
  - `availableAnalysis`'s `renderCanonical && requiredTier == .syntax` branch (`:511-517`), which forces
    the ExactRun+reproject path — removed, so `format --select FMT01x` takes the artifact path (`:518`)
    and reports original-coordinate findings without a second frontend run.
  - `RulePlan.demandedCaps` (consulted at `:493`) — **rewired** off `renderCanonical` onto the apply
    signal, so a `fix` selecting FMT014 with an admissible fix demands the info-tree walk and a
    `format --select FMT014` demands nothing. Specify the exact trigger.
  - `patchDuplicateFindings`/canonical `patchImports` (`:819-828`); the `result.canonical?`-as-patch-source
    branch of `prepareFile`; and any now-dead `CanonicalText.findings`/`renderCanonicalText` source-rule
    surface that only fed the patch.
  State where FMT014's occurrences are captured after the change (the base `analyzeExact`, original
  coordinates) and that every fix now indexes the same string it is reported against — so the
  `RFP-SPEC`-measured coordinate gap (`namespace     Alpha` deleting four bytes) can no longer move a
  fix off its bytes.
- Prove the **preserved** invariants are genuinely untouched: the `ruff-11b` capability split
  (`SemanticCaps`, `SemanticResult` capability field, `cacheHitServes` `demandedCaps ⊆ caps`,
  `Tier.satisfies`) is orthogonal to coordinates and stays a sound cache gate; the occurrence demand
  trigger moves to the base analysis (a `fix`/`check` selecting FMT014) without re-projection; the
  `ruff-06` applicability, conflict rejection, atomic transaction, output re-elaboration validator, and
  stale-source pre-check are unchanged and still gate every `fix` write.
- Design the boundary **twice** and compare on caller knowledge, invariants hidden, error surface,
  cache identity, critical path, and mechanism retired:
  - **Design A** — a `PatchKind` (`layout | fix | none`) derived from `RunMode` inside `prepareFile`,
    replacing the `renderCanonical` bool; one function, two internal branches.
  - **Design B** — split `prepareFile` into `prepareLayout` (canonical base, no fixes) and `prepareFix`
    (normalized base, admitted fixes), dispatched by mode at the caller.
  Justify the choice against the deep-module test (small surface, each concern changes independently,
  no caller learns a coordinate system it did not before). Record the rejected alternative.
- Enumerate the adversarial cases RDF-FINAL must drive (see that prompt) and the demand trigger, the
  soundness argument, and any remaining uncertainty.
- Write `results/01-spec.md` with the frozen interface, the two designs and the decision, evidence
  locators (file and line for each live seam), and remaining uncertainty. Update `state/current.md`
  only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Reproduce the fusion (`format` composing a fix; `fix` reflowing) on a mixed fixture and pin the exact
   `prepareFile` lines responsible.
2. Trace every rule fix's current coordinate path — source (`selected`), import FMT005
   (`patchDuplicateFindings`), syntax (`reprojectCanonical`), semantic FMT014 (`reprojectCanonical` +
   `captureOccurrences`) — and confirm each has a sound original-coordinate source already computed in
   the base analysis.
3. Design the boundary twice; compare on the module-design axes; record the rejected alternative.
4. Characterize the reflow-subsumes-source-fix question first-hand.
5. Name what retires, prove the capability split and validator untouched, and inspect callers/docs for
   any claim that `format` is meant to apply fixes.

## Stop

- Do not specify `format`/`diff` applying or previewing any rule fix, or `fix` reflowing.
- Do not specify a fix computed at canonical coordinates; every fix rides the file's normalized bytes.
- Do not weaken the capability split, `Tier.satisfies` soundness, the validator, exact semantics, write
  safety, or cache identity, or give rules lifecycle authority.

## Check

- This is a specification prompt; its checks are that the interface is complete, sourced first-hand
  against the live seams it names (cite file and line for each), and buildable in principle without
  changing any rule's report.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-11c-decouple-fix-format`.
- Run `git diff --check` and read all output before marking RDF-SPEC verified.
