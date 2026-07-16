module

import all LeanFmt.ArtifactModel
import Lean.Linter.PersistentLintLog
import Lake.Build.Common

namespace LeanFmt.Internal

private def validRange (sourceBytes : Nat) (range : SourceRange) : Bool :=
  range.start <= range.stop && range.stop <= sourceBytes

private def validEdit (sourceBytes : Nat) (edit : Edit) : Bool :=
  validRange sourceBytes edit.range

private def validFinding (sourceBytes : Nat) (finding : Finding) : Bool :=
  validRange sourceBytes finding.range && finding.fix?.all (validEdit sourceBytes)

private def validCommand (sourceBytes : Nat) (command : CommandShape) : Bool :=
  command.range?.all (validRange sourceBytes)

def structurallyValid (artifact : ModuleArtifact) : Bool :=
  artifact.schema == artifactSchema &&
    artifact.commands.all (validCommand artifact.sourceBytes) &&
    artifact.findings.all (validFinding artifact.sourceBytes)

private def decodeEntry? (entry : Lean.Linter.LintEntry) : Option ModuleArtifact := do
  guard <| entry.linter == artifactLinter
  let json ← Lean.Json.parse entry.message.data |>.toOption
  let artifact ← Lean.fromJson? json |>.toOption
  guard <| structurallyValid artifact
  return artifact

/- Read the formatter result owned by `moduleName` from an already imported module environment.
The caller cannot substitute a side-file path or an independent build identity. -/
def fromEnvironment? (environment : Lean.Environment)
    (moduleName : Lean.Name) : Option ModuleArtifact := do
  let (_, entries) ← Lean.Linter.getAllLints environment |>.find? (fun item => item.1 == moduleName)
  let artifact ← entries.findSome? decodeEntry?
  guard <| artifact.mainModule == moduleName.toString
  return artifact

private def temporaryPath (target : System.FilePath) : IO System.FilePath := do
  let pid ← IO.Process.getPID
  let nonce ← IO.monoNanosNow
  return System.FilePath.mk s!"{target}.tmp-{pid}-{nonce}"

/- Write the declared facet output atomically. This is not a promotion operation: the caller owns
the extraction and the output in one build action. -/
def writeArtifactAtomic (path : System.FilePath) (artifact : ModuleArtifact) : IO Unit := do
  unless structurallyValid artifact do
    throw <| IO.userError "refusing to write an invalid lean-fmt module artifact"
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  let temporary ← temporaryPath path
  try
    IO.FS.writeFile temporary (Lean.toJson artifact).compress
    IO.FS.rename temporary path
  catch error =>
    if ← temporary.pathExists then
      IO.FS.removeFile temporary
    throw error

/- Validate the descriptor returned by the Lake-owning orchestration immediately after a facet
fetch. `Lake.Artifact` itself is publicly constructible and is not authority by type alone; this
primitive must remain behind that orchestration boundary. The content hash is recomputed instead of
trusting Lake's adjacent `.hash` accelerator, then the semantic payload is matched to the caller's
current module and source snapshot. Every integrity or identity failure is an ordinary miss. -/
def readFacet? (facet : Lake.Artifact) (moduleName : Lean.Name)
    (source : String) : IO (Option ModuleArtifact) := do
  try
    let actualHash ← Lake.computeFileHash facet.path (text := true)
    unless actualHash == facet.hash do
      return none
    let contents ← IO.FS.readFile facet.path
    let .ok json := Lean.Json.parse contents
      | return none
    let .ok artifact := Lean.fromJson? json
      | return none
    unless structurallyValid artifact && artifact.mainModule == moduleName.toString &&
        artifact.source == Digest.ofString source && artifact.sourceBytes == source.utf8ByteSize do
      return none
    return some artifact
  catch _ =>
    return none

end LeanFmt.Internal
