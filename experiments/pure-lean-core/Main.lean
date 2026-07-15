module

import Lake.Config.Env
import Lake.Config.InstallPath
import Lake.Load.Workspace
import Lean.Elab.Frontend

open Lean System

namespace PureLeanCore

private partial def discoverLeanFiles (root : FilePath) : IO (Array FilePath) := do
  let paths ← root.walkDir fun path => pure <| path.fileName != some ".lake"
  return paths.filter fun path => path.extension == some "lean"

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
  let config : Lake.LoadConfig := {lakeEnv, wsDir := root}
  let workspace? ← Lake.loadWorkspace config |>.toBaseIO
  workspace?.getDM <| throw <| IO.userError s!"could not load Lake workspace at {root}"

private unsafe def frontendFile (workspace : Lake.Workspace) (path : FilePath) : IO Bool := do
  let targetSearchPath := workspace.leanPath ++ [workspace.lakeEnv.lean.leanLibDir]
  Lean.searchPathRef.set targetSearchPath
  Lean.enableInitializersExecution
  let source ← IO.FS.readFile path
  let before := (← IO.monoNanosNow)
  let env? ← Lean.Elab.runFrontend source {} path.toString `_pureLeanCoreProbe
  let after := (← IO.monoNanosNow)
  let elapsedMs := (after - before) / 1000000
  match env? with
  | some env =>
      let localDeclarations := env.constants.map₂.foldl (fun count _ _ => count + 1) 0
      IO.println s!"frontend=ok imported_modules={env.header.moduleNames.size} \
        local_declarations={localDeclarations} elapsed_ms={elapsedMs}"
      return true
  | none =>
      IO.println s!"frontend=errors elapsed_ms={elapsedMs}"
      return false

private def usage : String :=
  "usage: pure-lean-core <lake-workspace-root> <lean-source-file>..."

private def checkTargetToolchain (root : FilePath) : IO String := do
  let path := root / "lean-toolchain"
  let pin := (← IO.FS.readFile path).trimAscii.copy
  unless pin.endsWith Lean.versionString do
    throw <| IO.userError s!"target pin {pin} does not match running Lean {Lean.versionString}"
  return pin

unsafe def run (args : List String) : IO UInt32 := do
  let rootArg :: fileArgs := args
    | IO.eprintln usage
      return 2
  if fileArgs.isEmpty then
    IO.eprintln usage
    return 2
  let root : FilePath := rootArg
  let targetToolchain ← checkTargetToolchain root
  let workspace ← loadTargetWorkspace root
  let files ← discoverLeanFiles root
  IO.println s!"lean={Lean.versionString}"
  IO.println s!"target_toolchain={targetToolchain}"
  IO.println s!"workspace={workspace.root.dir} packages={workspace.packages.size}"
  let targetSearchPath := workspace.leanPath ++ [workspace.lakeEnv.lean.leanLibDir]
  IO.println s!"lean_path_entries={targetSearchPath.length} discovered_lean_files={files.size}"
  let mut allSucceeded := true
  for fileArg in fileArgs do
    let file : FilePath := fileArg
    IO.println s!"source={file}"
    (← IO.getStdout).flush
    unless ← frontendFile workspace file do
      allSucceeded := false
    (← IO.getStdout).flush
  return if allSucceeded then 0 else 1

end PureLeanCore

public unsafe def main (args : List String) : IO UInt32 := PureLeanCore.run args
