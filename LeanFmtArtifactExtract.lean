module

import all LeanFmt.ArtifactStore

open LeanFmt.Internal

private unsafe def extract (moduleName : Lean.Name) (moduleFile output : System.FilePath) : IO Unit := do
  Lean.enableInitializersExecution
  Lean.initSearchPath (← Lean.findSysroot)
  let (moduleData, _region) ← Lean.readModuleData moduleFile
  let level := if moduleData.isModule then Lean.OLeanLevel.exported else .private
  let artifacts : Lean.NameMap Lean.ImportArtifacts :=
    ({} : Lean.NameMap Lean.ImportArtifacts).insert moduleName (.ofArray #[moduleFile])
  let environment ← Lean.importModules #[{ module := moduleName }] {}
    (trustLevel := 1024) (loadExts := true) (level := level) (arts := artifacts)
  let some artifact := fromEnvironment? environment moduleName
    | throw <| IO.userError s!"module {moduleName} contains no lean-fmt compiler payload"
  writeArtifactAtomic output artifact
  -- `moduleData`, `region`, and the imported environment intentionally remain live until this
  -- short-lived process exits; manually freeing compacted regions would violate Lean's ownership
  -- contract while decoded values still exist.

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | [moduleName, moduleFile, output] =>
    extract moduleName.toName moduleFile output
    return 0
  | _ =>
    IO.eprintln "usage: lean-fmt-artifact-extract MODULE OLEAN OUTPUT"
    return 2
