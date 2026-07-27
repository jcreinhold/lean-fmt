module

public import LeanFmt.Analysis
public import LeanFmt.Application
public import LeanFmt.ArtifactStore
public import LeanFmt.Cache
public import LeanFmt.Cli
public import LeanFmt.Comments
public import LeanFmt.Config
public import LeanFmt.Discovery
public import LeanFmt.Doc
public import LeanFmt.Edit
public import LeanFmt.Formatter.NativeLayout
public import LeanFmt.Imports
public import LeanFmt.LanguageServer
public import LeanFmt.Rules
public import LeanFmt.Suppression
public import Test

import all LeanFmt.Analysis
import all LeanFmt.Application
import all LeanFmt.ArtifactStore
import all LeanFmt.Cache
import all LeanFmt.Cli
import all LeanFmt.Comments
import all LeanFmt.Config
import all LeanFmt.Discovery
import all LeanFmt.Doc
import all LeanFmt.Edit
import all LeanFmt.Formatter.NativeLayout
import all LeanFmt.Imports
import all LeanFmt.LanguageServer
import all LeanFmt.Rules
import all LeanFmt.Suppression
import all Test.Unit.Fixtures

import Lean.Data.Lsp

open LeanFmt LeanFmt.Internal

open LeanFmt.Test.Unit.Fixtures

namespace LeanFmt.Test.Unit.Semantic

/-- An artifact carrying one surfaced compiler diagnostic. -/
private def fixtureSemanticArtifact : ModuleArtifact :=
  { fixtureArtifact with semantic := some {
      diagnostics := #[
        { kind := "linter.unusedVariables", range := { start := 0, stop := 3 },
          severity := .warning, message := "unused variable `x`" }] } }

/- The semantic fact is additive and demand-gated. The pre-release syntax-artifact replacement has no
legacy decoder: old lossy payloads fail decoding and therefore become ordinary facet misses. -/
private def testSemanticArtifact : IO Unit := do
  ensure (structurallyValid fixtureSemanticArtifact)
    "a v9 artifact carrying the semantic fact was rejected"
  let decoded : Except String ModuleArtifact := Lean.fromJson? (Lean.toJson fixtureSemanticArtifact)
  match decoded with
  | .ok actual => ensure (actual == fixtureSemanticArtifact) "v9 semantic artifact JSON round trip failed"
  | .error message => throw <| IO.userError s!"v9 semantic artifact decode failed: {message}"

  -- The plugin producer emits `semantic = none`; that shape is valid and round-trips too.
  ensure (fixtureArtifact.semantic.isNone) "the plugin-shaped fixture already carried a semantic fact"
  ensure (structurallyValid fixtureArtifact) "a v9 artifact with semantic = none was rejected"
  let noneDecoded : Except String ModuleArtifact := Lean.fromJson? (Lean.toJson fixtureArtifact)
  match noneDecoded with
  | .ok actual => ensure (actual == fixtureArtifact) "v9 semantic = none artifact JSON round trip failed"
  | .error message => throw <| IO.userError s!"v9 semantic = none artifact decode failed: {message}"

  -- A stale `v4` payload is a clean miss, the same discipline as the `v1` miss in `testStore`.
  ensure (!(structurallyValid { fixtureArtifact with schema := "lean-fmt.module-artifact.v4" }))
    "a stale v4 artifact was accepted by the current reader"
  -- Faithful to a `v4` payload with the deleted lossy source projection and no syntax payload.
  let v4none := Lean.Json.mkObj
    [("schema", "lean-fmt.module-artifact.v4"), ("source", Lean.toJson fixtureLosslessSource)]
  match (Lean.fromJson? v4none : Except String ModuleArtifact) with
  | .ok _ => throw <| IO.userError "the v9 decoder retained the deleted v4 payload shape"
  | .error _ => pure ()
/- The shipped semantic-tier rules (FMT012–FMT015) surface the compiler's own diagnostics:
each keys on one stable `kind` tag and re-emits it as a report-only finding under its own code,
preserving the compiler's message, severity, and range. This exercises the whole engine seam over
`.semantic` facts without the exact frontend — the production `runRulesOf` reads `SemanticFacts`
built directly, so the mapping is pinned as pure data. `tests/semantic/run.sh` proves the *capture*
half against Lean's own emission; this proves the *rule* half.

Every assertion is about the shipped `ruleRegistry`, not a probe, because these are real shipped rules
(the reason `testEngineTiers`' representative rules could not be semantic before). -/
private def testSemanticRules : IO Unit := do
  let mkDiag (kind : String) (start stop : Nat) (message : String) : Diagnostic :=
    { kind, range := { start, stop }, severity := .warning, message }
  -- One diagnostic per surfaced kind, plus one kind no rule owns. Distinct starts pin byte-ordering.
  let diagnostics := #[
    mkDiag "Lean.Linter.deprecatedAttr"       0 4 "`oldName` is deprecated",
    mkDiag "linter.unusedVariables"           5 6 "unused variable `x`",
    mkDiag "linter.unusedSectionVars"         7 8 "unused section variable `inst`",
    mkDiag "linter.constructorNameAsVariable" 9 10 "`true` resembles a constructor",
    mkDiag "linter.unownedByAnyRule"          2 3 "no rule surfaces this kind"]
  let facts := Facts.semantic (SemanticFacts.of fixtureSourceText fixtureLosslessSource diagnostics)
  let findings := runRulesOf ruleRegistry facts

  -- Each surfaced kind maps to exactly its code, preserving the compiler's own range/severity/message.
  let expect : Array (String × String × Nat × Nat) := #[
    ("FMT012", "`oldName` is deprecated", 0, 4),
    ("FMT013", "unused variable `x`", 5, 6),
    ("FMT014", "unused section variable `inst`", 7, 8),
    ("FMT015", "`true` resembles a constructor", 9, 10)]
  for (code, message, start, stop) in expect do
    match findings.filter (·.code == code) with
    | #[f] =>
      ensure (f.message == message) s!"{code} did not preserve the compiler's message"
      ensure (f.range.start == start && f.range.stop == stop) s!"{code} did not preserve the diagnostic range"
      ensure (f.severity == .warning) s!"{code} did not preserve the diagnostic severity"
      ensure (f.fix?.isNone) s!"{code} is report-only but carried a fix"
    | other => throw <| IO.userError s!"expected exactly one {code} finding, got {other.size}"

  -- A kind no rule owns yields no finding: the rules read only the tags they name, never everything
  -- the artifact happens to carry. (Capture already filters to `surfacedDiagnosticKinds`; this pins
  -- that the rule side is closed the same way — an unowned kind fed in directly is still dropped.)
  ensure (surfacedDiagnosticKinds.size == 4) "surfacedDiagnosticKinds no longer lists exactly the four rules"
  ensure ((findings.filter (fun f => #["FMT012", "FMT013", "FMT014", "FMT015"].contains f.code)).size == 4)
    "the surfaced rules produced other than one finding per owned kind (the unowned kind leaked)"

  -- The engine skips semantic rules cleanly when only cheaper facts are on hand — not guessed at, not
  -- defaulted, not an error — exactly as it skips a syntax rule on source facts. `requiredTierOf` is
  -- what makes the skip sound (it decided not to obtain these diagnostics), and it reads one registry.
  let semanticCodes := #["FMT012", "FMT013", "FMT014", "FMT015"]
  let onSyntax := runRulesOf ruleRegistry (.syntax (SyntaxFacts.of fixtureSourceText fixtureLosslessSource))
  ensure (onSyntax.all (fun f => !semanticCodes.contains f.code))
    "a semantic rule fired on syntax facts that never carried a diagnostic"
  let onSource := runRulesOf ruleRegistry (.source (SourceFacts.of fixtureSourceText))
  ensure (onSource.all (fun f => !semanticCodes.contains f.code))
    "a semantic rule fired on source facts that never carried a diagnostic"

/- The owned FMT012 rename fix. The report is surfaced from the diagnostic
(unchanged, always cheap); the `unsafe` rename fix is attached from the owned occurrence fact — and
only when a *fixable* occurrence sits at the surfaced finding's own range with a `newName?`. This pins
the rule half as pure data: the report never changes across the occurrence cases, only `fix?` does, so
a `check` (empty occurrences) is byte-identical to the original surfaced-only behavior. `run.sh` proves
the fix *applies* end to end through canonical re-projection; this pins the *attachment* predicate. -/
private def testOwnedDeprecationFix : IO Unit := do
  let depRange : SourceRange := { start := 0, stop := 4 }
  let diag : Diagnostic :=
    { kind := "Lean.Linter.deprecatedAttr", range := depRange, severity := .warning,
      message := "`oldName` is deprecated" }
  -- Run the shipped registry over `.semantic` facts carrying one deprecation diagnostic and a chosen
  -- set of occurrences; return the single FMT012 finding (there is exactly one surfaced diagnostic).
  let fmt014 (occurrences : Array DeprecatedOccurrence) : IO Finding := do
    let facts := Facts.semantic
      (SemanticFacts.of fixtureSourceText fixtureLosslessSource #[diag] occurrences)
    match (runRulesOf ruleRegistry facts).filter (·.code == "FMT012") with
    | #[f] => return f
    | other => throw <| IO.userError s!"expected exactly one FMT012 finding, got {other.size}"
  -- The report an occurrence set must never perturb: same code/severity/message/range every time.
  let reportUnchanged (f : Finding) (label : String) : IO Unit := do
    ensure (f.severity == .warning && f.message == "`oldName` is deprecated" && f.range == depRange)
      s!"FMT012 report was perturbed by the {label} occurrence set"

  let fixable : DeprecatedOccurrence :=
    { range := depRange, declName := "oldName", newName? := some "newName",
      since? := some "1.0", text? := none, fixable := true }

  -- A. A fixable occurrence at the finding's range with a `newName?` attaches an `unsafe` rename whose
  -- one edit replaces exactly that range with the new name.
  let a ← fmt014 #[fixable]
  reportUnchanged a "fixable"
  match a.fix? with
  | some fix =>
    ensure (fix.applicability == .unsafe) "FMT012 rename fix must be unsafe (unproven textual swap)"
    ensure (fix.edits == #[{ range := depRange, replacement := "newName" }])
      "FMT012 fix did not replace the occurrence range with the deprecation's newName"
  | none => throw <| IO.userError "a fixable deprecation occurrence attached no fix"

  -- B. A non-bare occurrence (`fixable := false`) stays report-only — the capture-side predicate, not
  -- the rule, decides bareness, and the rule offers no fix without it.
  let b ← fmt014 #[{ fixable with fixable := false }]
  reportUnchanged b "non-fixable"
  ensure (b.fix?.isNone) "FMT012 attached a fix to a non-fixable (non-bare-identifier) occurrence"

  -- C. A `newName? = none` occurrence (deprecation with no replacement) stays report-only: there is no
  -- name to substitute, so no rename can be offered even though the use is bare.
  let c ← fmt014 #[{ fixable with newName? := none }]
  reportUnchanged c "no-replacement"
  ensure (c.fix?.isNone) "FMT012 attached a fix to a deprecation with no replacement name"

  -- D. An occurrence at a *different* range does not match the surfaced finding — the fix attaches by
  -- range identity, never by position or count, so a stray occurrence cannot mis-fix another finding.
  let d ← fmt014 #[{ fixable with range := { start := 100, stop := 104 } }]
  reportUnchanged d "range-mismatch"
  ensure (d.fix?.isNone) "FMT012 attached a fix from an occurrence at a different range"

  -- E. No occurrences (the `check` path, or any run that did not demand the capability): report-only,
  -- byte-identical to the surfaced-only behavior FMT012 shipped with.
  let e ← fmt014 #[]
  reportUnchanged e "empty"
  ensure (e.fix?.isNone) "FMT012 was not report-only when no occurrences were captured"
  ensure (e == { a with fix? := none })
    "the surfaced-only FMT012 finding is not the fixable one minus its fix (report drifted)"

/- `SemanticCaps.subset` and the `needsOccurrences`↔tier invariant. The subset gate is what makes a
report-only `.semantic` cache entry miss a fixable-FMT012 demand rather than serve a false
clean; the invariant is what keeps the capability from rotting into an unenforced field. -/
private def testSemanticCaps : IO Unit := do
  let all : SemanticCaps := { occurrences := true }
  let cheap : SemanticCaps := {}
  let occ : SemanticCaps := { occurrences := true }
  -- `{}` demands nothing, so a source/syntax run is served by any entry.
  ensure (SemanticCaps.subset {} all && SemanticCaps.subset {} {}) "the empty demand is not a subset of everything"
  -- A full entry serves every demand; the demand serves itself.
  ensure (SemanticCaps.subset occ all && SemanticCaps.subset occ occ) "occurrences demand not served by an entry that has it"
  -- The load-bearing miss: an occurrences demand against a report-only entry is not a subset, so
  -- `cacheHitServes` recomputes rather than serving a false clean.
  ensure (!SemanticCaps.subset occ cheap && !SemanticCaps.subset occ {})
    "a fixable-FMT012 demand was (wrongly) served by an entry that captured no occurrences"
  -- The empty demand is served by an occurrence-bearing entry (superset), orthogonal to the tier.
  ensure (SemanticCaps.subset cheap all) "the cheap sub-facts are not a subset of the full capability set"

  -- The invariant: a `needsOccurrences` rule is `.semantic` (its fix reads an info-tree fact), and only
  -- FMT012 declares it today. A declared-but-unenforced capability would rot exactly as a tier field
  -- would; this ties it to the tier the registry actually derives from the constructor.
  for rule in ruleRegistry do
    if rule.info.needsOccurrences then
      ensure (rule.tier == .semantic)
        s!"{rule.info.code} needs occurrences but is not a semantic-tier rule"
  ensure ((ruleRegistry.filter (·.info.needsOccurrences)).map (·.info.code) == #["FMT012"])
    "exactly FMT012 must declare needsOccurrences (a new owner needs its own capture + tests)"

/-- The cases this module contributes to the unit runner, in run order. -/
public def cases : Array Case := #[
  { name := "testSemanticArtifact", run := testSemanticArtifact },
  { name := "testSemanticRules", run := testSemanticRules },
  { name := "testOwnedDeprecationFix", run := testOwnedDeprecationFix },
  { name := "testSemanticCaps", run := testSemanticCaps }]

end LeanFmt.Test.Unit.Semantic
