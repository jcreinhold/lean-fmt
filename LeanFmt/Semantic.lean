module

import all LeanFmt.Analysis

namespace LeanFmt.Internal

structure SemanticResult where
  schema : String
  source : Digest
  sourceBytes : Nat
  findings : Array Finding
  deriving BEq, Lean.ToJson, Lean.FromJson

structure SemanticAnalysis where
  result? : Option SemanticResult
  diagnostics : Array String := #[]
  deriving BEq, Lean.ToJson, Lean.FromJson

def semanticResultSchema : String := "lean-fmt.semantic-result.v1"

/-- `normalized` must be `(LosslessSource.normalize raw).1`, the string every finding indexes. -/
def SemanticAnalysis.success (normalized : String) (findings : Array Finding) : SemanticAnalysis := {
  result? := some {
    schema := semanticResultSchema
    source := Digest.ofString normalized
    sourceBytes := normalized.utf8ByteSize
    findings
  }
}

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
evidence; source-only product rules never receive a fabricated syntax projection. The artifact's own
findings are canonical here — recomputing them on this side would be a second opinion about a module
this process never elaborated, and could disagree with the artifact under different options. -/
def SemanticAnalysis.ofEnvelope? (raw : String)
    (envelope : AnalysisEnvelope) : Option SemanticAnalysis :=
  match envelope.artifact? with
  | none =>
    if envelope.diagnostics.isEmpty then none else some (.broken envelope.diagnostics)
  | some artifact =>
    if structurallyValid artifact && artifact.source.validFor raw &&
        envelope.diagnostics.isEmpty then
      some (.success (LosslessSource.normalize raw).1 artifact.findings)
    else
      none

end LeanFmt.Internal
