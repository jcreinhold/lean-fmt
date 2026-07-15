import Lake.Config.Env
import Lake.Config.InstallPath
import Lake.Load.Workspace
import LeanFmt.Frontend

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

private def requestJson (sysroot : FilePath) (searchPath : Array String)
    (path : FilePath) (source : String) : Json :=
  Json.mkObj
    [ ("schema", Json.str "lean-fmt.frontend.v2")
    , ("file", Json.str path.toString)
    , ("source", Json.str source)
    , ("options", Json.mkObj
        [ ("sysroot", Json.str sysroot.toString)
        , ("search_path", toJson searchPath) ]) ]

private def usage : String :=
  "usage: pure-lean-analyze <lake-workspace-root> <lean-source-file>..."

private def analyzeFile (sysroot : FilePath) (searchPath : Array String)
    (file : FilePath) : IO UInt32 := do
  let source ← IO.FS.readFile file
  let before ← IO.monoNanosNow
  let response ← LeanFmt.Frontend.analyzeCommand (requestJson sysroot searchPath file source).compress
  let elapsedMs := ((← IO.monoNanosNow) - before) / 1000000
  let status := (Json.parse response >>= fun json => json.getObjValAs? String "status").toOption
  IO.println s!"analyze_status={status.getD "invalid-response"} elapsed_ms={elapsedMs} response_bytes={response.utf8ByteSize}"
  return if status == some "ok" then 0 else 1

private def importFile (sysroot : FilePath) (searchPath : Array String)
    (file : FilePath) : IO UInt32 := do
  Lean.initSearchPath sysroot (searchPath.toList.map FilePath.mk)
  let source ← IO.FS.readFile file
  let input := Parser.mkInputContext source file.toString
  let before ← IO.monoNanosNow
  let (header, _, messages) ← Parser.parseHeader input
  if messages.hasErrors then
    IO.println "import_status=header-error"
    return 1
  unsafe Lean.enableInitializersExecution
  let (_, messages) ← Elab.processHeader header {} messages input
  let elapsedMs := ((← IO.monoNanosNow) - before) / 1000000
  IO.println s!"import_status={if messages.hasErrors then "error" else "ok"} elapsed_ms={elapsedMs}"
  return if messages.hasErrors then 1 else 0

private def runParent (rootArg : String) (fileArgs : List String)
    (importOnly : Bool) : IO UInt32 := do
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
      args := #[if importOnly then "--child-import" else "--child", sysroot, file] ++ searchPath
      env := #[("LEAN_NUM_THREADS", "1")]
    }
    IO.print output.stdout
    IO.eprint output.stderr
    if output.exitCode != 0 then
      result := 1
  return result

unsafe def run (args : List String) : IO UInt32 := do
  if let "--child" :: sysroot :: file :: searchPath := args then
    return ← analyzeFile sysroot searchPath.toArray file
  if let "--child-import" :: sysroot :: file :: searchPath := args then
    return ← importFile sysroot searchPath.toArray file
  let (importOnly, args) := match args with
    | "--import-only" :: rest => (true, rest)
    | _ => (false, args)
  let rootArg :: fileArgs := args
    | IO.eprintln usage
      return 2
  if fileArgs.isEmpty then
    IO.eprintln usage
    return 2
  runParent rootArg fileArgs importOnly

end PureLeanAnalyze

public unsafe def main (args : List String) : IO UInt32 := PureLeanAnalyze.run args
