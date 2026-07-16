module

import all LeanFmt.Cache
import all LeanFmt.Config
import all LeanFmt.Edit
import Lake.Build.Module
import Lake.Build.Run
import Lake.Config.Env
import Lake.Config.InstallPath
import Lake.Load.Workspace
import all Lean.Shell

open System

namespace LeanFmt.Internal.Application

inductive RunMode where
  | check
  | format
  | diff
  | fix
  deriving BEq

def RunMode.toString : RunMode → String
  | .check => "check"
  | .format => "format"
  | .diff => "diff"
  | .fix => "fix"

structure RunRequest where
  mode : RunMode
  root : FilePath
  files : Array FilePath
  maxMemoryGiB : Nat := 8
  cache : Bool := true
  configPath? : Option FilePath := none
  select : Array String := #[]
  ignore : Array String := #[]
  validationLevel : ValidationLevel := .syntax

private structure SourceSnapshot where
  module : Lake.Module
  path : FilePath
  relativePath : String
  source : String

structure FileReport where
  path : String
  status : String
  findings : Array Finding := #[]
  diagnostics : Array String := #[]
  formatted : Option String := none
  diff : Option String := none
  written : Bool := false
  deriving Lean.ToJson

structure RunReport where
  mode : String
  files : Array FileReport
  findings : Nat
  changed : Nat
  written : Nat
  broken : Nat
  rejected : Nat
  infrastructureFailures : Array String
  deriving Lean.ToJson

private structure ChildOutput where
  exitCode : UInt32
  stdout : String
  stderr : String
  peakAggregateRssKiB : Nat

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
    (config : FormatterConfig) (requested : Array FilePath) : IO (Array Lake.Module) := do
  if requested.isEmpty then
    return (← allRootModules workspace).filter fun mod =>
      config.includesPath (Lake.relPathFrom root mod.leanFile).toString
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

private def withoutProcessOutput (action : IO α) : IO α := do
  let buffer ← IO.mkRef { : IO.FS.Stream.Buffer }
  let stdout ← IO.setStdout (.ofBuffer buffer)
  let stderr ← IO.setStderr (.ofBuffer buffer)
  try action finally
    discard <| IO.setStdout stdout
    discard <| IO.setStderr stderr

private def trustedArtifact? (workspace : Lake.Workspace) (application : FilePath)
    (snapshot : SourceSnapshot) : IO (Option ModuleArtifact) := do
  if (← IO.getEnv "LEAN_FMT_DISABLE_ARTIFACT") == some "1" then
    return none
  try
    withoutProcessOutput do
      unless ← workspace.checkNoBuild (do snapshot.module.olean.fetch) do
        return none
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
    (snapshot : SourceSnapshot) (validator := false) : IO AnalysisEnvelope := do
  let setupCurrent ← withoutProcessOutput <| workspace.checkNoBuild (do snapshot.module.setup.fetch)
  let setup? ← if setupCurrent then
    some <$> workspace.runBuild (cfg := { noBuild := true, verbosity := .quiet }) do
      snapshot.module.setup.fetch
  else
    try
      some <$> withoutProcessOutput (workspace.runBuild (cfg := { verbosity := .quiet }) do
        snapshot.module.setup.fetch)
    catch _ => pure none
  let setup := setup?.getD (minimalSetup snapshot)
  let setupPath ← writeSetup temporary index setup
  let sourcePath := temporary / s!"{index}.lean"
  IO.FS.writeFile sourcePath snapshot.source
  let configuredMaxBytes := request.maxMemoryGiB * 1024 * 1024 * 1024
  let maxBytes := ((← IO.getEnv "LEAN_FMT_TEST_MAX_BYTES").bind (·.toNat?))
    |>.getD configuredMaxBytes
  if (← residentKiB) * 1024 >= maxBytes then
    throw <| IO.userError s!"resource envelope exhausted before exact frontend child \
      (limit {maxBytes} bytes)"
  let overrideName := if validator then "LEAN_FMT_TEST_VALIDATOR" else "LEAN_FMT_TEST_ANALYZER"
  let analyzer := (← IO.getEnv overrideName).map FilePath.mk |>.getD application
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
  if setup?.isNone && envelope.artifact?.isSome then
    throw <| IO.userError s!"could not establish the exact Lake module setup for \
      {snapshot.relativePath}; refusing a successful result from diagnostic-only header fallback"
  return envelope

private def canonicalAnalysis (snapshot : SourceSnapshot)
    (analysis : AnalysisEnvelope) : AnalysisEnvelope :=
  match analysis.artifact? with
  | none => analysis
  | some artifact => {
      artifact? := some {
        artifact with
        trailingWhitespace := true
        findings := runRules snapshot.source true
      }
    }

private def analyzeFile (workspace : Lake.Workspace) (application temporary : FilePath)
    (index : Nat) (request : RunRequest) (cache? : Option ResultCache)
    (snapshot : SourceSnapshot) (cached? : Option AnalysisEnvelope) : IO AnalysisEnvelope := do
  if let some analysis := cached? then
    return analysis
  let analysis ← do
    if let some artifact ← trustedArtifact? workspace application snapshot then
      pure { artifact? := some artifact }
    else
      exactFallback workspace application temporary index request snapshot
  let analysis := canonicalAnalysis snapshot analysis
  if let some cache := cache? then
    cache.write snapshot.module snapshot.source analysis
  return analysis

private structure DiffSource where
  lines : List String
  finalNewline : Bool

private def diffSource (source : String) : DiffSource :=
  if source.isEmpty then
    { lines := [], finalNewline := false }
  else
    let finalNewline := source.endsWith "\n"
    let pieces := source.splitOn "\n"
    { lines := if finalNewline then pieces.dropLast else pieces, finalNewline }

private def prefixedLines (marker : String) (source : DiffSource) : String :=
  let body := source.lines.foldl (fun output line => output ++ marker ++ line ++ "\n") ""
  if !source.finalNewline && !source.lines.isEmpty then
    body ++ "\\ No newline at end of file\n"
  else
    body

private def unifiedDiff (path before after : String) : String :=
  let old := diffSource before
  let new := diffSource after
  let oldStart := if old.lines.isEmpty then 0 else 1
  let newStart := if new.lines.isEmpty then 0 else 1
  s!"--- a/{path}\n+++ b/{path}\n@@ -{oldStart},{old.lines.length} \
    +{newStart},{new.lines.length} @@\n{prefixedLines "-" old}{prefixedLines "+" new}"

private def octalDigit? : Char → Option Nat
  | '0' => some 0
  | '1' => some 1
  | '2' => some 2
  | '3' => some 3
  | '4' => some 4
  | '5' => some 5
  | '6' => some 6
  | '7' => some 7
  | _ => none

private def parseOctal? (value : String) : Option Nat := do
  guard !value.isEmpty
  value.toList.foldlM (init := 0) fun total character => do
    let digit ← octalDigit? character
    return total * 8 + digit

private def accessMode (path : FilePath) : IO Nat := do
  let candidates : Array (String × Array String) := #[
    ("/usr/bin/stat", #["-f", "%Lp", path.toString]),
    ("stat", #["-c", "%a", path.toString])
  ]
  for (command, arguments) in candidates do
    try
      let output ← IO.Process.output { cmd := command, args := arguments }
      if output.exitCode == 0 then
        if let some mode := parseOctal? output.stdout.trimAscii.copy then
          return mode
    catch _ => pure ()
  throw <| IO.userError s!"could not read source permissions: {path}"

private def publicationTemp (path : FilePath) : IO FilePath := do
  let pid ← IO.Process.getPID
  let nonce ← IO.monoNanosNow
  return FilePath.mk s!"{path}.lean-fmt-tmp-{pid}-{nonce}"

private def runBeforeWriteHook (path : FilePath) : IO Unit := do
  if let some command ← IO.getEnv "LEAN_FMT_TEST_BEFORE_WRITE" then
    let output ← IO.Process.output { cmd := command, args := #[path.toString] }
    unless output.exitCode == 0 do
      throw <| IO.userError "test before-write hook failed"

private def publishAtomic (path : FilePath) (original output : String) : IO (Except String Unit) := do
  let mode ← accessMode path
  let temporary ← publicationTemp path
  try
    IO.FS.writeFile temporary output
    IO.Prim.setAccessRights temporary mode.toUInt32
    runBeforeWriteHook path
    unless (← IO.FS.readFile path) == original do
      IO.FS.removeFile temporary
      return .error "source changed after analysis; refusing stale write"
    IO.FS.rename temporary path
    return .ok ()
  catch error =>
    if ← temporary.pathExists then
      IO.FS.removeFile temporary
    throw error

private def baseReport (snapshot : SourceSnapshot) (status : String)
    (findings : Array Finding := #[]) (diagnostics : Array String := #[]) : FileReport :=
  { path := snapshot.relativePath, status, findings, diagnostics }

private def validationReport (snapshot : SourceSnapshot) (findings : Array Finding)
    (validation : AnalysisEnvelope) : Option FileReport :=
  match validation.artifact? with
  | some _ => none
  | none => some (baseReport snapshot "rejected" findings validation.diagnostics)

private def projectFile (workspace : Lake.Workspace) (application temporary : FilePath)
    (index : Nat) (request : RunRequest) (plan : RulePlan) (snapshot : SourceSnapshot)
    (analysis : AnalysisEnvelope) : IO FileReport := do
  let some artifact := analysis.artifact?
    | return baseReport snapshot "broken" #[] analysis.diagnostics
  let findings := plan.findings snapshot.relativePath artifact.findings
  let patch ← match preparePatch snapshot.source findings with
    | .ok patch => pure patch
    | .error error =>
      return baseReport snapshot "rejected" findings #[toString error]
  match request.mode with
  | .check =>
    return baseReport snapshot (if findings.isEmpty then "clean" else "findings") findings
  | .format =>
    if patch.changed then
      return { (baseReport snapshot "would-format" findings) with
        formatted := some patch.formatted }
    return baseReport snapshot "clean" findings
  | .diff =>
    if patch.changed then
      return { (baseReport snapshot "would-diff" findings) with
        diff := some (unifiedDiff snapshot.relativePath snapshot.source patch.formatted) }
    return baseReport snapshot "clean" findings
  | .fix =>
    unless patch.changed do
      return baseReport snapshot "clean" findings
    let candidate := { snapshot with source := patch.formatted }
    let validation ← exactFallback workspace application temporary
      (index + 1000000) request candidate (validator := true)
    if let some report := validationReport snapshot findings validation then
      return report
    match ← publishAtomic snapshot.path snapshot.source patch.formatted with
    | .error message => return baseReport snapshot "rejected" findings #[message]
    | .ok _ =>
      return { (baseReport snapshot "fixed" findings) with
        formatted := some patch.formatted
        written := true }

private def summarize (mode : RunMode) (files : Array FileReport)
    (failures : Array String := #[]) : RunReport :=
  let findings := files.foldl (fun total file => total + file.findings.size) 0
  let changed := files.foldl (fun total file =>
    if file.status == "findings" || file.status == "would-format" ||
        file.status == "would-diff" || file.status == "fixed" then total + 1 else total) 0
  let written := files.foldl (fun total file => if file.written then total + 1 else total) 0
  let broken := files.foldl (fun total file =>
    if file.status == "broken" then total + 1 else total) 0
  let rejected := files.foldl (fun total file =>
    if file.status == "rejected" then total + 1 else total) 0
  { mode := mode.toString, files, findings, changed, written, broken, rejected,
    infrastructureFailures := failures }

private def recordPhase (name : String) (started finished : Nat) : IO Unit := do
  if (← IO.getEnv "LEAN_FMT_PROFILE_PHASES") == some "1" then
    IO.eprintln s!"phase.{name}_ms={(finished - started) / 1000000}"

/- Execute one immutable user request. This operation owns workspace discovery, exact module
selection, source snapshots, trusted-artifact validation, fallback, deterministic aggregation, and
resource intent. No caller can sequence or retain those mechanisms independently. -/
def execute (request : RunRequest) : IO RunReport := do
  if request.maxMemoryGiB == 0 then
    throw <| IO.userError "--max-memory must provide a nonzero operating envelope"
  let root ← IO.FS.realPath request.root
  let workspaceStarted ← IO.monoNanosNow
  let workspace ← loadWorkspace root
  let workspaceFinished ← IO.monoNanosNow
  recordPhase "workspace_load" workspaceStarted workspaceFinished
  let selectionStarted ← IO.monoNanosNow
  let configPath? := request.configPath?.map fun path =>
    if path.isAbsolute then path else root / path
  let config ← FormatterConfig.load root configPath?
  let plan ← match config.rulePlan request.select request.ignore with
    | .ok plan => pure plan
    | .error message => throw <| IO.userError message
  let modules ← selectedModules workspace root config request.files
  let snapshots ← snapshotSources root modules
  let selectionFinished ← IO.monoNanosNow
  recordPhase "selection_snapshot" selectionStarted selectionFinished
  let application ← IO.appPath
  let epochStarted ← IO.monoNanosNow
  let cache? ← if request.cache then
    ResultCache.open? workspace application request.validationLevel
  else
    pure none
  let epochFinished ← IO.monoNanosNow
  recordPhase "cache_epoch" epochStarted epochFinished
  let lookupStarted ← IO.monoNanosNow
  let cached ← match cache? with
    | none => pure (Array.replicate snapshots.size none)
    | some cache =>
      snapshots.mapM fun snapshot => cache.read? snapshot.module snapshot.source
  let lookupFinished ← IO.monoNanosNow
  recordPhase "cache_lookup" lookupStarted lookupFinished
  if cached.all Option.isSome && request.mode != .fix then
    let mut files := #[]
    for (snapshot, cached?) in snapshots.zip cached, index in [0:snapshots.size] do
      if let some analysis := cached? then
        files := files.push (← projectFile workspace application "." index request plan
          snapshot analysis)
    return summarize request.mode files
  let temporary ← IO.FS.createTempDir
  try
    let mut files := #[]
    let mut failures := #[]
    for (snapshot, cached?) in snapshots.zip cached, index in [0:snapshots.size] do
      try
        files := files.push
          (← projectFile workspace application temporary index request plan snapshot
            (← analyzeFile workspace application temporary index request cache? snapshot cached?))
      catch error =>
        let message := toString error
        failures := failures.push s!"{snapshot.relativePath}: {message}"
        files := files.push {
          path := snapshot.relativePath
          status := "infrastructure-failure"
          diagnostics := #[message]
        }
    return summarize request.mode files failures
  finally
    IO.FS.removeDirAll temporary

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

private unsafe def runInspectArtifactChild (args : List String) : IO UInt32 := do
  let [moduleName, moduleFile, sourcePath, maxBytes] := args
    | return 2
  let some maxBytes := maxBytes.toNat?
    | return 2
  Lean.Internal.setMaxMemory maxBytes.toUSize
  let source ← IO.FS.readFile sourcePath
  match ← compilerArtifact? moduleName.toName moduleFile with
  | some artifact =>
    if structurallyValid artifact && artifact.mainModule == moduleName &&
        artifact.source == Digest.ofString source && artifact.sourceBytes == source.utf8ByteSize then
      IO.println "ready"
    else
      IO.println "missing"
  | none => IO.println "missing"
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

structure CleanReport where
  root : String
  removed : Bool
  deriving Lean.ToJson

def clean (requestedRoot : FilePath) : IO CleanReport := do
  let root ← IO.FS.realPath requestedRoot
  let cache := root / ".lean-fmt-cache"
  let removed ← cache.pathExists
  if removed then IO.FS.removeDirAll cache
  return { root := root.toString, removed }

structure CompilerStatusRequest where
  root : FilePath := "."
  maxMemoryGiB : Nat := 8

structure CompilerSetupReport where
  schema : String
  package : String
  plugin : String
  facet : String
  toolchain : String
  guidance : Array String
  deriving Lean.ToJson

def compilerSetupReport : CompilerSetupReport := {
  schema := "lean-fmt.compiler-setup.v1"
  package := "lean-fmt"
  plugin := "LeanFmtCompilerPlugin:shared"
  facet := "leanFmtArtifact"
  toolchain := s!"Lean {Lean.versionString} ({Lean.githash})"
  guidance := #[
    "add lean-fmt as a Lake dependency using the source and revision you trust",
    "for dependency alias ALIAS, add `@ALIAS/LeanFmtCompilerPlugin:shared to each formatted lean_lib plugins array",
    "build +MODULE:leanFmtArtifact when an extracted module artifact is required"
  ]
}

structure CompilerModuleStatus where
  path : String
  module : String
  status : String
  deriving Lean.ToJson

structure CompilerStatusReport where
  root : String
  toolchain : String
  modules : Array CompilerModuleStatus
  ready : Nat
  missing : Nat
  unbuilt : Nat
  deriving Lean.ToJson

private def inspectCompilerArtifact (workspace : Lake.Workspace) (application : FilePath)
    (maxBytes : Nat) (snapshot : SourceSnapshot) : IO String := do
  unless ← withoutProcessOutput <| workspace.checkNoBuild (do snapshot.module.olean.fetch) do
    return "unbuilt"
  let output ← runBounded {
    cmd := application.toString
    args := #["__inspect-artifact", snapshot.module.name.toString,
      snapshot.module.oleanFile.toString, snapshot.path.toString, toString maxBytes]
    env := workspace.augmentedEnvVars.push ⟨"LEAN_NUM_THREADS", some "1"⟩
  } maxBytes
  unless output.exitCode == 0 do
    throw <| IO.userError s!"compiler status child failed for {snapshot.relativePath}: \
      {output.stderr.trimAscii}"
  let status := output.stdout.trimAscii.copy
  unless status == "ready" || status == "missing" do
    throw <| IO.userError s!"compiler status child returned invalid output for \
      {snapshot.relativePath}"
  return status

def compilerStatus (request : CompilerStatusRequest) : IO CompilerStatusReport := do
  unless request.maxMemoryGiB > 0 do
    throw <| IO.userError "--max-memory must provide a nonzero operating envelope"
  let root ← IO.FS.realPath request.root
  let workspace ← loadWorkspace root
  let modules ← allRootModules workspace
  let snapshots ← snapshotSources root modules
  let application ← IO.appPath
  let maxBytes := request.maxMemoryGiB * 1024 * 1024 * 1024
  let mut statuses := #[]
  for snapshot in snapshots do
    let status ← inspectCompilerArtifact workspace application maxBytes snapshot
    statuses := statuses.push {
      path := snapshot.relativePath
      module := snapshot.module.name.toString
      status
    }
  let ready := statuses.foldl (fun total item => if item.status == "ready" then total + 1 else total) 0
  let missing := statuses.foldl (fun total item => if item.status == "missing" then total + 1 else total) 0
  let unbuilt := statuses.foldl (fun total item => if item.status == "unbuilt" then total + 1 else total) 0
  return {
    root := root.toString
    toolchain := s!"Lean {Lean.versionString} ({Lean.githash})"
    modules := statuses
    ready
    missing
    unbuilt
  }

/-- Dispatch only the private subprocess/profiling protocol. Ordinary product commands return
`none` and cannot observe setup paths, module artifacts, or process limits. -/
unsafe def runInternal? (args : List String) : IO (Option UInt32) :=
  match args with
  | "__analyze-exact" :: rest => some <$> runAnalyzeChild rest
  | "__extract-artifact" :: rest => some <$> runExtractChild rest
  | "__inspect-artifact" :: rest => some <$> runInspectArtifactChild rest
  | "__measure-cache-epoch" :: rest => some <$> measureCacheEpoch rest
  | _ => pure none

end LeanFmt.Internal.Application
