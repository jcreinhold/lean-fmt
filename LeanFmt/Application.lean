module

import all LeanFmt.Cache
import Lake.Build.Module
import Lake.Build.Run
import Lake.Config.Env
import Lake.Config.InstallPath
import Lake.Load.Workspace
import all Lean.Shell

open System

namespace LeanFmt.Internal.Application

private inductive ReportFormat where
  | text
  | json

private structure RunRequest where
  root : FilePath
  files : Array FilePath
  format : ReportFormat := .text
  maxMemoryGiB : Nat := 8
  cache : Bool := true

private structure SourceSnapshot where
  module : Lake.Module
  path : FilePath
  relativePath : String
  source : String

private structure FileReport where
  path : String
  status : String
  findings : Array Finding := #[]
  diagnostics : Array String := #[]
  deriving Lean.ToJson

private structure RunReport where
  files : Array FileReport
  findings : Nat
  broken : Nat
  infrastructureFailures : Array String
  deriving Lean.ToJson

private structure ChildOutput where
  exitCode : UInt32
  stdout : String
  stderr : String
  peakAggregateRssKiB : Nat

private def usage : String := "\
usage: lean-fmt check [--root PATH] [--json] [--no-cache] [--max-memory GIB] [FILE...]\n\
       lean-fmt check --help"

private def parseCheckArgs (args : List String) : Except String RunRequest :=
  let rec loop (remaining : List String) (request : RunRequest) :=
    match remaining with
    | [] => .ok request
    | "--root" :: root :: rest => loop rest { request with root }
    | "--json" :: rest => loop rest { request with format := .json }
    | "--no-cache" :: rest => loop rest { request with cache := false }
    | "--max-memory" :: value :: rest =>
      match value.toNat? with
      | some amount => loop rest { request with maxMemoryGiB := amount }
      | none => .error "--max-memory expects a whole number of GiB"
    | "--help" :: _ => .error usage
    | option :: rest =>
      if option.startsWith "-" then .error s!"unknown option: {option}"
      else loop rest { request with files := request.files.push option }
  loop args { root := ".", files := #[] }

private def expectedVersion (pin : String) : String :=
  let version := (pin.splitOn ":").getLast!
  if version.startsWith "v" then (version.drop 1).toString else version

private def targetLeanInstall (root : FilePath) : IO Lake.LeanInstall := do
  let sysroot ← match ← IO.getEnv "LEAN_SYSROOT" with
    | some path => pure (FilePath.mk path)
    | none =>
      let lean := (← IO.getEnv "LEAN").getD "lean"
      if lean.trimAscii.isEmpty then
        throw <| IO.userError "target Lean discovery was disabled by an empty LEAN value"
      let output ← IO.Process.output {
        cmd := lean
        args := #["--print-prefix"]
        cwd := root
      }
      unless output.exitCode == 0 do
        throw <| IO.userError s!"could not resolve the target Lean installation: \
          {output.stderr.trimAscii}"
      pure (FilePath.mk output.stdout.trimAscii.copy)
  let install ← Lake.LeanInstall.get sysroot
  unless install.githash == Lean.githash do
    throw <| IO.userError s!"target Lean revision {install.githash} does not match this \
      lean-fmt build ({Lean.githash}); install lean-fmt for the target toolchain"
  return install

private def loadWorkspace (root : FilePath) : IO Lake.Workspace := do
  let pinPath := root / "lean-toolchain"
  let pin ← IO.FS.readFile pinPath
  let pin := pin.trimAscii.copy
  unless expectedVersion pin == Lean.versionString do
    throw <| IO.userError s!"target toolchain {pin} does not match this lean-fmt build \
      (Lean {Lean.versionString}); install lean-fmt for the target toolchain"
  let lean ← targetLeanInstall root
  let lake := Lake.LakeInstall.ofLean lean
  unless ← lake.lake.pathExists do
    throw <| IO.userError s!"target toolchain has no Lake executable at {lake.lake}"
  let elan? ← Lake.findElanInstall?
  let lakeEnvResult ← (Lake.Env.compute lake lean elan?).toIO'
  let lakeEnv ← match lakeEnvResult with
    | .ok environment => pure environment
    | .error message => throw <| IO.userError message
  let loaded ← Lake.loadWorkspace { lakeEnv, wsDir := root } |>.toBaseIO
  loaded.getDM <| throw <| IO.userError s!"could not load Lake workspace at {root}"

private def artifactFile (mod : Lake.Module) : FilePath :=
  Lean.modToFilePath (mod.pkg.buildDir / "lean-fmt-check-artifacts") mod.name "json"

private def fetchArtifact (application : FilePath)
    (mod : Lake.Module) : Lake.FetchM (Lake.Job Lake.Artifact) := do
  let oleanJob ← mod.olean.fetch
  let applicationJob ← Lake.inputBinFile application
  let dependency := oleanJob.zipWith (fun olean executable => (olean, executable)) applicationJob
  dependency.mapM fun (olean, executable) => do
    Lake.withCurrPackage mod.pkg do
      Lake.buildArtifactUnlessUpToDate (artifactFile mod) (text := true) (ext := "json")
          (restore := true) (platformIndependent := true) do
        Lake.proc {
          cmd := executable.toString
          args := #["__extract-artifact", mod.name.toString, olean.toString,
            (artifactFile mod).toString]
          env := #[
            ⟨"LEAN_PATH", (← Lake.getLeanPath).toString⟩,
            ⟨"LEAN_NUM_THREADS", "1"⟩
          ]
        }

private def moduleLess (left right : Lake.Module) : Bool :=
  left.leanFile.toString < right.leanFile.toString

private def deduplicateModules (modules : Array Lake.Module) : Array Lake.Module :=
  let (_, unique) := modules.foldl (init := (none, #[])) fun (previous, unique) mod =>
    let path := mod.leanFile.toString
    if previous == some path then (previous, unique) else (some path, unique.push mod)
  unique

private def allRootModules (workspace : Lake.Workspace) : IO (Array Lake.Module) := do
  let mut modules := #[]
  for library in workspace.root.leanLibs do
    modules := modules ++ (← library.getModuleArray)
  return deduplicateModules (modules.qsort moduleLess)

private def selectedModules (workspace : Lake.Workspace) (root : FilePath)
    (requested : Array FilePath) : IO (Array Lake.Module) := do
  if requested.isEmpty then
    allRootModules workspace
  else
    let mut modules := #[]
    for requestedPath in requested do
      let path := if requestedPath.isAbsolute then requestedPath else root / requestedPath
      let path ← IO.FS.realPath path
      let some mod := workspace.findModuleBySrc? path
        | throw <| IO.userError s!"selected file is not a buildable Lake module: {path}"
      modules := modules.push mod
    return deduplicateModules (modules.qsort moduleLess)

private def snapshotSources (root : FilePath)
    (modules : Array Lake.Module) : IO (Array SourceSnapshot) := do
  modules.mapM fun mod => do
    let path ← IO.FS.realPath mod.leanFile
    return {
      module := mod
      path
      relativePath := (Lake.relPathFrom root path).toString
      source := ← IO.FS.readFile path
    }

private def trustedArtifact? (workspace : Lake.Workspace) (application : FilePath)
    (snapshot : SourceSnapshot) : IO (Option ModuleArtifact) := do
  if (← IO.getEnv "LEAN_FMT_DISABLE_ARTIFACT") == some "1" then
    return none
  unless ← workspace.checkNoBuild (do snapshot.module.olean.fetch) do
    return none
  try
    let facet ← workspace.runBuild (cfg := { verbosity := .quiet }) do
      fetchArtifact application snapshot.module
    readFacet? facet snapshot.module.name snapshot.source
  catch _ =>
    return none

private def writeSetup (directory : FilePath) (index : Nat)
    (setup : Lean.ModuleSetup) : IO FilePath := do
  let path := directory / s!"{index}.setup.json"
  IO.FS.writeFile path (Lean.toJson setup).compress
  return path

private def residentKiB : IO Nat := do
  let pid ← IO.Process.getPID
  let output ← IO.Process.output {
    cmd := "/bin/ps"
    args := #["-o", "rss=", "-p", toString pid]
  }
  unless output.exitCode == 0 do
    throw <| IO.userError s!"could not sample parent RSS: {output.stderr.trimAscii}"
  let some value := output.stdout.trimAscii.toNat?
    | throw <| IO.userError "could not parse parent RSS"
  return value

private def processGroupRssKiB (processGroup : UInt32) : IO Nat := do
  let output ← IO.Process.output { cmd := "/bin/ps", args := #["-axo", "pgid=,rss="] }
  unless output.exitCode == 0 do
    throw <| IO.userError s!"could not sample child process group RSS: \
      {output.stderr.trimAscii}"
  return output.stdout.splitOn "\n" |>.foldl (init := 0) fun total line =>
    let fields := line.trimAscii.copy.splitOn " " |>.filter (!·.isEmpty)
    match fields with
    | [group, rss] =>
      if group.toNat? == some processGroup.toNat then total + rss.toNat?.getD 0 else total
    | _ => total

private def awaitRead (task : Task (Except IO.Error String)) : IO String := do
  match ← IO.wait task with
  | .ok contents => return contents
  | .error error => throw error

private partial def monitorChild (child : IO.Process.Child {
      stdin := .inherit, stdout := .piped, stderr := .piped })
    (stdoutTask stderrTask : Task (Except IO.Error String))
    (maxBytes peakKiB : Nat) : IO ChildOutput := do
  match ← child.tryWait with
  | some exitCode =>
    return {
      exitCode
      stdout := ← awaitRead stdoutTask
      stderr := ← awaitRead stderrTask
      peakAggregateRssKiB := peakKiB
    }
  | none =>
    let aggregateKiB := (← residentKiB) + (← processGroupRssKiB child.pid)
    let peakKiB := max peakKiB aggregateKiB
    if aggregateKiB * 1024 > maxBytes then
      try child.kill catch _ => pure ()
      discard child.wait
      discard <| awaitRead stdoutTask
      discard <| awaitRead stderrTask
      throw <| IO.userError s!"resource envelope exhausted during exact frontend child \
        ({aggregateKiB} KiB > {maxBytes / 1024} KiB)"
    IO.sleep 50
    monitorChild child stdoutTask stderrTask maxBytes peakKiB

private def runBounded (arguments : IO.Process.SpawnArgs)
    (maxBytes : Nat) : IO ChildOutput := do
  let child ← IO.Process.spawn {
    cmd := arguments.cmd
    args := arguments.args
    cwd := arguments.cwd
    env := arguments.env
    inheritEnv := arguments.inheritEnv
    stdin := .inherit
    stdout := .piped
    stderr := .piped
    setsid := true
  }
  let stdoutTask ← IO.asTask child.stdout.readToEnd
  let stderrTask ← IO.asTask child.stderr.readToEnd
  monitorChild child stdoutTask stderrTask maxBytes 0

private def minimalSetup (snapshot : SourceSnapshot) : Lean.ModuleSetup := {
  name := snapshot.module.name
  package? := snapshot.module.pkg.id?
  isModule := true
  options := snapshot.module.leanOptions
}

private def exactFallback (workspace : Lake.Workspace) (application : FilePath)
    (temporary : FilePath) (index : Nat) (request : RunRequest)
    (snapshot : SourceSnapshot) : IO AnalysisEnvelope := do
  let setupCurrent ← workspace.checkNoBuild (do snapshot.module.setup.fetch)
  let setup ← if setupCurrent then
    workspace.runBuild (cfg := { noBuild := true, verbosity := .quiet }) do
      snapshot.module.setup.fetch
  else
    pure (minimalSetup snapshot)
  let setupPath ← writeSetup temporary index setup
  let sourcePath := temporary / s!"{index}.lean"
  IO.FS.writeFile sourcePath snapshot.source
  let configuredMaxBytes := request.maxMemoryGiB * 1024 * 1024 * 1024
  let maxBytes := ((← IO.getEnv "LEAN_FMT_TEST_MAX_BYTES").bind (·.toNat?))
    |>.getD configuredMaxBytes
  if (← residentKiB) * 1024 >= maxBytes then
    throw <| IO.userError s!"resource envelope exhausted before exact frontend child \
      (limit {maxBytes} bytes)"
  let analyzer := (← IO.getEnv "LEAN_FMT_TEST_ANALYZER").map FilePath.mk
    |>.getD application
  let output ← runBounded {
    cmd := analyzer.toString
    args := #["__analyze-exact", setupPath.toString, sourcePath.toString,
      snapshot.path.toString, toString maxBytes]
    env := workspace.augmentedEnvVars.push ⟨"LEAN_NUM_THREADS", some "1"⟩
  } maxBytes
  unless output.exitCode == 0 do
    throw <| IO.userError s!"exact frontend child failed for {snapshot.relativePath}: \
      {output.stderr.trimAscii}"
  let .ok json := Lean.Json.parse output.stdout
    | throw <| IO.userError s!"exact frontend child returned invalid JSON for \
      {snapshot.relativePath}"
  let .ok envelope := Lean.fromJson? json
    | throw <| IO.userError s!"exact frontend child returned an invalid result for \
      {snapshot.relativePath}"
  return envelope

private def reportFromEnvelope (snapshot : SourceSnapshot)
    (envelope : AnalysisEnvelope) : FileReport :=
  match envelope.artifact? with
  | some artifact => {
      path := snapshot.relativePath
      status := if artifact.findings.isEmpty then "clean" else "findings"
      findings := artifact.findings
    }
  | none => {
      path := snapshot.relativePath
      status := "broken"
      diagnostics := envelope.diagnostics
    }

private def analyzeFile (workspace : Lake.Workspace) (application temporary : FilePath)
    (index : Nat) (request : RunRequest) (cache? : Option ResultCache)
    (snapshot : SourceSnapshot) (cached? : Option AnalysisEnvelope) : IO FileReport := do
  if let some analysis := cached? then
    return reportFromEnvelope snapshot analysis
  let analysis ← do
    if let some artifact ← trustedArtifact? workspace application snapshot then
      pure { artifact? := some artifact }
    else
      exactFallback workspace application temporary index request snapshot
  if let some cache := cache? then
    cache.write snapshot.module snapshot.source analysis
  return reportFromEnvelope snapshot analysis

private def summarize (files : Array FileReport) (failures : Array String := #[]) : RunReport :=
  let findings := files.foldl (fun total file => total + file.findings.size) 0
  let broken := files.foldl (fun total file =>
    if file.status == "broken" then total + 1 else total) 0
  { files, findings, broken, infrastructureFailures := failures }

private def recordPhase (name : String) (started finished : Nat) : IO Unit := do
  if (← IO.getEnv "LEAN_FMT_PROFILE_PHASES") == some "1" then
    IO.eprintln s!"phase.{name}_ms={(finished - started) / 1000000}"

/- Execute one immutable user request. This operation owns workspace discovery, exact module
selection, source snapshots, trusted-artifact validation, fallback, deterministic aggregation, and
resource intent. No caller can sequence or retain those mechanisms independently. -/
private def execute (request : RunRequest) : IO RunReport := do
  if request.maxMemoryGiB == 0 then
    throw <| IO.userError "--max-memory must provide a nonzero operating envelope"
  let root ← IO.FS.realPath request.root
  let workspaceStarted ← IO.monoNanosNow
  let workspace ← loadWorkspace root
  let workspaceFinished ← IO.monoNanosNow
  recordPhase "workspace_load" workspaceStarted workspaceFinished
  let selectionStarted ← IO.monoNanosNow
  let modules ← selectedModules workspace root request.files
  let snapshots ← snapshotSources root modules
  let selectionFinished ← IO.monoNanosNow
  recordPhase "selection_snapshot" selectionStarted selectionFinished
  let application ← IO.appPath
  let epochStarted ← IO.monoNanosNow
  let cache? ← if request.cache then ResultCache.open? workspace application else pure none
  let epochFinished ← IO.monoNanosNow
  recordPhase "cache_epoch" epochStarted epochFinished
  let lookupStarted ← IO.monoNanosNow
  let cached ← match cache? with
    | none => pure (Array.replicate snapshots.size none)
    | some cache =>
      snapshots.mapM fun snapshot => cache.read? snapshot.module snapshot.source
  let lookupFinished ← IO.monoNanosNow
  recordPhase "cache_lookup" lookupStarted lookupFinished
  if cached.all Option.isSome then
    let files := (snapshots.zip cached).filterMap fun
      | (snapshot, some analysis) => some (reportFromEnvelope snapshot analysis)
      | (_, none) => none
    return summarize files
  let temporary ← IO.FS.createTempDir
  try
    let mut files := #[]
    let mut failures := #[]
    for (snapshot, cached?) in snapshots.zip cached, index in [0:snapshots.size] do
      try
        files := files.push
          (← analyzeFile workspace application temporary index request cache? snapshot cached?)
      catch error =>
        let message := toString error
        failures := failures.push s!"{snapshot.relativePath}: {message}"
        files := files.push {
          path := snapshot.relativePath
          status := "infrastructure-failure"
          diagnostics := #[message]
        }
    return summarize files failures
  finally
    IO.FS.removeDirAll temporary

private def renderText (report : RunReport) : IO Unit := do
  for file in report.files do
    for finding in file.findings do
      IO.println s!"{file.path}:{finding.range.start}-{finding.range.stop}: \
        {finding.code} {finding.message}"
    for diagnostic in file.diagnostics do
      IO.println s!"{file.path}: {file.status}: {diagnostic}"
  IO.println s!"checked={report.files.size} findings={report.findings} broken={report.broken} \
    infrastructure_failures={report.infrastructureFailures.size}"

private def render (format : ReportFormat) (report : RunReport) : IO Unit :=
  match format with
  | .text => renderText report
  | .json => IO.println (Lean.toJson report).compress

private def exitCode (report : RunReport) : UInt32 :=
  if !report.infrastructureFailures.isEmpty then 2
  else if report.findings > 0 || report.broken > 0 then 1
  else 0

private unsafe def runAnalyzeChild (args : List String) : IO UInt32 := do
  let [setupPath, snapshotPath, displayPath, maxBytes] := args
    | return 2
  let some maxBytes := maxBytes.toNat?
    | return 2
  Lean.Internal.setMaxMemory maxBytes.toUSize
  let .ok setupJson := Lean.Json.parse (← IO.FS.readFile setupPath)
    | throw <| IO.userError "invalid ModuleSetup JSON"
  let .ok setup := Lean.fromJson? setupJson
    | throw <| IO.userError "invalid ModuleSetup payload"
  let source ← IO.FS.readFile snapshotPath
  let envelope ← analyzeExact setup source displayPath
  IO.println (Lean.toJson envelope).compress
  return 0

private unsafe def runExtractChild (args : List String) : IO UInt32 := do
  let [moduleName, moduleFile, output] := args
    | return 2
  match ← compilerArtifact? moduleName.toName moduleFile with
  | some artifact => writeArtifactAtomic output artifact
  | none =>
    if let some parent := (output : FilePath).parent then
      IO.FS.createDirAll parent
    IO.FS.writeFile output "null"
  return 0

private unsafe def measureCacheEpoch (args : List String) : IO UInt32 := do
  let [root] := args
    | return 2
  let root ← IO.FS.realPath root
  let workspaceStarted ← IO.monoNanosNow
  let workspace ← loadWorkspace root
  let workspaceFinished ← IO.monoNanosNow
  let epochStarted ← IO.monoNanosNow
  let cache? ← ResultCache.open? workspace (← IO.appPath)
  let epochFinished ← IO.monoNanosNow
  IO.println s!"phase.workspace_load_ms={(workspaceFinished - workspaceStarted) / 1000000}"
  IO.println s!"phase.cache_epoch_ms={(epochFinished - epochStarted) / 1000000}"
  IO.println s!"cache_enabled={cache?.isSome}"
  return if cache?.isSome then 0 else 1

public unsafe def runCli (args : List String) : IO UInt32 := do
  let args := match args with | "--" :: rest => rest | _ => args
  match args with
  | "__analyze-exact" :: rest => runAnalyzeChild rest
  | "__extract-artifact" :: rest => runExtractChild rest
  | "__measure-cache-epoch" :: rest => measureCacheEpoch rest
  | "check" :: "--help" :: _ => IO.println usage; return 0
  | "check" :: rest =>
    let request ← match parseCheckArgs rest with
      | .ok request => pure request
      | .error message => IO.eprintln message; return 2
    try
      let report ← execute request
      render request.format report
      return exitCode report
    catch error =>
      IO.eprintln s!"lean-fmt: {error}"
      return 2
  | _ =>
    IO.eprintln usage
    return 2

end LeanFmt.Internal.Application
