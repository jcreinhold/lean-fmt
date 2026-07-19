# RDF-SPEC — the decoupled patch model

Frozen interface for splitting `prepareFile`'s single canonical patch into two independent concerns.
Sourced first-hand against the live seams (line numbers verified against the working tree at this
commit) and against runtime probes recorded in `evidence/01-fusion-and-subsumption.md`.

## 1. The fusion this stack unwinds

Today one patch does two jobs at once. `prepareFile` (`Application.lean:848-888`) chooses its `base`
from `renderCanonical` (`:865-872`):

```
let (base, baseFindings) :=
  match (if renderCanonical then result.canonical? else none) with
  | some canonical => (canonical.text, plan.findings … (canonical.findings ++ patchImports))
  | none           => (normalized,     selected)
```

`RunMode.rendersCanonical` (`:42-44`) is `true` for `format | diff | fix`. So all three render canonical
text **and** compose every admitted rule fix onto it: the canonical fixes come from `canonical.findings`
(`renderCanonicalText`'s `runSourceRules`, `:379-382`) for source rules, from `reprojectCanonical`
(`:418-428`) for syntax `.safe` and the FMT014 rename, and from `patchImports`/`patchDuplicateFindings`
(`:819-828`) for FMT005. Probes 1 and 4 (`evidence/`) show `format` deleting trailing whitespace and
appending a final newline — i.e. applying FMT001/FMT002 — and probe 4b shows it reflowing at the same
time. The user's mental model is Ruff's `check --fix && format`, two commands; the product fuses them.

## 2. The two concerns after the split

- **Layout patch** — `format`, `diff`. `base := canonical.text`; the patch carries **no** rule fix. The
  render is the whole answer. `RunMode.rendersCanonical` stays `true` for these two.
- **Fix patch** — `fix`. `base := normalized` (the file's own coordinates); the patch carries the
  admitted fixes from the original-coordinate `result.findings ++ reportImports`. No reflow.
  `RunMode.rendersCanonical := false` for `fix`.
- **`check`** — unchanged: report only, no published patch, `rendersCanonical = false`.

The mapping collapses cleanly onto `renderCanonical` **once `fix` flips**: layout patch iff
`renderCanonical` (format/diff); fix patch iff `!renderCanonical` (check/fix). `check` and `fix` share the
fix-patch computation over normalized bytes; only `fix` publishes it. This is why the flip of one line
(`rendersCanonical` for `fix`) plus deleting the canonical fix machinery is most of the implementation.

## 3. Whitespace/newline is layout, not a rule (product decision, owner-confirmed)

Probe 5 proves the canonical printer subsumes **neither** trailing whitespace **nor** the final newline:
with FMT001/FMT002 deselected, canonical text equals the input exactly (`changed: False`). So a fix-free
`format` (concern 1) would regress ws/newline unless the formatter takes ownership. It matches
`ruff format`, where ws/newline cleanup is formatter behavior, not a lint.

Probe 4b/6 also surface a **pre-existing FMT001 soundness defect**: FMT001's byte-level trim
(`Rules.lean:197-215`) deletes trailing whitespace **inside** a multi-line string literal, silently
changing the string value, and the output re-elaboration validator does not reject it (the corrupted file
still elaborates). Moving ws/newline into the printer as layout — trimming only the whitespace *trivia*
the printer emits, never token/string bytes — makes the corruption impossible **by construction**.

**Resolution (handed to RDF-LAYOUT, which lands before the patch split so `format` never regresses):**
the canonical printer trims its own emitted trailing whitespace trivia and guarantees exactly one final
newline; **FMT001 and FMT002 retire as lint rules.** Blast radius: FMT001/FMT002 are the fixable-*source*
vehicle across the persistent suite (`LeanFmtTest.lean`, `tests/suppression`, `tests/modes`,
`tests/check`, `tests/imports`, `tests/service`); their tests migrate onto surviving rules
(import FMT005, syntax `.safe` FMT010/FMT011/FMT013, semantic FMT014). FMT003/FMT004 stay report-only
source-tier (`Rules.lean:697,707`, `fix? := none`), so a default `check`/`format` still resolves
`requiredTier == .source` and keeps the source-only fast shortcut (`Application.lean:495-510`). After
retirement there is **no source-tier fixable rule left** — the surviving fix tiers are import, syntax,
and semantic.

## 4. `format`'s report policy (frozen)

`FileReport.findings` is drawn from `result.findings` at **original** coordinates in every mode:
`prepareFile:856` computes `selected := plan.findings … (result.findings ++ reportImports)` and the
report (`findings`, `:857`) derives from it, independent of the `base` branch. So the report is already
invariant under the patch change. **Frozen:** `format`/`diff` keep reporting their original-coordinate
findings; only the *patch* loses fixes. Rejected alternative — `format` reports nothing about lint
(pure Ruff `format`, which is silent) — is deferred, not taken: the product's `format` has always
reported findings, silencing them is a separate UX decision outside this stack's "decouple the patch"
scope, and keeping the report costs nothing (it never depended on the canonical patch).

## 5. What retires (each named so no wasted path stays live)

- `ExactRun.reprojectCanonical` (`:418-428`) and its `(captureSemantic captureOccurrences)` parameters —
  deleted entirely. It rewrites only `canonical.findings` (`:427`), read only by the canonical patch
  (`prepareFile:871`). A fix-free `format` has no consumer, and `check`/`fix` no longer render canonical
  fixes. Confirm no render-only survivor before deleting (the base `canonicalAnalysis` still produces
  `canonical.text` for the layout patch; only the `findings` rewrite goes).
- `ExactRun.analyzeSnapshot`'s reprojection branch (`:439-441`, the `if renderCanonical && (needsSyntax ||
  captureOccurrences)` arm) — removed with `reprojectCanonical`.
- `availableAnalysis`'s `renderCanonical && plan.requiredTier == .syntax` branch (`:511-517`) — removed.
  It forced the ExactRun+reproject path so `format --select FMT01x` re-projected canonical findings; with
  no canonical fix, `format`/`diff` take the artifact path (`:518-519`) and report original-coordinate
  findings without a second frontend run.
- `patchDuplicateFindings` (`:824-828`) and the `patchImports` argument thread — the canonical FMT005
  recompute. FMT005 comes from the original-coordinate `reportImports` already folded into `selected`
  (`:856`). The `some canonical => … ++ patchImports` half of `prepareFile:871` goes with it.
- The `result.canonical?`-as-patch-source branch of `prepareFile` (`:866,870-871`) — collapses to
  `base := normalized` for the fix patch; the layout patch takes `base := canonical.text` with **no**
  findings folded in.
- `renderCanonicalText`'s `findings := runSourceRules text` (`:382`) — the source-rule surface that only
  fed `canonical.findings`. The layout patch needs `canonical.text` only, so `CanonicalText.findings`
  becomes dead; drop the field or stop populating it (RDF-IMPL's call).

## 6. `demandedCaps` rewire (the one non-mechanical change)

Today `RulePlan.demandedCaps` (`Config.lean:326-331`) sets
`occurrences := renderCanonical && plan.selectsOccurrenceRule`. After the `fix` flip, `renderCanonical`
is `true` for format/diff (which apply no fix — wrong to demand the info-tree fold) and `false` for fix
(which needs it — wrong to skip). So the occurrence demand must key off the **apply signal**, not
`renderCanonical`:

> **Frozen trigger:** `occurrences` is demanded iff the run **applies** fixes (mode `= fix`) **and**
> selects an occurrence-fix rule (`selectsOccurrenceRule`, i.e. FMT014). `format`/`diff`/`check` never
> demand it.

Mechanically, thread an `applies : Bool` (true only for `.fix`) into `demandedCaps` (and into
`cacheHitServes`'s `plan.demandedCaps` call at `availableAnalysis:493`) and use it for the `occurrences`
field in place of `renderCanonical`. Keep `notations := renderCanonical` (format/diff need the layout
fact; fix does not reflow, so demands no notations) and `diagnostics := plan.requiredTier == .semantic`
(orthogonal, unchanged). `demandedTier` (`:302-303`) needs **no** rewire: `fix --select FMT014` still
reaches `.semantic` through the rule's own tier, so the semantic artifact is obtained; `fix` selecting a
source/syntax rule stays low-tier because it no longer renders (correct — fix does not need the
formatter's layout fact).

FMT014's occurrences are already captured at original coordinates in the base `analyzeExact` under
`captureOccurrences`, and `deprecatedUse` builds its fix edit from `occ.range` (original coordinates,
`Rules.lean:633-642`). `reprojectCanonical` only *re-derived* that fix on canonical text for the canonical
patch; deleting it leaves the original-coordinate fix in `result.findings`, which the fix patch consumes
directly. Every fix now indexes the same normalized string it is reported against, so the
`RFP-SPEC`-measured coordinate gap (`namespace     Alpha` deleting four bytes) can no longer move a fix
off its bytes.

## 7. Preserved invariants (proved untouched)

- **ruff-11b capability split.** `SemanticCaps`, the `SemanticResult` capability field, `cacheHitServes`'s
  `demandedCaps.subset result.caps` gate (`:486`), and `Tier.satisfies` (`:485`) are orthogonal to
  coordinates. The rewire only changes *when* `occurrences` is demanded (apply signal vs render signal),
  not the gate: a fixable-FMT014 demand still misses a monolithic-era `.semantic` entry
  (`caps.occurrences = false`) rather than serving a false clean.
- **ruff-11b fixable predicate** `spelled == occurrenceDisplay declName` — unchanged; the occurrence is
  captured at original coordinates as before.
- **ruff-06** applicability (`admitted unsafeFixes`, `prepareFile:873-875`), conflict rejection
  (`preparePatch`, `:877-880`), atomic transaction, output re-elaboration validator, and stale-source
  pre-check — unchanged and still gate every `fix` write. (The validator's blind spot to FMT001's
  in-string corruption is resolved by *retiring* FMT001, not by weakening the validator.)
- `check`/`format`/`diff` never write source — unchanged.

## 8. Boundary design — A vs B

The `base`/`baseFindings` selection is the seam. Two designs:

- **Design A — `PatchKind` inside `prepareFile`.** Replace the `renderCanonical` bool at the patch
  branch with a `PatchKind` (`layout | fix | none`) derived from `RunMode` at the caller. `prepareFile`
  branches internally: `layout` → `base := canonical.text`, no fixes; `fix` → `base := normalized`,
  admitted fixes; `none` (check) → report only, no patch. One function, two internal branches, one caller.
- **Design B — split into `prepareLayout` and `prepareFix`.** `prepareLayout` (canonical base, no fixes)
  and `prepareFix` (normalized base, admitted fixes), dispatched by mode at the caller.

**Decision: Design A.** Against the deep-module test:
- *Caller knowledge.* A already funnels the mode→kind mapping through one derivation next to
  `rendersCanonical`; B makes the **caller** dispatch on mode and learn which preparer applies which
  coordinate system — pushing a coordinate decision up to the caller, the opposite of what this stack is
  for. A keeps the coordinate choice inside `prepareFile`.
- *Shared body.* `prepareFile`'s suppression projection (`:857`), admission (`:873-875`), conflict
  rejection (`:877`), and counts (`:883-887`) are identical for both patches. B duplicates them across two
  functions or extracts a third helper — more surface, more drift risk. A shares them by construction.
- *Surface.* A changes one parameter type (`Bool → PatchKind`) and one `match`; the report path (`:856`)
  is literally untouched. B adds two names to the private surface and a caller-side dispatch.
- *Independent change.* Layout and fix concerns still change independently inside A — they are separate
  `match` arms; a future layout-only change touches one arm.

Rejected: **Design B**, for pushing coordinate-system knowledge to the caller and duplicating the shared
admission/conflict/count body. Recorded so RDF-IMPL does not re-litigate it.

## 9. Adversarial cases RDF-FINAL must drive (enumerated for the acceptance prompt)

1. `format`/`diff` fix-free at every surviving tier: import (FMT005), syntax `.safe`, semantic FMT014 —
   the finding survives a post-`format` `check`; with and without `--unsafe-fixes`.
2. `fix` applies each at original coordinates with no reflow; a layout-dirty otherwise-clean fixture keeps
   its layout; a fresh `check` of the written file is clean.
3. Coordinate exactness on the `namespace     Alpha` interior-gap fixture — the fix lands on the correct
   original bytes.
4. Composition both orders (`fix; format` and `format; fix`) reach a fixed point, or a specific
   understood divergence is recorded.
5. Unsafe gating (`withheldUnsafe >= 1`, byte-identical) and idempotence (second `fix`/`format` no-op).
6. Capability split: info-tree fold absent from plain `format` and from a surfaced-only FMT014 `check`,
   present only under the fix demand; monolithic-era entry still misses a fixable-FMT014 demand.
7. Retirement proof by grep: `reprojectCanonical`, `patchDuplicateFindings`, the syntax-branch, the
   canonical patch-source branch, and FMT001/FMT002 all absent.
8. Formatter owns ws/newline: `format` on a ws/no-newline fixture trims + terminates with **no rule
   selected**; the in-string fixture keeps its value under `format` and `fix`.
9. Efficiency: `format --select FMT01x` no longer forces a second frontend run; `fix` on a source-only
   selection takes the source shortcut.

## 10. Remaining uncertainty

- Whether `CanonicalText.findings` is deleted as a field or merely left unpopulated is RDF-IMPL's call;
  either removes the dead source-rule surface. The field may have a non-patch reader worth a grep before
  deletion.
- RDF-LAYOUT owns the exact printer mechanism (trim trivia `Doc` nodes as built vs a token/trivia-aware
  post-pass); this note freezes only that it must be sound by construction (trivia-only), not the
  mechanism.
