module

import Lake.Build.Module
import Lake.Build.Run
import Lake.Config.Env
import Lake.Config.InstallPath
import Lake.Load.Workspace

open Lean System

namespace SetupAudit

private def loadTargetWorkspace (root : FilePath) : IO Lake.Workspace := do
  let (elan?, lean?, lake?) ← Lake.findInstall?
  let some lean := lean?
    | throw <| IO.userError "could not locate the active Lean installation"
  let some lake := lake?
    | throw <| IO.userError "could not locate the active Lake installation"
  let lakeEnvResult ← (Lake.Env.compute lake lean elan?).toIO'
  let lakeEnv ← match lakeEnvResult with
    | .ok env => pure env
    | .error message => throw <| IO.userError message
  let config : Lake.LoadConfig := { lakeEnv, wsDir := root }
  let workspace? ← Lake.loadWorkspace config |>.toBaseIO
  workspace?.getDM <| throw <| IO.userError s!"could not load Lake workspace at {root}"

private def readManifest (manifest : FilePath) : IO (Array String) := do
  let contents ← IO.FS.readFile manifest
  return contents.splitOn "\n" |>.foldl (init := #[]) fun paths line =>
    if line.isEmpty then paths else paths.push line

private def usage := "usage: setup-audit PROJECT_ROOT SOURCE_MANIFEST"

private def setupBatchSize := 16

private def setupBatch (workspace : Lake.Workspace) (root : FilePath)
    (sources : Array String) : IO (Array (String × UInt64)) :=
  workspace.runBuild (cfg := { noBuild := true, verbosity := .quiet }) do
    let jobs ← sources.mapM fun (relative : String) => do
      let path := root / (relative : FilePath)
      let setupJob ← Lake.setupServerModule relative path none
      setupJob.mapM (sync := true) fun setup =>
        return (relative, hash (toJson setup).compress)
    return Lake.Job.collectArray jobs "setup audit batch"

private def run (args : List String) : IO UInt32 := do
  let [rootArg, manifestArg] := args
    | IO.eprintln usage
      return 2
  let root : FilePath := rootArg
  let manifest : FilePath := manifestArg
  let workspace ← loadTargetWorkspace root
  let sources ← readManifest manifest
  let started ← IO.monoNanosNow
  let mut succeeded := 0
  let mut offset := 0
  while offset < sources.size do
    let stop := min sources.size (offset + setupBatchSize)
    let batch := sources.extract offset stop
    for (relative, setupHash) in ← setupBatch workspace root batch do
      IO.println s!"source={relative} setup_hash={setupHash}"
      succeeded := succeeded + 1
    offset := stop
  let elapsedMs := ((← IO.monoNanosNow) - started) / 1000000
  IO.println s!"sources={sources.size} setups_ok={succeeded} setups_failed=0"
  IO.println s!"phase.setup_audit_ms={elapsedMs}"
  return 0

end SetupAudit

public def main (args : List String) : IO UInt32 := SetupAudit.run args
