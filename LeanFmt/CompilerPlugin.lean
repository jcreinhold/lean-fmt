module

import all LeanFmt.ArtifactModel
import all LeanFmt.Rules
import Lean.Linter.PersistentLintLog

open Lean Elab Command

namespace LeanFmt.Internal.CompilerPlugin

register_option leanFmt.trailingWhitespace : Bool := {
  defValue := true
  descr := "report and repair trailing horizontal whitespace"
}


private def produceArtifact (commands : Array Syntax) : CommandElabM Unit := do
  let options ← getOptions
  let checkTrailingWhitespace := leanFmt.trailingWhitespace.get options
  let environment ← getEnv
  if environment.mainModule.isAnonymous then
    return
  let fileMap ← getFileMap
  let source := fileMap.source
  let artifact : ModuleArtifact := {
    schema := artifactSchema
    source := LeanFmt.Digest.ofString source
    sourceBytes := source.utf8ByteSize
    mainModule := environment.mainModule.toString
    trailingWhitespace := checkTrailingWhitespace
    commands := projectCommands commands
    findings := runRules source checkTrailingWhitespace
  }
  logAt (← getRef)
    (.tagged artifactLinter <| .tagged Lean.Linter.linterMessageTag <|
      m!"{Lean.toJson artifact |>.compress}")
    (severity := .information) (isSilent := true)

initialize addModuleLinter { name := `leanFmtSemanticArtifact, run := produceArtifact }

end LeanFmt.Internal.CompilerPlugin
