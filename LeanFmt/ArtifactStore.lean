module

import all LeanFmt.ArtifactModel
import Lean.Linter.PersistentLintLog
import Lake.Build.Common

namespace LeanFmt.Internal

/-- Structural validity, checkable without the source.

This used to also bound every finding's range by the projection's byte count. There are no findings
in an artifact any more, and dropping that check lost nothing: the process that reports a finding now
computes it, from facts `validFor` has already matched to the bytes in hand, so its range fits those
bytes without a separate audit. -/
def structurallyValid (artifact : ModuleArtifact) : Bool :=
  artifact.schema == artifactSchema && artifact.source.structurallyValid

/-- Validity against the file a caller actually read. Normalizing is the caller's only correct move:
no compiler-produced offset or digest indexes the bytes on disk. -/
def ModuleArtifact.validFor (artifact : ModuleArtifact) (moduleName : Lean.Name)
    (raw : String) : Bool :=
  structurallyValid artifact &&
    artifact.source.mainModule == moduleName.toString &&
    artifact.source.validFor raw

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
  guard <| artifact.source.mainModule == moduleName.toString
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
    unless artifact.validFor moduleName source do
      return none
    return some artifact
  catch _ =>
    return none

end LeanFmt.Internal
