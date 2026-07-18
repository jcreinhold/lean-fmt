module

import all LeanFmt.Config
import all LeanFmt.Digest
import Lake.Build.Module
import all Lake.Build.Run
import Lake.Config.Env
import Lake.Config.InstallPath
import all Lake.DSL
import all Lake.Load.Lean.Elab
import all Lake.Load.Workspace

open System

namespace LeanFmt.Internal.Project

structure SourceTarget where
  private mk ::
  module? : Option Lake.Module
  path : FilePath
  relativePath : String
  source : String

structure Snapshot where
  private mk ::
  root : FilePath
  workspace : Lake.Workspace
  targets : Array SourceTarget
  workspaceLoadNanos : Nat
  selectionNanos : Nat

inductive ModuleEvidence where
  | current
  | needsFrontend
  deriving BEq

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

def loadWorkspace (root : FilePath) : IO Lake.Workspace := do
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

private def relativeLess (left right : SourceTarget) : Bool :=
  left.relativePath < right.relativePath

private def deduplicate (targets : Array SourceTarget) : Array SourceTarget :=
  let (_, unique) := targets.foldl (init := (none, #[])) fun (previous, unique) target =>
    if previous == some target.relativePath then (previous, unique)
    else (some target.relativePath, unique.push target)
  unique

private def insideRoot (root path : FilePath) : Bool :=
  path == root || path.toString.startsWith
    (root.toString ++ FilePath.pathSeparator.toString)

private def snapshotTarget (workspace : Lake.Workspace) (root path : FilePath) : IO SourceTarget := do
  let path ← IO.FS.realPath path
  unless insideRoot root path do
    throw <| IO.userError s!"selected file is outside the project root: {path}"
  unless path.extension == some "lean" do
    throw <| IO.userError s!"selected file is not a Lean source: {path}"
  return {
    module? := workspace.findModuleBySrc? path
    path
    relativePath := (Lake.relPathFrom root path).toString
    source := ← IO.FS.readFile path
  }

private def discoverPaths (root : FilePath) : IO (Array FilePath) := do
  let paths ← root.walkDir fun path => pure <| path.fileName != some ".lake"
  return paths.filter (·.extension == some "lean")

/- Load executable Lake configuration, select every requested source exactly once, and snapshot all
bytes before analysis. Module/standalone classification is hidden in `SourceTarget`. -/
def load (requestedRoot : FilePath) (config : FormatterConfig)
    (requested : Array FilePath) : IO Snapshot := do
  let root ← IO.FS.realPath requestedRoot
  let workspaceStarted ← IO.monoNanosNow
  let workspace ← loadWorkspace root
  let workspaceFinished ← IO.monoNanosNow
  let paths ← if requested.isEmpty then
    pure <| (← discoverPaths root).filter fun path =>
      config.includesPath (Lake.relPathFrom root path).toString
  else
    requested.mapM fun path =>
      IO.FS.realPath (if path.isAbsolute then path else root / path)
  let targets ← paths.mapM (snapshotTarget workspace root)
  let selectionFinished ← IO.monoNanosNow
  return {
    root
    workspace
    targets := deduplicate (targets.qsort relativeLess)
    workspaceLoadNanos := workspaceFinished - workspaceStarted
    selectionNanos := selectionFinished - workspaceFinished
  }

def loadAll (requestedRoot : FilePath) : IO Snapshot := do
  let root ← IO.FS.realPath requestedRoot
  let workspaceStarted ← IO.monoNanosNow
  let workspace ← loadWorkspace root
  let workspaceFinished ← IO.monoNanosNow
  let targets ← (← discoverPaths root).mapM (snapshotTarget workspace root)
  let selectionFinished ← IO.monoNanosNow
  return {
    root
    workspace
    targets := deduplicate (targets.qsort relativeLess)
    workspaceLoadNanos := workspaceFinished - workspaceStarted
    selectionNanos := selectionFinished - workspaceFinished
  }

/- Resolve one already-selected source by filesystem identity. Path normalization and root
containment stay below the service boundary; callers receive the canonical immutable target or a
single ordinary miss. -/
def Snapshot.findTarget? (snapshot : Snapshot) (requested : FilePath) : IO (Option SourceTarget) := do
  if requested.isAbsolute then
    return none
  try
    let path ← IO.FS.realPath (snapshot.root / requested)
    unless insideRoot snapshot.root path do
      return none
    return snapshot.targets.find? (·.path == path)
  catch _ =>
    return none

def SourceTarget.withSource (target : SourceTarget) (source : String) : SourceTarget :=
  { target with source }

/- Run one shared Lake no-build graph and recover one status per module. Lake's public runner only
returns aggregate success; the exact-toolchain `import all` boundary lets this private capability
await the typed jobs without parsing monitor output or exposing a temporal lifecycle to callers. -/
private def batchModuleStatuses (workspace : Lake.Workspace)
    (modules : Array Lake.Module) : IO (Array Bool) := do
  let registeredJobs ← Lake.mkJobQueue
  let context ← Lake.mkBuildContext' workspace { noBuild := true } registeredJobs
  let computation : Lake.Job (Lake.Job (Array Bool)) ← Lake.Workspace.startBuild context do
    let jobs ← modules.mapM fun mod => do
      let job ← mod.olean.fetch
      return job.mapResult fun
        | .ok _ state => .ok true state
        | .error _ state => .ok false state
    return Lake.Job.collectArray jobs "lean-fmt module evidence"
  let statusesJob ← match ← computation.wait with
    | .ok job _ => pure job
    | .error _ _ => throw <| IO.userError "could not construct module evidence"
  match ← statusesJob.wait with
  | .ok statuses _ => return statuses
  | .error _ _ => throw <| IO.userError "could not collect module evidence"

/- For each name in `names` that resolves to a workspace module, the set of module names it
transitively imports, fetched from one shared no-build Lake graph — never one build context per file.
This is the graph fact FMT006 (redundant import) consumes; a `RuleImpl` cannot fetch it
(`Rules.lean:17-19`), so it is produced here and threaded into the finding set by the application.

The `startBuild`/`wait` pattern matches `batchModuleStatuses`: it is *not* `runBuild`, so an out-of-date
target cannot trigger the `noBuild` process-exit (`finalizeBuild` → `IO.Process.exit`, which only fires
under `runBuild`). A fetch that errors under `noBuild` — the closure would need a build to resolve —
maps to the empty closure, a graceful miss: FMT006 then never reports a redundancy *through* that
import. That can only lose a report (report-only anyway), never fabricate one. A name absent from the
workspace is simply omitted. -/
def importClosures (workspace : Lake.Workspace) (names : Array Lean.Name) :
    IO (Array (Lean.Name × Array Lean.Name)) := do
  let resolved := names.filterMap fun name =>
    (workspace.findModule? name).map fun mod => (name, mod)
  if resolved.isEmpty then return #[]
  let registeredJobs ← Lake.mkJobQueue
  let context ← Lake.mkBuildContext' workspace { noBuild := true } registeredJobs
  let computation : Lake.Job (Lake.Job (Array (Array Lean.Name))) ←
    Lake.Workspace.startBuild context do
      let jobs ← resolved.mapM fun (_, mod) => do
        let job ← mod.transImports.fetch
        return job.mapResult fun
          | .ok mods state => .ok (mods.map (·.name)) state
          | .error _ state => .ok #[] state
      return Lake.Job.collectArray jobs "lean-fmt import closures"
  let closuresJob ← match ← computation.wait with
    | .ok job _ => pure job
    | .error _ _ => throw <| IO.userError "could not construct import closures"
  let closures ← match ← closuresJob.wait with
    | .ok closures _ => pure closures
    | .error _ _ => throw <| IO.userError "could not collect import closures"
  return (resolved.zip closures).map fun ((name, _), closure) => (name, closure)

def moduleEvidence (snapshot : Snapshot) : IO (Array ModuleEvidence) := do
  if (← IO.getEnv "LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE") == some "1" then
    return Array.replicate snapshot.targets.size .needsFrontend
  let modules := snapshot.targets.filterMap (·.module?)
  let statuses ← batchModuleStatuses snapshot.workspace modules
  let mut moduleIndex := 0
  let mut evidence := #[]
  for target in snapshot.targets do
    match target.module? with
    | none =>
      if target.path.fileName == some "lakefile.lean" then
        if target.path == snapshot.root / "lakefile.lean" then
          evidence := evidence.push .current
        else
          let parent := target.path.parent.getD snapshot.root
          let loaded ← Lake.loadWorkspaceRoot {
            lakeEnv := snapshot.workspace.lakeEnv
            wsDir := parent
          } |>.toBaseIO
          evidence := evidence.push (if loaded.isSome then .current else .needsFrontend)
      else
        evidence := evidence.push .needsFrontend
    | some _ =>
      let current := statuses[moduleIndex]!
      moduleIndex := moduleIndex + 1
      evidence := evidence.push (if current then .current else .needsFrontend)
  return evidence

private def setupJob (target : SourceTarget) : Lake.FetchM (Lake.Job Lean.ModuleSetup) := do
  let header ← Lean.parseImports' target.source target.relativePath
  Lake.setupServerModule target.relativePath target.path (some header)

def exactSetup (snapshot : Snapshot) (target : SourceTarget) : IO Lean.ModuleSetup := do
  let current ← snapshot.workspace.checkNoBuild (setupJob target)
  if current then
    snapshot.workspace.runBuild (cfg := { noBuild := true, verbosity := .quiet })
      (setupJob target)
  else
    snapshot.workspace.runBuild (cfg := { verbosity := .quiet }) (setupJob target)

private def moduleConfiguration (mod : Lake.Module) : String :=
  String.intercalate "\u0000" [
    mod.name.toString,
    toString mod.pkg.id?,
    (Lean.toJson mod.leanOptions).compress,
    String.intercalate "\u0000" mod.leanArgs.toList,
    String.intercalate "\u0000" mod.weakLeanArgs.toList,
    String.intercalate "\u0000" (mod.dynlibs.map toString).toList,
    String.intercalate "\u0000" (mod.plugins.map toString).toList,
    toString mod.allowImportAll,
    toString mod.platformIndependent
  ]

/- Identify the evaluated root-package policy used by Lake for sources outside a declared library.
Header bytes and import order remain in the source identity; ordered search roots and artifact
contents remain in the environment epoch. This value covers the remaining setup decisions without
running `setupServerModule` on an all-hit cache path. -/
def externalConfigurationIdentity (workspace : Lake.Workspace) : Digest :=
  let root := workspace.root
  Digest.ofString <| String.intercalate "\u0000" [
    toString root.id?,
    (Lean.toJson workspace.serverOptions).compress,
    toString root.precompileModules,
    String.intercalate "\u0000" (root.dynlibs.map toString).toList,
    String.intercalate "\u0000" (root.plugins.map toString).toList,
    String.intercalate "\u0000" (root.externLibs.map (·.name.toString)).toList,
    String.intercalate "\u0000" (root.extraDepTargets.map toString).toList
  ]

def configurationIdentity (_snapshot : Snapshot) (target : SourceTarget) : IO Digest :=
  match target.module? with
  | some mod => return Digest.ofString (moduleConfiguration mod)
  | none => do
    if target.path.fileName == some "lakefile.lean" then
      return Digest.ofString <| String.intercalate "\u0000"
        ["lakefile", target.relativePath, Lean.versionString, Lean.githash]
    return Digest.ofString <| String.intercalate "\u0000"
      ["external-source", target.relativePath]

end LeanFmt.Internal.Project
