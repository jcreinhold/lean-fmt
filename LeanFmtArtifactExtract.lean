module

import all LeanFmt.Analysis

open LeanFmt.Internal

private unsafe def extract (moduleName : Lean.Name) (moduleFile output : System.FilePath) : IO Unit := do
  match ← compilerArtifact? moduleName moduleFile with
  | some artifact => writeArtifactAtomic output artifact
  | none =>
    if let some parent := output.parent then
      IO.FS.createDirAll parent
    IO.FS.writeFile output "null"
  -- Exact per-module facet extraction deliberately uses process exit as its reclamation boundary.
  -- The experimental batch specialization tests `Environment.freeRegions`; production does not
  -- reproduce that unsafe lifetime protocol without a scoped exact-import API in Lean.

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | [moduleName, moduleFile, output] =>
    extract moduleName.toName moduleFile output
    return 0
  | _ =>
    IO.eprintln "usage: lean-fmt-artifact-extract MODULE OLEAN OUTPUT"
    return 2
