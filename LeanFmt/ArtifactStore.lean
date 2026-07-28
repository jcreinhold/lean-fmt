/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.ArtifactModel

import Lake.Build.Common
import Lean.Linter.PersistentLintLog

/-! Where a module artifact comes from, and how it is proved to be about the bytes in hand.

Three routes reach one type. `fromEnvironment?` reads the records the compiler plugin wrote into an
imported module's `.olean`; `readFacet?` reads the Lake facet's sidecar; `writeArtifactAtomic`
publishes one. None is trusted by provenance: `validFor` re-derives the module name, the byte count,
and the digest from the caller's own file, and materializes the projection against it.

A path, a filesystem timestamp, or a `Lake.Artifact` descriptor is not evidence. The content is. -/

namespace LeanFmt.Internal

/-- Structural validity, checkable without the source.

This used to also bound every finding's range by the projection's byte count. Artifacts hold no
findings any more, and dropping that check lost nothing: the process that reports a finding now
computes it from facts `validFor` has already matched to the bytes in hand, so its range fits those
bytes without a separate audit. -/
def structurallyValid (artifact : ModuleArtifact) : Bool :=
  artifact.schema == artifactSchema &&
    artifact.syntaxData.structurallyValid artifact.normalizedBytes

/-- Validity against the file a caller actually read. Normalizing is the caller's only correct
move: no compiler-produced offset or digest indexes the bytes on disk. -/
def ModuleArtifact.validFor (artifact : ModuleArtifact) (moduleName : Lean.Name)
    (raw : String) : Bool :=
  let normalized := (LosslessSource.normalize raw).1
  structurallyValid artifact &&
    artifact.mainModule == moduleName.toString &&
    artifact.normalizedBytes == normalized.utf8ByteSize &&
    artifact.normalizedDigest == Digest.ofString normalized &&
    (artifact.materialize raw).isOk

private def decodeEntry? (entry : Lean.Linter.LintEntry) : Option CommandArtifactRecord := do
  guard <| entry.linter == commandArtifactLinter
  let json ← Lean.Json.parse entry.message.data |>.toOption
  let record ← Lean.fromJson? json |>.toOption
  guard record.structurallyValid
  return record

/- Read the formatter result owned by `moduleName` from an already imported module environment.
The caller cannot substitute a side-file path or an independent build identity. -/
def fromEnvironment? (environment : Lean.Environment)
    (moduleName : Lean.Name) : Option ModuleArtifact := do
  let (_, entries) ← Lean.Linter.getAllLints environment |>.find? (fun item => item.1 == moduleName)
  let records := entries.filterMap decodeEntry?
  let first ← records[0]?
  guard <| first.mainModule == moduleName.toString
  guard <| records.all fun record =>
    record.mainModule == first.mainModule &&
      record.normalizedBytes == first.normalizedBytes &&
      record.normalizedDigest == first.normalizedDigest
  let syntaxData ← ModuleSyntax.ofRecords records |>.toOption
  let artifact : ModuleArtifact := {
    schema := artifactSchema
    mainModule := first.mainModule
    normalizedBytes := first.normalizedBytes
    normalizedDigest := first.normalizedDigest
    syntaxData
  }
  guard <| structurallyValid artifact
  return artifact

private def temporaryPath (target : System.FilePath) : IO System.FilePath := do
  let pid ← IO.Process.getPID
  let nonce ← IO.monoNanosNow
  return System.FilePath.mk s!"{target}.tmp-{pid}-{nonce}"

/- Write the declared facet output atomically. Not a promotion operation: the caller owns the
extraction and the output in one build action. -/
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

private def headerBoundaryValid (artifact : ModuleArtifact) (source : String) : IO Bool := do
  let .ok materialized := artifact.materialize source | return false
  let input := Lean.Parser.mkInputContext source "<lean-fmt-artifact>"
  let (_, state, messages) ← Lean.Parser.parseHeader input
  return !messages.hasErrors && state.pos.byteIdx == materialized.source.headerStop

/- Validate the descriptor returned by the Lake-owning orchestration immediately after a facet
fetch. `Lake.Artifact` is publicly constructible and not authority by type alone; this primitive must
stay behind that orchestration boundary. The content hash is recomputed rather than trusting Lake's
adjacent `.hash` accelerator, then the payload is matched to the caller's current module and source
snapshot. Every integrity or identity failure is an ordinary miss. -/
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
    unless ← headerBoundaryValid artifact source do
      return none
    return some artifact
  catch _ =>
    return none

end LeanFmt.Internal
