# 01-model — the syntax-fix composition interface (RYC-SPEC)

Frozen interface for applying a syntax-tier rule's `.safe` fix through `fix`/`format`, honoring the
model `ruff-06`'s RFX-SPEC froze (`ruff-06-fix-safety/notes/01-model.md` §3): compose by
**re-projecting the canonical text**, never by translating original-coordinate edits onto moved bytes.

## 1. The current boundary (characterized)

The fix lifecycle already carries every mechanism the composition needs *except* the syntax findings
on canonical coordinates. Reading the live path:

- `renderCanonicalText` (`LeanFmt/Application.lean:376`) renders canonical `text` with
  `Printer.format` and returns `CanonicalText { text, findings := runSourceRules text }`. **Only
  source rules run.** This is the sole gap.
- `prepareFile` (`Application.lean:788`) builds the write patch. Its canonical branch
  (`Application.lean:805-812`) sets `base := canonical.text` and
  `baseFindings := plan.findings (canonical.findings ++ patchImports)` — the patch is assembled from
  **`canonical.findings`**. Whatever findings `renderCanonicalText` puts there become the fix edits.
- Admission (`Application.lean:813-816`) strips any non-`admitted` fix to `none`; `preparePatch`
  assembles the edits; `Edit.validateConflicts` (`LeanFmt/Edit.lean:93`) rejects the whole file with
  provenance if two admitted edits overlap. All of this is tier-agnostic — it operates on `Finding`s
  with `fix?`, whatever tier produced them.
- `fixFile` (`Application.lean:886`) validates by re-elaborating the *output* bytes
  (`run.analyzeSnapshot candidate (validator := true)`, `Application.lean:908-909`) and only then
  `publishAtomic` (`Application.lean:599`) writes. The write is already validated to elaborate.

So the composition reduces to one question: **put the canonical-coordinate syntax findings into
`CanonicalText.findings`.** Everything downstream composes unchanged.

Why the edits are then correct-by-construction: a finding computed *from the canonical projection*
indexes the canonical text's own bytes, so its fix `Edit` is natively in canonical coordinates — the
coordinate system `prepareFile`'s `base := canonical.text` already applies edits in. This is precisely
ruff-06's "re-project, don't translate": there is no byte translation to get wrong.

## 2. The projection is compiler evidence, and canonical text has none of its own

`SyntaxFacts` (`LeanFmt/Rules.lean:79-89`) needs a `LosslessSource` projection and the string it
indexes; `SyntaxFacts.of normalized projection`. Today the projection is the compiler artifact's
projection of the *original* source (`Semantic.lean:151`, `runRules (.syntax (SyntaxFacts.of normalized
artifact.source))`), and `Semantic.lean:125-126` states the invariant deliberately: "the projection
remains compiler evidence; source-only product rules never receive a fabricated syntax projection."

Canonical text was never compiled — it is the printer's fresh output — so it has no artifact
projection. Re-projecting it is unavoidable, and there are two ways to get the projection.

## 3. Two designs

### Design A — re-project via the exact frontend (CHOSEN)

At the point `renderCanonicalText` has `text`, when the plan demands the syntax tier
(`plan.requiredTier == .syntax`, `Application.lean:423-440`, `Config.RulePlan.demandedTier`
`Config.lean:302`), re-run the exact frontend on the canonical text —
`run.analyzeSnapshot (snapshot.withSource text) (renderCanonical := false)` — and use *that* analysis's
`result.findings` (the whole registry over the canonical projection) as `CanonicalText.findings`.
Otherwise keep `runSourceRules text` exactly as today.

- **Caller knowledge.** The render path must learn (a) the `ExactRun` and (b) one bit,
  `needsSyntax := plan.requiredTier == .syntax`. `renderCanonicalText` is reached from
  `ExactRun.analyzeSnapshot` (`Application.lean:393`) → `canonicalAnalysis` (`381`), both of which can
  thread `run` and the bit down. No rule and no CLI code learns anything new.
- **Invariants hidden.** The "projection is compiler evidence" invariant (§2) is *preserved*: the
  canonical projection is a real frontend run, not a fabricated parse. Coordinate identity is preserved
  by construction (findings index the text they came from).
- **Error surface.** None new: `analyzeSnapshot` already throws `invalid exact analysis` on a
  projection that does not match its bytes; canonical text elaborates by construction (it is a valid
  elaborated module reprinted), and a file that did not analyze never reaches canonical rendering.
- **Exactness / cache identity.** `check` is untouched (it never renders canonical). The re-projection
  is on the fix/format write path only; `SemanticResult` cache identity is unchanged.
- **Critical path / memory.** One extra frontend run **only** on a file whose selected rules demand
  syntax *and* render canonical — gated exactly as `requiredTier` already gates projection
  (`ruff-06` authorized this: "RFX-IMPL pays it only when such a rule is selected"). Bounded by the
  same `ExactRun` memory envelope as every other frontend run.
- **Determinism.** Canonical text is a pure function of the artifact; its projection is a pure function
  of the canonical text; the findings are pure functions of the projection. No fix-then-format vs
  format-then-fix disagreement is possible because there is only one order: format, then re-project,
  then fix. This is why ruff-06 rejected the apply-to-original-then-format alternative.

### Design B — parse-only projection (rejected for v1)

Parse the canonical text into a `LosslessSource` directly (a parse, not a full elaboration), build
`SyntaxFacts.of text projection`, run only the syntax registry, and merge with `runSourceRules text`.

- **Cheaper** — a parse instead of an elaboration, matching ruff-06's "a second parse per file"
  phrasing literally.
- **Rejected for v1 because:** it introduces a new projection-construction path outside compiler
  evidence (against `Semantic.lean:125-126`), adds new coordinate-system surface to get wrong, and
  duplicates registry dispatch that Design A gets for free. Its cost advantage is real but unmeasured;
  Design A reuses 100% of the existing envelope→`ofEnvelope?`→`runRules` machinery with a bounded,
  authorized cost. **B is the named optimization if RYC-FINAL's frozen-sample measurement shows the
  elaboration cost is unacceptable.** Until there is a measured reason, the safe, machinery-reusing path
  wins.

## 4. Gating, and what does NOT change

- Re-project only when `plan.requiredTier == .syntax` on a canonical-rendering run. A `fix`/`format`
  whose selected rules are all source-tier keeps `runSourceRules text` and pays no second frontend run.
- `check` is unchanged (no canonical render, no re-projection).
- `SemanticResult` cache identity and `cacheHitServes` are unchanged; this stack owns only the
  `CanonicalText.findings` content on the write path.
- Admission, conflict rejection, atomic publication, and output validation are unchanged — they already
  handle any-tier findings.

## 5. Adversarial obligations handed to RYC-FINAL

1. **A fix that moves tokens under re-projection.** Construct a fixture whose syntax `.safe` fix, once
   applied to canonical text, shifts later tokens; confirm the applied bytes are correct (Design A
   computes the edit from the canonical projection, so a byte-translation bug is structurally
   impossible — the test proves it).
2. **UTF-8 boundary.** A fix whose edit range abuts a multibyte glyph (`↦`, `·`, `ϕ`); confirm byte
   offsets are exact (the `((ϕ i x))` frozen-sample case is the natural driver).
3. **Multi-edit fix.** FMT013 already emits two edits (outer `(` and `)`); confirm both land under
   re-projection.
4. **Syntax-vs-source conflict.** A file where an admitted syntax fix and an admitted source fix touch
   overlapping canonical ranges; confirm `validateConflicts` rejects the whole file with provenance
   naming both rules.
5. **Idempotence.** After `fix`, a re-`check` of the written file reports nothing and a second `fix` is
   a no-op.
6. **Frozen-sample composition run.** Manually review every applied edit for exactness and pass-order
   independence.

## 6. Evidence locators

`renderCanonicalText` `Application.lean:376`; `prepareFile` canonical branch `Application.lean:805-812`;
admission `Application.lean:813-816`; `fixFile` validator + publish `Application.lean:908-912`, `599`;
`Edit.validateConflicts` `Edit.lean:93`; `CanonicalText` `Semantic.lean:21`, `withCanonical`
`Semantic.lean:104`; compiler-evidence invariant `Semantic.lean:125-151`; `SyntaxFacts`
`Rules.lean:79-89`; gating `Application.lean:423-440`, `Config.lean:302`; exact frontend `analyzeExact`
`Analysis.lean:107`, `ExactRun.analyzeSnapshot` `Application.lean:393`; the deferral this closes
`Application.lean:358-375`.
