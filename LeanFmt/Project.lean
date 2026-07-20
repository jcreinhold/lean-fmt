module

import all LeanFmt.Config
import all LeanFmt.Digest
import all LeanFmt.Discovery
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
  /-- The **effective** configuration for this file: the closest recognized config at or above its
  directory, with its `extend` chain already composed (`ruff-13` `notes/01-discovery.md` §5). Carried
  per target rather than per run because that is what "for each file, the closest recognized config
  applies" means — two files in one run can legitimately disagree about `line-width` or `[lint]`. -/
  config : FormatterConfig
  /-- The directory whose config governs this file, root-relative. Two targets sharing a key share a
  configuration, which is what lets the caller resolve one `RulePlan` per distinct config instead of
  one per file. -/
  configKey : String

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

/-- Whether a root-relative path lies inside Lake's build directory.

Gate 1 of the selection table (`ruff-13` `notes/01-discovery.md` §11), and an **absolute** floor: no
configuration key, no `--config`, no explicit path, and no `force-exclude` setting can lift it. `.lake`
holds Lake's build outputs and vendored dependency sources; writing there corrupts a build the user did
not ask us to touch. -/
private def insideLakeDirectory (relativePath : String) : Bool :=
  relativePath == ".lake" || relativePath.startsWith ".lake/" ||
    relativePath.startsWith ".lake\\"

private def snapshotTarget (workspace : Lake.Workspace) (discovery : Discovery.Discovery)
    (root path : FilePath) : IO SourceTarget := do
  let path ← IO.FS.realPath path
  unless insideRoot root path do
    throw <| IO.userError s!"selected file is outside the project root: {path}"
  unless path.extension == some "lean" do
    throw <| IO.userError s!"selected file is not a Lean source: {path}"
  -- The floor runs here, beside the containment and extension checks, rather than only in
  -- `discoverPaths`: both path forms reach this operation, and until `ruff-13` only the discovery form
  -- was filtered — so `format .lake/packages/dep/Dep.lean` wrote a dependency's source
  -- (`ruff-13-config-discovery/evidence/01-discovery-baseline.md` §3).
  if insideLakeDirectory (Lake.relPathFrom root path).toString then
    throw <| IO.userError s!"selected file is inside the Lake build directory: {path}"
  let relativePath := (Lake.relPathFrom root path).toString
  return {
    module? := workspace.findModuleBySrc? path
    path
    relativePath
    source := ← IO.FS.readFile path
    config := discovery.configFor relativePath
    configKey := discovery.configKeyFor relativePath
  }

/-- Resolve `.` and `..` without touching the filesystem.

`FilePath.normalize` only canonicalizes separators (`Init/System/FilePath.lean:83-89`), and `realPath`
is unavailable to us here by construction: an unsaved buffer's path need not exist. So the traversal is
done lexically over `components`. A `..` that would escape an absolute root is dropped rather than
allowed to climb past it, which keeps `insideRoot` below meaningful on a path like `<root>/../etc`. -/
private def resolveLexically (path : FilePath) : FilePath :=
  let leadingSlash := path.toString.startsWith FilePath.pathSeparator.toString
  let resolved := path.components.foldl (init := ([] : List String)) fun acc component =>
    if component == "" || component == "." then acc
    else if component == ".." then acc.dropLast
    else acc ++ [component]
  let joined := String.intercalate FilePath.pathSeparator.toString resolved
  FilePath.mk (if leadingSlash then FilePath.pathSeparator.toString ++ joined else joined)

/-- One **unsaved** buffer as a target: bytes and an identity, with no filesystem read for content.

`ruff-14` RSF-IMPL, `notes/01-stream-range.md` §2. This is the one place the stdin surface cannot reuse
`snapshotTarget`, which calls `realPath` and `readFile` — an editor formatting a buffer that has never
been saved has a path with nothing behind it. Every *gate* `snapshotTarget` applies still applies here,
in the same order and with the same messages, and each names `argument`, the string the caller wrote,
as `CLAUDE.md` requires of path-taking surface.

The `.lake` floor is gate 1 and is not liftable by this path any more than by an explicit file argument
— that was `ruff-13`'s closed write-safety defect, and arriving through a pipe does not reopen it. The
stdin path never publishes, so this is defence in depth rather than the only guard; it is here because
a floor that some entry points skip is not a floor.

`module?` is resolved from the *real* path when the file happens to exist, so a saved-but-modified
buffer keeps the module identity its on-disk twin has and gets the same exact Lake setup. A path with
nothing behind it resolves to `none` and takes the standalone route `diagnosticSetup` already serves. -/
def unsavedTarget (workspace : Lake.Workspace) (discovery : Discovery.Discovery)
    (root : FilePath) (argument : String) (source : String) : IO SourceTarget := do
  let written := FilePath.mk argument
  let candidate := resolveLexically (if written.isAbsolute then written else root / written)
  unless insideRoot root candidate do
    throw <| IO.userError s!"selected file is outside the project root: {argument}"
  unless candidate.extension == some "lean" do
    throw <| IO.userError s!"selected file is not a Lean source: {argument}"
  let relativePath := (Lake.relPathFrom root candidate).toString
  if insideLakeDirectory relativePath then
    throw <| IO.userError s!"selected file is inside the Lake build directory: {argument}"
  let path ← if ← candidate.pathExists then IO.FS.realPath candidate else pure candidate
  return {
    module? := workspace.findModuleBySrc? path
    path
    relativePath
    source
    config := discovery.configFor relativePath
    configKey := discovery.configKeyFor relativePath
  }

/- Load executable Lake configuration, select every requested source exactly once, and snapshot all
bytes before analysis. Module/standalone classification is hidden in `SourceTarget`.

Selection is now driven by one `Discovery` walk rather than a walk of its own plus a root-only config
(`ruff-13` `notes/01-discovery.md` §4.2, §11). With no requested files the selected set is exactly
what discovery kept: the floor, the ignore sources, and each file's *own* effective `include`/`exclude`.

An explicitly named file skips gates 2-4 unless its effective configuration sets `force-exclude`, and
never consults `include` even then — `include` answers "when I say nothing, format these", and naming
a path is saying something (§11). Gate 1 is not skippable and lives in `snapshotTarget`, so it covers
both path forms. -/
def load (requestedRoot : FilePath) (discovery : Discovery.Discovery)
    (requested : Array FilePath) : IO Snapshot := do
  let root ← IO.FS.realPath requestedRoot
  let workspaceStarted ← IO.monoNanosNow
  let workspace ← loadWorkspace root
  let workspaceFinished ← IO.monoNanosNow
  let paths ← if requested.isEmpty then
    discovery.selectedSources.mapM fun relative => IO.FS.realPath (root / FilePath.mk relative)
  else
    requested.mapM fun path => do
      -- Resolve against the root, but report a missing file in the caller's own terms. `realPath` on a
      -- path that does not exist throws `noFileOrDirectory` naming its partially-resolved buffer, which
      -- absolutizes the leading component and mangles the rest — unreadable when a whole argument list
      -- was passed as one path (an unquoted shell variable under a non-splitting shell). Name what the
      -- caller wrote, consistent with the outside-root / not-a-source siblings and `Config` above.
      let candidate := if path.isAbsolute then path else root / path
      unless ← candidate.pathExists do
        throw <| IO.userError s!"selected file does not exist: {path}"
      IO.FS.realPath candidate
  let targets ← paths.mapM (snapshotTarget workspace discovery root)
  -- `force-exclude` is evaluated after snapshotting because it reads the file's *own* effective
  -- configuration, which is a per-file fact. A path discovery dropped is absent from `sources`, so
  -- reusing that set is exactly the gate-2 answer without a second matcher.
  let targets ← if requested.isEmpty then pure targets else targets.filterM fun target => do
    unless target.config.forceExclude do return true
    if !discovery.sources.contains target.relativePath then return false
    return discovery.gateFor target.relativePath != .configExclude
  let selectionFinished ← IO.monoNanosNow
  return {
    root
    workspace
    targets := deduplicate (targets.qsort relativeLess)
    workspaceLoadNanos := workspaceFinished - workspaceStarted
    selectionNanos := selectionFinished - workspaceFinished
  }

/-- The Lake workspace alone, selecting nothing.

`ruff-14` RSF-IMPL. A stdin request formats exactly the bytes it was handed, so it must not pay to
select the project: `load` snapshots every discovered source, which is the right cost for a batch run
over a tree and the wrong cost for one buffer an editor is waiting on. `ExactRun` reads only
`workspace` and `root` from a `Snapshot` — `targets` is never consulted by `envelope`/`exactSetup` —
so an empty selection is a complete capability here rather than a stub.

The service takes the other trade deliberately (`Service.lean`: `Project.load root discovery #[]`,
once per session, because it answers many requests and wants `findTarget?`). A one-shot CLI invocation
has no session to amortize against. -/
def loadWorkspaceOnly (requestedRoot : FilePath) : IO Snapshot := do
  let root ← IO.FS.realPath requestedRoot
  let workspaceStarted ← IO.monoNanosNow
  let workspace ← loadWorkspace root
  let workspaceFinished ← IO.monoNanosNow
  return {
    root
    workspace
    targets := #[]
    workspaceLoadNanos := workspaceFinished - workspaceStarted
    selectionNanos := 0
  }

def loadAll (requestedRoot : FilePath) : IO Snapshot := do
  let root ← IO.FS.realPath requestedRoot
  let discovery ← Discovery.run root none
  let workspaceStarted ← IO.monoNanosNow
  let workspace ← loadWorkspace root
  let workspaceFinished ← IO.monoNanosNow
  let targets ← discovery.sources.mapM fun relative => do
    snapshotTarget workspace discovery root (root / FilePath.mk relative)
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

/- Identify the evaluated setup **and the formatter settings that change canonical bytes**.

The `[format]` fold is what `ruff-13` RCD-IMPL owes the moment `line-width` became a runtime key
(`notes/01-discovery.md` §9.1). Formatter identity is `(path, byteSize, mtime)` of the executable
(`Cache.lean`), so editing the old compile-time `canonicalWidth` still invalidated — a rebuild rewrites
the file. A *runtime* override changes output without touching the binary at all, so without this
component two projects on one machine at different widths would serve each other's cached
`CanonicalText`. `[lint]` settings are deliberately absent: they project over an unchanged canonical
result and must stay out of identity, exactly as `CLAUDE.md` requires of rule selection. -/
def configurationIdentity (_snapshot : Snapshot) (target : SourceTarget) : IO Digest :=
  let format := target.config.format.identityString
  match target.module? with
  | some mod => return Digest.ofString (moduleConfiguration mod ++ "\u0000" ++ format)
  | none => do
    if target.path.fileName == some "lakefile.lean" then
      return Digest.ofString <| String.intercalate "\u0000"
        ["lakefile", target.relativePath, Lean.versionString, Lean.githash, format]
    return Digest.ofString <| String.intercalate "\u0000"
      ["external-source", target.relativePath, format]

end LeanFmt.Internal.Project
