module

import Lake.Config.Env
import Lake.Config.InstallPath
import Lake.Load.Workspace
import Lean.Elab.Frontend

open Lean System

namespace PureLeanAnalyze

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

private def usage : String :=
  "usage: pure-lean-analyze --import-only <lake-workspace-root> <lean-source-file>..."

private def importFile (sysroot : FilePath) (searchPath : Array String)
    (file : FilePath) : IO UInt32 := do
  Lean.initSearchPath sysroot (searchPath.toList.map FilePath.mk)
  let source ← IO.FS.readFile file
  let input := Parser.mkInputContext source file.toString
  let parseStarted ← IO.monoNanosNow
  let (header, _, messages) ← Parser.parseHeader input
  let parseMs := ((← IO.monoNanosNow) - parseStarted) / 1000000
  if messages.hasErrors then
    IO.println "import_status=header-error"
    return 1
  let header : Elab.HeaderSyntax := header
  let level := if header.isModule then OLeanLevel.exported else OLeanLevel.private
  let imports := header.imports
  unsafe Lean.enableInitializersExecution
  let (loadMs, finalizeMs, env) ← Lean.withImporting do
    let loadStarted ← IO.monoNanosNow
    let (_, importState) ← importModulesCore (globalLevel := level) imports |>.run
    let loadMs := ((← IO.monoNanosNow) - loadStarted) / 1000000
    let finalizeStarted ← IO.monoNanosNow
    let env ← finalizeImport importState imports {} 0
      (leakEnv := false) (loadExts := true) (level := level)
    let finalizeMs := ((← IO.monoNanosNow) - finalizeStarted) / 1000000
    return (loadMs, finalizeMs, env)
  IO.println s!"import_status=ok parse_ms={parseMs} load_ms={loadMs} \
    finalize_ms={finalizeMs} modules={env.header.modules.size}"
  return 0

private def runParent (rootArg : String) (fileArgs : List String) : IO UInt32 := do
  let root : FilePath := rootArg
  let workspace ← loadTargetWorkspace root
  let appPath ← IO.appPath
  let sysroot := workspace.lakeEnv.lean.sysroot.toString
  let searchPath := workspace.leanPath.map FilePath.toString |>.toArray
  let mut result := 0
  for file in fileArgs do
    IO.println s!"source={file}"
    (← IO.getStdout).flush
    let output ← IO.Process.output {
      cmd := appPath.toString
      args := #["--child-import", sysroot, file] ++ searchPath
      env := #[("LEAN_NUM_THREADS", "1")]
    }
    IO.print output.stdout
    IO.eprint output.stderr
    if output.exitCode != 0 then
      result := 1
  return result

private unsafe def run (args : List String) : IO UInt32 := do
  if let "--child-import" :: sysroot :: file :: searchPath := args then
    return ← importFile sysroot searchPath.toArray file
  let args := match args with
    | "--import-only" :: rest => rest
    | _ => args
  let rootArg :: fileArgs := args
    | IO.eprintln usage
      return 2
  if fileArgs.isEmpty then
    IO.eprintln usage
    return 2
  runParent rootArg fileArgs

end PureLeanAnalyze

public unsafe def main (args : List String) : IO UInt32 := PureLeanAnalyze.run args
