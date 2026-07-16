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


/- A module linter receives the non-terminal command stream and runs at the terminal command, which
is `getRef` here. The terminal is what ends the parsed region — `eoi` ordinarily, `#exit` for a file
with an unparsed tail — so the projection needs it and the command stream does not contain it.

`fileMap.source` is the string the parser saw, already normalized by `Parser.mkInputContext`. This
position cannot observe the file's bytes, which is why artifact identity is normalized identity. -/
private def produceArtifact (commands : Array Syntax) : CommandElabM Unit := do
  let options ← getOptions
  let checkTrailingWhitespace := leanFmt.trailingWhitespace.get options
  let environment ← getEnv
  if environment.mainModule.isAnonymous then
    return
  let fileMap ← getFileMap
  let terminal ← getRef
  let artifact := ModuleArtifact.ofParsedModule environment.mainModule.toString fileMap.source
    commands (some terminal) checkTrailingWhitespace
  logAt terminal
    (.tagged artifactLinter <| .tagged Lean.Linter.linterMessageTag <|
      m!"{Lean.toJson artifact |>.compress}")
    (severity := .information) (isSilent := true)

initialize addModuleLinter { name := `leanFmtSemanticArtifact, run := produceArtifact }

end LeanFmt.Internal.CompilerPlugin
