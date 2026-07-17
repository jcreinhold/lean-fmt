module

import all LeanFmt.Analysis

namespace LeanFmt.Internal

/-- A module's canonical layout, and the source-rule findings that index **it** rather than the file.

Both halves are needed and neither can be recovered from the other side of a cache hit. `text` is what
`format` prints and what `fix` publishes. `findings` exists because canonical text is *not* lint-clean:
the printer keeps a command's trailing trivia run verbatim (`Printer.lean:208-222`), so it strips no
trailing whitespace and adds no final newline — `RFP-SPEC` §6 checked this rather than assuming it.
Re-running the rules is therefore mandatory, and it cannot be deferred to the caller, because
canonicalizing moves bytes: `namespace     Alpha` loses four of them, and every `findings` offset past
that point would land in the wrong column. The two arrays are the same rules in two coordinate
systems, and mixing them corrupts files.

Both are selection-independent — `runRules` produces every rule's findings and `RulePlan.findings`
projects afterwards — so one cache entry still serves any `--select`. -/
structure CanonicalText where
  text : String
  findings : Array Finding
  deriving BEq, Lean.ToJson, Lean.FromJson

structure SemanticResult where
  schema : String
  source : Digest
  sourceBytes : Nat
  findings : Array Finding
  /-- `none` when this result was produced without a projection to render — the source-only shortcut
  in `availableAnalysis` takes no artifact, so a `check` run caches an entry a later `format` cannot
  use. Such an entry is a miss for a rendering mode rather than an answer, which is why this is an
  `Option` and not a `String`. -/
  canonical? : Option CanonicalText := none
  deriving BEq, Lean.ToJson, Lean.FromJson

structure SemanticAnalysis where
  result? : Option SemanticResult
  diagnostics : Array String := #[]
  deriving BEq, Lean.ToJson, Lean.FromJson

/-- `v2` adds `canonical?`. `validFor` compares this exactly, so every `v1` entry on disk is a miss
rather than a silently under-populated hit — a `v1` entry deserialized under `v2` would carry
`canonical? := none` from the field default and read as "this file needs no canonical text", which is
the stale-output bug `RFP-SPEC` §7 named. The schema is what makes the default safe. -/
def semanticResultSchema : String := "lean-fmt.semantic-result.v2"

/-- `normalized` must be `(LosslessSource.normalize raw).1`, the string every finding indexes. -/
def SemanticAnalysis.success (normalized : String) (findings : Array Finding) : SemanticAnalysis := {
  result? := some {
    schema := semanticResultSchema
    source := Digest.ofString normalized
    sourceBytes := normalized.utf8ByteSize
    findings
  }
}

/-- Attach a rendered canonical layout to an already-validated result.

Separate from `success` because rendering needs `IO` (`Printer.format` parses the header) while every
other step here is pure, and because it must happen *after* `ofEnvelope?` has checked
`structurallyValid` and `validFor`: rendering a projection that does not match its own source would
produce canonical text for a file that does not exist. Applying this to a `broken` analysis is a
no-op — there is nothing to render and nothing to attach it to. -/
def SemanticAnalysis.withCanonical (analysis : SemanticAnalysis)
    (canonical : CanonicalText) : SemanticAnalysis :=
  { analysis with result? := analysis.result?.map ({ · with canonical? := some canonical }) }

def SemanticAnalysis.broken (diagnostics : Array String) : SemanticAnalysis := {
  result? := none
  diagnostics
}

/-- `raw` is the file as the caller read it; identity is normalized, so normalize before comparing.
Every `validFor` in the product takes raw bytes and normalizes, so no caller has to remember which
coordinate system a given identity lives in. -/
def SemanticAnalysis.validFor (analysis : SemanticAnalysis) (raw : String) : Bool :=
  match analysis.result? with
  | none => !analysis.diagnostics.isEmpty
  | some result =>
    let normalized := (LosslessSource.normalize raw).1
    analysis.diagnostics.isEmpty && result.schema == semanticResultSchema &&
      result.source == Digest.ofString normalized &&
      result.sourceBytes == normalized.utf8ByteSize

/- Project a compiler protocol response into the product result. The projection remains compiler
evidence; source-only product rules never receive a fabricated syntax projection.

**The findings are computed here, from the artifact's facts.** They used to travel inside the
artifact, and this comment used to defend that: recomputing them would be "a second opinion about a
module this process never elaborated, and could disagree with the artifact under different options".
The second clause was the only thing holding the first up, and it was circular — findings could
disagree under different options only because a rule's enablement *was* an option. It is not any
more. A rule is a pure total function of its facts, and `validFor` on the line above has just proved
this artifact describes exactly these bytes, so there is one input and one function and no second
opinion available to have.

The empirical version is shorter. Carrying findings in the artifact did not prevent disagreement; it
caused the one `notes/01-rule-facts.md` §2 measured, where `check` reported a rule the artifact said
was off. Two deciders disagreed, so there is now one. -/
def SemanticAnalysis.ofEnvelope? (raw : String)
    (envelope : AnalysisEnvelope) : Option SemanticAnalysis :=
  match envelope.artifact? with
  | none =>
    if envelope.diagnostics.isEmpty then none else some (.broken envelope.diagnostics)
  | some artifact =>
    if structurallyValid artifact && artifact.source.validFor raw &&
        envelope.diagnostics.isEmpty then
      let normalized := (LosslessSource.normalize raw).1
      some (.success normalized (runRules (.syntax (SyntaxFacts.of normalized artifact.source))))
    else
      none

end LeanFmt.Internal
