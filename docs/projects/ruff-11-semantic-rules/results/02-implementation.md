---
kind: result
claim_id: RMR-IMPL
status: verified
---

# RMR-IMPL — the four surfaced semantic rules and the `v5` diagnostics projection

The four semantic-tier rules FMT014–FMT017 ship end to end: the exact frontend normalizes its own
`MessageLog` into immutable byte-range `Diagnostic` facts carried in a demanded `.semantic` artifact,
the rule engine runs them from those facts in the reporting process, and the source-only / syntax-only
fast paths are untouched when no semantic rule is selected and nothing renders. All four are
report-only in this cut (recorded, not silent); the owned/fixable FMT014 autofix and the Design-B
capability split remain deferred per `notes/01-authority.md` §§8,11. Toolchain
`leanprover/lean4:v4.32.0`; base `bf3116d`; `Darwin arm64`.

## What shipped (work order `notes/01-authority.md` §11)

1. **Projection (`v4 → v5`).** `ArtifactModel.lean`: `Diagnostic` (`kind : String`, `range :
   SourceRange`, `severity`, `message`), `SemanticProjection.diagnostics : Array Diagnostic := #[]`,
   `artifactSchema := "…v5"`. Engine: `Rules.lean` `SemanticFacts` (nests `SyntaxFacts`, adds
   `diagnostics`), `Facts.semantic`, `RuleImpl.semantic` (`tier → .semantic`), and the four
   `runRulesOf` rows — a `.semantic` rule runs on `.semantic` facts, a `.syntax` rule runs on the
   nested syntax facts, and both skip cleanly on cheaper facts (the skip is a match arm, not a guard,
   so it cannot drift from `requiredTierOf`).
2. **Capture (`Analysis.lean`).** `captureDiagnostics` filters the whole-file `MessageLog` by
   `surfacedDiagnosticKinds` (one source of truth shared with the rules), converts each `(pos, endPos)`
   through the frontend's `FileMap` (built on `crlfToLf`-normalized source, so the offsets share the
   projection's coordinate system), clamps to `[0, sourceBytes]`, and serializes the compiler's own
   message text. Monolithic with the notation capture (Design A): both sub-facts populate together
   only when `captureSemantic` is set, so a demanded `.semantic` artifact is complete and
   `Tier.satisfies` stays a sound cache gate.
3. **Rules + registry (`Rules.lean`).** `surfaceDiagnostics kind code` re-emits each captured
   diagnostic of one `kind` as a report-only `Finding` preserving the compiler's message/severity/range
   (`fix? := none`). FMT014 deprecation / FMT015 unused / FMT016 unused / FMT017 naming, all
   `defaultEnabled := false`, all in `ruleRegistry` and thus `allRuleInfos` / `rules --json`.
4. **Fix classification.** All four report-only in this cut — surfacing a deprecation or an unused
   binder is not an edit any fact here proves safe (§3). Recorded (`fixable:false`), not silent.
5. **Fast paths preserved.** `Config.demandedTier` folds the shipped registry: a source/syntax-only
   selection that does not render still demands only its rules' tier (unit-pinned for FMT001 and the
   whole registry; `demandedTier false == .semantic` now holds for an FMT014 selection — the second
   demander beside the render mode). `Semantic.ofEnvelope?` branches on `artifact.semantic`: `some` →
   `.semantic` facts + `.semantic` tag (whole registry incl. FMT014–017); `none` → `.syntax` facts +
   `.syntax` tag, byte-for-byte as before.
6. **Tests** — below.

## Commands and raw evidence

- `LEAN_NUM_THREADS=1 lake build` — clean (42 jobs).
- `lake exe lean-fmt-tests` → `lean-fmt module-artifact tests passed`. New/changed unit coverage in
  `LeanFmtTest.lean`:
  - `testSemanticRules` (new): builds `.semantic` facts from hand-authored `Diagnostic`s (four surfaced
    kinds + one unowned) and asserts each surfaced kind maps to exactly its code preserving
    range/severity/message and report-only; the unowned kind yields nothing; and the four rules skip
    cleanly on `.syntax` and `.source` facts.
  - `testEngineTiers`: the now-false `ruleRegistry.all (·.tier != .semantic)` assertion is replaced —
    the registry now spans all three tiers (source+syntax+semantic).
  - `testMixedSelection`: adds `semanticPlan.demandedTier false == .semantic` (a `.semantic`-rule
    selection demands the fact with no rendering).
  - `testSemanticArtifact`: fixture and guard bumped `v4 → v5` (the fixture now carries a diagnostic);
    the stale-payload cases pin verified decoder behavior (see "Decoder behavior" below).
- `tests/semantic/run.sh` → `diagnostics differential: matched 4 kinds [...]`,
  `lean-fmt semantic differential + demand-gating tests passed`. The production capture path
  (`__analyze-exact … 1`) reproduces, byte for byte, the `(kind, range)` an independent
  `lean --json` frontend emits on `tests/semantic/Diagnostics.lean` for all four kinds; `… 0` carries
  no semantic fact (demand-gating); only the surfaced kinds are captured (`got_kinds == want`).
- `tests/boundary/run.sh` → `native module and dependency boundary passed`. `LeanFmt.Rules` is still
  absent from `CompilerPlugin.lean`'s imports and the plugin lib globs; capture lives in `Analysis.lean`
  and reads only data across the process boundary (no `Environment`/`FileMap`/`Position` reaches a rule).
- Suites over touched modules, all passed: `check`, `compiler`, `modes` (the `rules --json` list +
  category/fixable/default/`input == "semantic"` assertions updated for FMT014–017), `suppression`,
  `lossless`, `syntax`, `service`, `scale`.
- `git diff --check` — clean.
- KanProofs structural checker and `write_next.py --check` — run below; recorded in `state/current.md`.

## Decoder behavior (verified, corrects a spec assumption)

`notes/01-authority.md` §6 and the draft schema comments assumed the `diagnostics` field default made
the `v5` decoder *total* over a `v4` full-`semantic` payload (reading as captured-and-empty, then
schema-missing). Verified against v4.32.0 (`structure S where … b : Array Nat := #[] deriving
FromJson`): the derived `FromJson` does **not** default an absent array field — it errors
(`expected JSON array, got 'null'`). So a genuine `v4` full-`semantic` payload (notations, no
`diagnostics` key) *fails to decode*, which is still a miss (a foreign payload is discarded, not
served), with the schema tag the primary gate and decode-failure the backstop. Only `Option` fields
(here `ModuleArtifact.semantic`) default on a missing key, so a `v4` payload *without* the `semantic`
key decodes with `semantic := none` and the schema guard rejects it. `ArtifactModel.lean`'s schema
comment and `testSemanticArtifact` were corrected to state this verified behavior rather than the
assumed one; the product invariant ("a pre-`v5` payload is never served as a valid `v5` artifact")
holds on both paths. A round-tripped `v5` artifact always carries the `diagnostics` key (ToJson emits
all fields), so decode is total within `v5`.

## Stop-rule checks

- **Schema and cache identity include the compiler/runtime version.** Artifact schema is `…v5`; the
  result cache keys on `lean-version\0{Lean.versionString}` and `lean-githash\0{githash}`
  (`Cache.lean:167-168`), and the artifact rides the module `.olean`'s Lake trace (toolchain-bound).
- **No retained mutable environment.** Capture reads `commandState.env`/`FileMap`/`MessageLog` inside
  `analyzeExact` and emits only immutable `Diagnostic` data; process exit remains the reclamation
  boundary. No `Environment` crosses into a rule.
- **Exact semantics / write safety / resource envelope unweakened.** `check`/`format`/`diff` still
  never write; all four rules are report-only; the service suite's RSS (`peak_rss_kib: 1044400`, ~1.0
  GiB) is well under the 8 GiB envelope.

## Remaining uncertainty (carried into RMR-FINAL)

- **(a) `endPos = none`** — `captureDiagnostics` falls back to a zero-width point range (`stop :=
  start`). All four surfaced kinds carry `endPos` on v4.32.0 (the differential matched full ranges), so
  the fallback is untriggered by the shipping catalog; it is defined, not exercised. RMR-FINAL may
  assert it directly if a whole-line kind is ever surfaced.
- **(b) Macro-reattributed ranges** — resolved by clamping: a `start > sourceBytes` is dropped and a
  `stop` past the span is clamped, so no finding lands off the file. Not observed to trigger on the
  fixture; the guard is defensive.
- **(c) Suppression** — resolved: `Suppression.apply` filters `Array Finding` by `finding.code` and
  byte scope only (`Suppression.lean:288,362`), entirely tier-agnostic, so a `# lean-fmt: disable[FMT014]`
  directive suppresses a surfaced finding exactly as a source one. The suppression suite passes with the
  semantic rules in the registry.
- **(d) Owned/fixable FMT014 + Design B** — deliberately deferred (`notes/01-authority.md` §8); the one
  genuinely heavy piece (whole-file info-tree occurrence walk), proven surfaced-first.

## Status

RMR-IMPL: **verified.** The four surfaced rules and the `v5` diagnostics projection are implemented
behind the existing private architecture, the capture reproduces the compiler's own emission on an
independent oracle, the fast paths and boundary are preserved, and every touched-module suite passes.
One spec assumption (decoder totality over a fieldless array) was corrected to verified behavior. The
deferred owned-autofix and Design-B split are the only outstanding pieces, both out of scope for this
cut by design.
