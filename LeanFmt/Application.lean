module

import all LeanFmt.Cache
import all LeanFmt.Config
import all LeanFmt.Edit
import all LeanFmt.Project
import all LeanFmt.Semantic
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

private abbrev SourceSnapshot := Project.SourceTarget

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

private structure FacetDescriptor where
  hash : String
  ext : String
  path : String
  deriving Lean.FromJson

private def decodeFacetDescriptor? (encoded : String) : Option Lake.Artifact := do
  let json ← Lean.Json.parse encoded |>.toOption
  let descriptor : FacetDescriptor ← Lean.fromJson? json |>.toOption
  let hash ← Lake.Hash.ofString? descriptor.hash
  guard <| !descriptor.path.isEmpty
  return {
    descr := Lake.artifactWithExt hash descriptor.ext
    path := FilePath.mk descriptor.path
    mtime := 0
  }

private def withoutProcessOutput (action : IO α) : IO α := do
  let buffer ← IO.mkRef { : IO.FS.Stream.Buffer }
  let stdout ← IO.setStdout (.ofBuffer buffer)
  let stderr ← IO.setStderr (.ofBuffer buffer)
  try action finally
    discard <| IO.setStdout stdout
    discard <| IO.setStderr stderr

/- Fetch the target workspace's registered formatter facet jobs together under Lake's no-build
policy. Returned descriptors never escape this operation: every content hash is recomputed and
every payload is matched to its immutable module/source snapshot. A missing, stale, corrupt, or
failing facet is an ordered miss, never an extractor launch or a partial batch failure. -/
def officialArtifacts (workspace : Lake.Workspace)
    (snapshots : Array SourceSnapshot) : IO (Array (Option ModuleArtifact)) := do
  if (← IO.getEnv "LEAN_FMT_DISABLE_ARTIFACT") == some "1" then
    return Array.replicate snapshots.size none
  let facetName := `module.leanFmtArtifact
  let some config := workspace.findModuleFacetConfig? facetName
    | return Array.replicate snapshots.size none
  try
    withoutProcessOutput do
      let encoded ← workspace.runBuild (cfg := { noBuild := true, verbosity := .quiet }) do
        let jobs ← snapshots.mapM fun snapshot => do
          match snapshot.module? with
          | none => return Lake.Job.pure none
          | some mod =>
            let job ← config.run (β := Lake.FacetOut facetName) mod
            return job.mapResult fun
              | .ok value state => .ok (some (config.format .json value)) state
              | .error _ state => .ok none state
        return Lake.Job.collectArray jobs "lean-fmt official artifacts"
      (snapshots.zip encoded).mapM fun (snapshot, encoded?) => do
        let some mod := snapshot.module?
          | return none
        let some encoded := encoded?
          | return none
        let some facet := decodeFacetDescriptor? encoded
          | return none
        readFacet? facet mod.name snapshot.source
  catch _ =>
    return Array.replicate snapshots.size none

private def writeSetup (directory : FilePath) (index : Nat)
    (setup : Lean.ModuleSetup) : IO FilePath := do
  let path := directory / s!"{index}.setup.json"
  IO.FS.writeFile path (Lean.toJson setup).compress
  return path

private def diagnosticSetup (snapshot : SourceSnapshot) : Lean.ModuleSetup :=
  match snapshot.module? with
  | some mod => {
      name := mod.name
      package? := mod.pkg.id?
      isModule := true
      options := mod.leanOptions
    }
  | none => { name := `_unknown }

private def exactSetupResult (project : Project.Snapshot)
    (snapshot : SourceSnapshot) : IO (Except IO.Error Lean.ModuleSetup) :=
  try
    return Except.ok (← Project.exactSetup project snapshot)
  catch error =>
    return Except.error error

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

private def exactFallback (project : Project.Snapshot) (application : FilePath)
    (temporary : FilePath) (index : Nat) (request : RunRequest)
    (snapshot : SourceSnapshot) (validator := false) : IO AnalysisEnvelope := do
  let setupResult ← exactSetupResult project snapshot
  let setup := match setupResult with
    | .ok setup => setup
    | .error _ => diagnosticSetup snapshot
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
    env := project.workspace.augmentedEnvVars.push ⟨"LEAN_NUM_THREADS", some "1"⟩
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
  if let .error setupError := setupResult then
    if envelope.artifact?.isSome then
      throw <| IO.userError s!"could not establish the exact Lake setup for \
        {snapshot.relativePath}: {setupError}"
  return envelope

private def canonicalAnalysis (snapshot : SourceSnapshot)
    (analysis : AnalysisEnvelope) : IO SemanticAnalysis :=
  match SemanticAnalysis.ofEnvelope? snapshot.source analysis with
  | some semantic => pure semantic
  | none => throw <| IO.userError s!"invalid exact analysis for {snapshot.relativePath}"

private def analyzeFile (project : Project.Snapshot) (application temporary : FilePath)
    (index : Nat) (request : RunRequest)
    (plan : RulePlan) (evidence : Project.ModuleEvidence)
    (snapshot : SourceSnapshot) (cached? : Option SemanticAnalysis)
    (officialArtifact? : Option ModuleArtifact) : IO SemanticAnalysis := do
  if let some analysis := cached? then
    return analysis
  let analysis ← if !plan.requiresSyntax && evidence == .current then
    pure <| SemanticAnalysis.success snapshot.source (runRules snapshot.source true)
  else if let some artifact := officialArtifact? then
    canonicalAnalysis snapshot { artifact? := some artifact }
  else
    canonicalAnalysis snapshot (← exactFallback project application temporary index request snapshot)
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
    (validation : SemanticAnalysis) : Option FileReport :=
  match validation.result? with
  | some _ => none
  | none => some (baseReport snapshot "rejected" findings validation.diagnostics)

private def projectFile (project : Project.Snapshot) (application temporary : FilePath)
    (index : Nat) (request : RunRequest) (plan : RulePlan) (snapshot : SourceSnapshot)
    (analysis : SemanticAnalysis) : IO FileReport := do
  let some result := analysis.result?
    | return baseReport snapshot "broken" #[] analysis.diagnostics
  let findings := plan.findings snapshot.relativePath result.findings
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
    let validation ← canonicalAnalysis candidate <| ← exactFallback project application temporary
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

private def recordDuration (name : String) (nanos : Nat) : IO Unit := do
  if (← IO.getEnv "LEAN_FMT_PROFILE_PHASES") == some "1" then
    IO.eprintln s!"phase.{name}_ms={nanos / 1000000}"

/- Execute one immutable user request. This operation owns workspace discovery, exact module
selection, source snapshots, trusted-artifact validation, fallback, deterministic aggregation, and
resource intent. No caller can sequence or retain those mechanisms independently. -/
def execute (request : RunRequest) : IO RunReport := do
  if request.maxMemoryGiB == 0 then
    throw <| IO.userError "--max-memory must provide a nonzero operating envelope"
  let root ← IO.FS.realPath request.root
  let configPath? := request.configPath?.map fun path =>
    if path.isAbsolute then path else root / path
  let config ← FormatterConfig.load root configPath?
  let plan ← match config.rulePlan request.select request.ignore with
    | .ok plan => pure plan
    | .error message => throw <| IO.userError message
  let project ← Project.load root config request.files
  recordDuration "workspace_load" project.workspaceLoadNanos
  recordDuration "selection_snapshot" project.selectionNanos
  let snapshots := project.targets
  let application ← IO.appPath
  let epochStarted ← IO.monoNanosNow
  let cache? ← if request.cache then
    ResultCache.open? project.workspace application request.validationLevel
  else
    pure none
  let epochFinished ← IO.monoNanosNow
  recordPhase "cache_epoch" epochStarted epochFinished
  let lookupStarted ← IO.monoNanosNow
  let cached ← match cache? with
    | none => pure (Array.replicate snapshots.size none)
    | some cache => cache.readAll project snapshots
  let lookupFinished ← IO.monoNanosNow
  recordPhase "cache_lookup" lookupStarted lookupFinished
  if cached.all Option.isSome && request.mode != .fix then
    let mut files := #[]
    for (snapshot, cached?) in snapshots.zip cached, index in [0:snapshots.size] do
      if let some analysis := cached? then
        files := files.push (← projectFile project application "." index request plan
          snapshot analysis)
    return summarize request.mode files
  let evidenceStarted ← IO.monoNanosNow
  let evidence ← Project.moduleEvidence project
  let evidenceFinished ← IO.monoNanosNow
  recordPhase "module_evidence" evidenceStarted evidenceFinished
  let artifactStarted ← IO.monoNanosNow
  let artifacts ← if plan.requiresSyntax then
    officialArtifacts project.workspace snapshots
  else
    pure (Array.replicate snapshots.size none)
  let artifactFinished ← IO.monoNanosNow
  recordPhase "official_artifacts" artifactStarted artifactFinished
  let temporary ← IO.FS.createTempDir
  try
    let mut files := #[]
    let mut failures := #[]
    let mut analyses := #[]
    for (((snapshot, cached?), sourceEvidence), artifact?) in
        ((snapshots.zip cached).zip evidence).zip artifacts,
        index in [0:snapshots.size] do
      try
        let analysis ← analyzeFile project application temporary index request plan sourceEvidence
          snapshot cached? artifact?
        analyses := analyses.push (some analysis)
        files := files.push
          (← projectFile project application temporary index request plan snapshot analysis)
      catch error =>
        analyses := analyses.push none
        let message := toString error
        failures := failures.push s!"{snapshot.relativePath}: {message}"
        files := files.push {
          path := snapshot.relativePath
          status := "infrastructure-failure"
          diagnostics := #[message]
        }
    if let some cache := cache? then
      cache.writeAll project snapshots analyses
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
  let workspace ← Project.loadWorkspace root
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
  let some mod := snapshot.module?
    | return "unbuilt"
  unless ← withoutProcessOutput <| workspace.checkNoBuild (do mod.olean.fetch) do
    return "unbuilt"
  let output ← runBounded {
    cmd := application.toString
    args := #["__inspect-artifact", mod.name.toString,
      mod.oleanFile.toString, snapshot.path.toString, toString maxBytes]
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
  let project ← Project.loadAll root
  let application ← IO.appPath
  let maxBytes := request.maxMemoryGiB * 1024 * 1024 * 1024
  let mut statuses := #[]
  for snapshot in project.targets do
    let some mod := snapshot.module?
      | continue
    let status ← inspectCompilerArtifact project.workspace application maxBytes snapshot
    statuses := statuses.push {
      path := snapshot.relativePath
      module := mod.name.toString
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
