module

import Lean.Linter.PersistentLintLog

open Lean

private structure Request where
  moduleName : Name
  moduleFile : System.FilePath
  output : System.FilePath

private def parseRequest (line : String) : Except String Request :=
  match line.splitOn "\t" with
  | [moduleName, moduleFile, output] =>
    .ok { moduleName := moduleName.toName, moduleFile, output }
  | _ => .error s!"invalid batch manifest row: {line}"

private def formatterPayload? (environment : Environment) (moduleName : Name) : Option String := do
  let (_, entries) ← Linter.getAllLints environment |>.find? (fun item => item.1 == moduleName)
  let entry ← entries.find? (fun entry => entry.linter == `leanFmt.semanticArtifact)
  return entry.message.data

/- This probe generalizes Lean's `withImportModules` reclamation pattern only by supplying the exact
target artifact. The callback returns `Unit`, no imported value escapes, and extension initializers
remain disabled. -/
private unsafe def withExactModule (request : Request)
    (action : Environment → IO Unit) : IO Unit := do
  let (moduleData, region) ← readModuleData request.moduleFile
  let level := if moduleData.isModule then OLeanLevel.exported else .private
  region.free
  let artifacts : NameMap ImportArtifacts :=
    ({} : NameMap ImportArtifacts).insert request.moduleName (.ofArray #[request.moduleFile])
  let environment ← importModules #[{ module := request.moduleName }] {}
    (trustLevel := 1024) (loadExts := false) (level := level) (arts := artifacts)
  try action environment finally environment.freeRegions

private unsafe def extract (request : Request) : IO Unit :=
  withExactModule request fun environment => do
    let some payload := formatterPayload? environment request.moduleName
      | throw <| IO.userError s!"module {request.moduleName} contains no lean-fmt payload"
    if let some parent := request.output.parent then
      IO.FS.createDirAll parent
    IO.FS.writeFile request.output payload

private def residentKiB : IO Nat := do
  let pid ← IO.Process.getPID
  let output ← IO.Process.output { cmd := "ps", args := #["-o", "rss=", "-p", toString pid] }
  if output.exitCode != 0 then
    throw <| IO.userError output.stderr
  let some rss := output.stdout.trimAscii.toNat?
    | throw <| IO.userError s!"invalid ps RSS output: {output.stdout}"
  return rss

public unsafe def main (args : List String) : IO UInt32 := do
  let [manifest] := args
    | IO.eprintln "usage: artifact-batch-probe MANIFEST"
      return 2
  initSearchPath (← findSysroot)
  let rows := (← IO.FS.readFile manifest).splitOn "\n" |>.filter (!·.isEmpty)
  let started ← IO.monoMsNow
  for row in rows, index in [1:rows.length + 1] do
    let request ← match parseRequest row with
      | .ok request => pure request
      | .error message => throw <| IO.userError message
    let itemStarted ← IO.monoMsNow
    extract request
    let itemFinished ← IO.monoMsNow
    IO.println s!"phase.batch_item_{index}_ms={itemFinished - itemStarted}"
    IO.println s!"batch_item_{index}_rss_kib={← residentKiB}"
  let finished ← IO.monoMsNow
  IO.println s!"phase.batch_total_ms={finished - started}"
  return 0
