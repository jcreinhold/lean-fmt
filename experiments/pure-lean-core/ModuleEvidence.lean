module

import Lake.Build.Module
import all Lake.Build.Run
import Lake.Config.Env
import Lake.Config.InstallPath
import Lake.Load.Workspace

open Lean System

namespace ModuleEvidence

private def loadTargetWorkspace (root : FilePath) : IO Lake.Workspace := do
  let elan? ← Lake.findElanInstall?
  let some lean ← Lake.findLeanInstall?
    | throw <| IO.userError "could not locate the active Lean installation"
  let lake := Lake.LakeInstall.ofLean lean
  let lakeEnvResult ← (Lake.Env.compute lake lean elan?).toIO'
  let lakeEnv ← match lakeEnvResult with
    | .ok env => pure env
    | .error message => throw <| IO.userError message
  let config : Lake.LoadConfig := { lakeEnv, wsDir := root }
  let workspace? ← Lake.loadWorkspace config |>.toBaseIO
  workspace?.getDM <| throw <| IO.userError s!"could not load Lake workspace at {root}"

private def readManifest (manifest : FilePath) : IO (Array String) := do
  let contents ← if manifest.toString == "-" then
    (← IO.getStdin).readToEnd
  else
    IO.FS.readFile manifest
  return contents.splitOn "\n" |>.foldl (init := #[]) fun paths line =>
    if line.isEmpty then paths else paths.push line

private def usage := "usage: module-evidence PROJECT_ROOT SOURCE_MANIFEST"

private def batchStatuses (workspace : Lake.Workspace)
    (modules : Array Lake.Module) : IO (Array Bool) := do
  let registeredJobs ← Lake.mkJobQueue
  let context ← Lake.mkBuildContext' workspace { noBuild := true } registeredJobs
  let computation : Lake.Job (Lake.Job (Array Bool)) ← Lake.Workspace.startBuild context do
    let jobs ← modules.mapM fun mod => do
      let job ← mod.olean.fetch
      return job.mapResult fun
        | .ok _ state => .ok true state
        | .error _ state => .ok false state
    return Lake.Job.collectArray jobs "module evidence"
  let statusesJob ← match ← computation.wait with
    | .ok job _ => pure job
    | .error _ _ => throw <| IO.userError "could not construct the module evidence job"
  let statuses ← match ← statusesJob.wait with
    | .ok statuses _ => pure statuses
    | .error _ _ => throw <| IO.userError "module evidence collection failed"
  return statuses

private def run (args : List String) : IO UInt32 := do
  let [rootArg, manifestArg] := args
    | IO.eprintln usage
      return 2
  let root ← IO.FS.realPath rootArg
  let workspaceStarted ← IO.monoNanosNow
  let workspace ← loadTargetWorkspace root
  let workspaceFinished ← IO.monoNanosNow
  let sources ← readManifest manifestArg
  let mut modules := #[]
  let mut standalone := #[]
  for relative in sources do
    let path ← IO.FS.realPath (root / (relative : FilePath))
    match workspace.findModuleBySrc? path with
    | some mod => modules := modules.push mod
    | none => standalone := standalone.push relative
  let validationStarted ← IO.monoNanosNow
  let statuses ← batchStatuses workspace modules
  let validationFinished ← IO.monoNanosNow
  IO.println s!"sources={sources.size} modules={modules.size} standalone={standalone.size}"
  for path in standalone do
    IO.println s!"standalone={path}"
  let mut stale := 0
  for (mod, current) in modules.zip statuses do
    unless current do
      stale := stale + 1
      IO.println s!"stale={Lake.relPathFrom root mod.leanFile}"
  IO.println s!"current={modules.size - stale} stale={stale}"
  IO.println s!"phase.workspace_load_ms={(workspaceFinished - workspaceStarted) / 1000000}"
  IO.println s!"phase.module_evidence_ms={(validationFinished - validationStarted) / 1000000}"
  return 0

end ModuleEvidence

public def main (args : List String) : IO UInt32 := ModuleEvidence.run args
