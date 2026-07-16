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

def SemanticAnalysis.success (source : String) (findings : Array Finding) : SemanticAnalysis := {
  result? := some {
    schema := semanticResultSchema
    source := Digest.ofString source
    sourceBytes := source.utf8ByteSize
    findings
  }
}

def SemanticAnalysis.broken (diagnostics : Array String) : SemanticAnalysis := {
  result? := none
  diagnostics
}

def SemanticAnalysis.validFor (analysis : SemanticAnalysis) (source : String) : Bool :=
  match analysis.result? with
  | none => !analysis.diagnostics.isEmpty
  | some result =>
    analysis.diagnostics.isEmpty && result.schema == semanticResultSchema &&
      result.source == Digest.ofString source && result.sourceBytes == source.utf8ByteSize

/- Project a compiler protocol response into the product result. Command shapes remain compiler
evidence; source-only product rules never receive a fabricated syntax projection. -/
def SemanticAnalysis.ofEnvelope? (source : String)
    (envelope : AnalysisEnvelope) : Option SemanticAnalysis :=
  match envelope.artifact? with
  | none =>
    if envelope.diagnostics.isEmpty then none else some (.broken envelope.diagnostics)
  | some artifact =>
    if structurallyValid artifact && artifact.source == Digest.ofString source &&
        artifact.sourceBytes == source.utf8ByteSize && envelope.diagnostics.isEmpty then
      some (.success source (runRules source true))
    else
      none

end LeanFmt.Internal
