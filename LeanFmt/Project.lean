/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.ArtifactStore
import all LeanFmt.Config
import all LeanFmt.Digest
import all LeanFmt.Discovery
import all LeanFmt.Profile

import Lake.Build.Module
import all Lake.Build.Run
import Lake.Config.Env
import Lake.Config.InstallPath
import all Lake.DSL
import all Lake.Load.Lean.Elab
import all Lake.Load.Workspace

open System

namespace LeanFmt.Internal.Project

open LeanFmt.Internal.Profile

structure SourceTarget where
  private mk ::
  module? : Option Lake.Module
  path : FilePath
  relativePath : String
  source : String
  /-- The **effective** configuration for this file: the closest recognized config at or above its
  directory, with its `extend` chain already composed. Carried
  per target rather than per run because two files in one run may legitimately disagree about
  `line-width` or `[lint]`. -/
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

Gate 1 of the selection table, and nothing lifts it: no
configuration key, no `--config`, no explicit path, no `force-exclude` setting. `.lake` holds Lake's
build outputs and vendored dependency sources; writing there corrupts a build the user did not ask us
to touch. -/
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
  -- Gate 1 runs here, beside the containment and extension checks, rather than only in
  -- `discoverPaths`: both path forms reach this operation, and only the discovery form used to be
  -- filtered — so `format .lake/packages/dep/Dep.lean` wrote a dependency's source.
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

`FilePath.normalize` only canonicalizes separators (`Init/System/FilePath.lean:83-89`), and
`realPath` is unusable here: an unsaved buffer's path need not exist. So the walk runs over
`components`. A `..` that would escape an absolute root is dropped rather than allowed to climb past
it, keeping `insideRoot` below meaningful on a path like `<root>/../etc`. -/
private def resolveLexically (path : FilePath) : FilePath :=
  let leadingSlash := path.toString.startsWith FilePath.pathSeparator.toString
  let resolved := path.components.foldl (init := ([] : List String)) fun acc component =>
    if component == "" || component == "." then acc
    else if component == ".." then acc.dropLast
    else acc ++ [component]
  let joined := String.intercalate FilePath.pathSeparator.toString resolved
  FilePath.mk (if leadingSlash then FilePath.pathSeparator.toString ++ joined else joined)

/-- One **unsaved** buffer as a target: bytes and an identity, with no filesystem read for content.

This is the one place the stdin surface cannot
reuse `snapshotTarget`, which calls `realPath` and `readFile` — an editor formatting a never-saved
buffer has a path with nothing behind it. Every *gate* `snapshotTarget` applies still applies here,
in the same order with the same messages, each naming `argument`, the string the caller wrote, as
`CLAUDE.md` requires of path-taking surface.

Gate 1 rules out `.lake` on this path as firmly as on an explicit file argument, and arriving
through a pipe does not reopen it. The stdin path never
publishes, so this guard is not the only one; it is here because a gate some entry points skip guards
nothing.

`module?` resolves from the *real* path when the file happens to exist, so a saved-but-modified
buffer keeps the module identity its on-disk twin has and gets the same exact Lake setup. A path with
nothing behind it resolves to `none` and takes the standalone route `diagnosticSetup` already serves.

`spelling?` exists because "the string the caller wrote" and "the path to resolve" stopped being one
string once a caller spoke URIs. A language-server client names a document
`file:///…`, and an error naming the decoded path would name something the client never sent. The
gates are unchanged and there is still one implementation of them; only the noun in the message
moves. Every path-taking caller passes `none` and reads as before. -/
def unsavedTarget (workspace : Lake.Workspace) (discovery : Discovery.Discovery)
    (root : FilePath) (argument : String) (source : String)
    (spelling? : Option String := none) : IO SourceTarget := do
  let written := FilePath.mk argument
  let spelling := spelling?.getD argument
  let candidate := resolveLexically (if written.isAbsolute then written else root / written)
  unless insideRoot root candidate do
    throw <| IO.userError s!"selected file is outside the project root: {spelling}"
  unless candidate.extension == some "lean" do
    throw <| IO.userError s!"selected file is not a Lean source: {spelling}"
  let relativePath := (Lake.relPathFrom root candidate).toString
  if insideLakeDirectory relativePath then
    throw <| IO.userError s!"selected file is inside the Lake build directory: {spelling}"
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

One `Discovery` walk drives selection, not a walk of its own plus a root-only config. With no
requested files the selected set is what discovery kept:
gate 1, the ignore sources, and each file's *own* effective `include`/`exclude`.

An explicitly named file skips gates 2-4 unless its effective configuration sets `force-exclude`, and
never consults `include` even then — `include` answers "when I say nothing, format these", and naming
a path is saying something. Gate 1 is not skippable and lives in `snapshotTarget`, so it covers
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
      -- Resolve against the root, but report a missing file in the caller's own terms. `realPath`
      -- on a path that does not exist throws `noFileOrDirectory` naming its partially-resolved
      -- buffer, which absolutizes the leading component and mangles the rest — unreadable when a
      -- whole argument list arrives as one path (an unquoted shell variable under a non-splitting
      -- shell). Name what the caller wrote, consistent with the outside-root / not-a-source siblings
      -- and `Config` above.
      let candidate := if path.isAbsolute then path else root / path
      unless ← candidate.pathExists do
        throw <| IO.userError s!"selected file does not exist: {path}"
      IO.FS.realPath candidate
  let targets ← paths.mapM (snapshotTarget workspace discovery root)
  -- `force-exclude` runs after snapshotting because it reads the file's *own* effective
  -- configuration, which is a per-file fact. A path discovery dropped is absent from `sources`, so
  -- reusing that set gives the gate-2 answer without a second matcher.
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

A stdin request formats just the bytes it was handed, so it must not pay to
select the project: `load` snapshots every discovered source, the right cost for a batch run over a
tree and the wrong cost for one buffer an editor is waiting on. `ExactRun` reads only `workspace` and
`root` from a `Snapshot` — `envelope` and `exactSetup` never consult `targets` — so an empty
selection is a complete capability here, not a stub.

A long-lived session takes the other trade deliberately: it loads once and answers many requests, so
it wants `findTarget?`. A one-shot CLI invocation has no session to spread that cost over. -/
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

/- Can Lake validate `build` without building anything? Asked silently.

Every caller wants both halves — the answer and the silence — so both live here.

**Why `checkNoBuild` and not `runBuild`.** Under `noBuild`, an out-of-date target makes
`finalizeBuild` call `IO.Process.exit noBuildCode` (`Lake/Build/Run.lean:368`). That is a process
exit, not an exception, so no `catch` below it runs. `checkNoBuild` asks the same question and
returns a `Bool` (`:405-414`).

**Why the buffer swap.** `checkNoBuild` is the one Lake entry point a caller cannot quiet. It builds
its own monitor from a hardcoded `{noBuild := true}`, leaving `verbosity` at `.normal`, so
`BuildConfig.showProgress` is true and Lake redraws a spinner over our stderr whenever that is a
terminal. `runBuild` takes a config and `startBuild` runs no monitor at all; this one takes nothing.
Buffering is safe only because `checkNoBuild` returns rather than exits: around a call that exits,
the same buffer would hold the unflushed report while the process died. -/
def isCurrent {α : Type} (workspace : Lake.Workspace)
    (build : Lake.FetchM (Lake.Job α)) : IO Bool := do
  let buffer ← IO.mkRef { : IO.FS.Stream.Buffer }
  let stdout ← IO.setStdout (.ofBuffer buffer)
  let stderr ← IO.setStderr (.ofBuffer buffer)
  try
    workspace.checkNoBuild build
  finally
    discard <| IO.setStdout stdout
    discard <| IO.setStderr stderr

/- `noBuildValue?`'s question, awaited so that one job's failure stays at its own position.

`monitorBuild` cannot do that. It returns `.error "build failed"` whenever `MonitorResult.isOk` is
false (`Lake/Build/Run.lean:333`), and `isOk` is `failures.isEmpty` (`:218-219`) over failures
`reportJob` accumulates for *every* registered job (`:129`) — so one failure outranks every per-job
`mapResult` and zeroes the batch. Awaiting the collection directly keeps the `mapResult` meaningful.
Measured on the artifact facet over `ArtifactLayout` (built) plus `Main` (never built):
`monitorBuild` gave hit=0/miss=2, this gives hit=1/miss=1.

No buffer swap, and none needed: with no monitor there is no `reportJob` and no `log.replay`, so a
job's log never reaches the caller's streams. `noBuildValue?` needs the swap only because it runs a
monitor.

`finalizeBuild` is not called here either — under `noBuild` it turns staleness into
`IO.Process.exit` (`:367-368`), which no `catch` below it survives. Staleness is a `none`. -/
private def noBuildValuePerJob? {α : Type} (workspace : Lake.Workspace)
    (build : Lake.FetchM (Lake.Job α)) : IO (Option α) := do
  try
    let jobs ← Lake.mkJobQueue
    let bctx ← Lake.mkBuildContext' workspace { noBuild := true, verbosity := .quiet } jobs
    let computation ← Lake.Workspace.startBuild bctx build
    let job ← match ← computation.wait with
      | .ok job _ => pure job
      | .error _ _ => return none
    match ← job.wait with
    | .ok value _ => return some value
    | .error _ _ => return none
  catch _ =>
    return none

private def setupJob (target : SourceTarget) : Lake.FetchM (Lake.Job Lean.ModuleSetup) := do
  let header ← Lean.parseImports' target.source target.relativePath
  Lake.setupServerModule target.relativePath target.path (some header)

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

/-- What a run wants from one Lake graph.

Every field is a traversal cost, so absent means *do not fetch*, never "fetch and discard". -/
structure Demand where
  /-- Is each target's module up to date? -/
  status : Bool := false
  /-- What does each name in `extraImports` transitively import? -/
  closures : Bool := false
  /-- Each target's `leanFmtArtifact` facet, revalidated against its source. -/
  artifacts : Bool := false
  /-- Each target's exact Lake module setup. Unlike every other field this one may *build*: what the
  no-build pass cannot answer is built once, here, before any worker exists. -/
  setups : Bool := false

/-- What one graph could say about one target.

A `none` is always "the graph could not produce this", never a substituted default. Which direction
a `none` degrades toward is the *caller's* judgement, made where the consequence is visible:
`moduleEvidence` degrades toward `needsFrontend` and `ResultCache.closureDigests` toward a miss,
and both would be wrong if the other's default were built in here. -/
structure TargetFacts where
  private mk ::
  /-- `some false` is an answer, not a failure: under `noBuild` a failed `olean` fetch *is* "not up
  to date". `none` means the target is not a workspace module, or the traversal itself failed. -/
  current? : Option Bool := none
  /-- The module's formatter facet, already revalidated: its content hash recomputed and its payload
  matched to this target's module name and exact source. A missing, stale, corrupt, or failing
  facet is `none`. No `Lake.Artifact` descriptor escapes `graph`, because a descriptor is a public
  type and not authority by type alone. -/
  artifact? : Option ModuleArtifact := none
  /-- The exact Lake setup for this target, from artifacts or from the one build below. `none` is
  not an answer: the caller falls back to the per-target path, which reports the failure against
  that file's own name. -/
  setup? : Option Lean.ModuleSetup := none
  deriving Inhabited

structure GraphFacts where
  private mk ::
  /-- Aligned index-for-index with the `targets` argument, always. -/
  targets : Array TargetFacts
  /-- Keyed by the names passed as `extraImports`. A name absent from the map is not a workspace
  library module; a name mapping to `none` is one whose closure the graph could not resolve. -/
  imports : Std.HashMap Lean.Name (Option (Array Lean.Name))

/-- One no-build Lake graph for a whole selection.

**Why one.** This replaces operations that each built their own `Lake.BuildContext` and ran their
own traversal — a per-module status probe and two import-closure fetches that differed in one line.
A `BuildStore` is created per `startBuild`, not per context, so separate traversals share no
memoized node: `mod.input`, `mod.importInfo` and `mod.transImports` were recomputed once per
operation. One duplicated probe alone cost 3,676 ms and 3,663 ms over this repository's 34 modules —
the same work twice, for 16% of a cold run.

**Why no monitor.** Per-target isolation is the point: one module that cannot resolve must not zero
the other 126. `monitorBuild` cannot give it, for the reason `noBuildValuePerJob?` records.

**Closure keys resolve through `Workspace.findModule?`, never a target's own `module?`.**
`findModule?` searches libraries. An executable root such as `Main` *is* a `Lake.Module` but has no
resolvable closure, which is why `ResultCache.closureDigests` gives such targets the conservative
whole-workspace digest. Resolving them from `module?` would silently re-key every such entry. -/
def graph (workspace : Lake.Workspace) (targets : Array SourceTarget)
    (extraImports : Array Lean.Name := #[]) (demand : Demand := {}) : IO GraphFacts := do
  let blank : GraphFacts := {
    targets := Array.replicate targets.size {}
    imports := Std.HashMap.emptyWithCapacity 0
  }
  let statusModules : Array (Option Lake.Module) :=
    if demand.status then targets.map (·.module?)
    else Array.replicate targets.size none
  let closureModules : Array (Lean.Name × Lake.Module) :=
    if demand.closures then
      extraImports.filterMap fun name => (workspace.findModule? name).map (name, ·)
    else #[]
  let facetName := `module.leanFmtArtifact
  let facetConfig? ←
    if !demand.artifacts then pure none
    else if (← IO.getEnv "LEAN_FMT_DISABLE_ARTIFACT") == some "1" then pure none
    else pure (workspace.findModuleFacetConfig? facetName)
  -- A module whose sidecar does not exist is a certain miss: `readFacet?` reads that very file, so
  -- no traversal could return anything else for it. Excluding it here saves the job. The path is
  -- the facet's own convention — `artifactFile` in the lakefile that declares `leanFmtArtifact` —
  -- and the compiler suite's mixed-selection case notices if the two drift. The trace is probed
  -- alongside the sidecar because a stale or missing trace fails the no-build job the same way.
  --
  -- This filter was once load-bearing for a second reason and is not any more: a failing facet job
  -- used to zero every *other* module's artifact, and the cause was the monitor, not the sidecar.
  -- `noBuildValuePerJob?` carries that measurement. The filter is an optimization now.
  let facetModules : Array (Option Lake.Module) ←
    match facetConfig? with
    | none => pure (Array.replicate targets.size none)
    | some _ => targets.mapM fun target =>
      match target.module? with
      | none => pure none
      | some mod => do
        let sidecar := Lean.modToFilePath (mod.pkg.buildDir / "lean-fmt-artifacts") mod.name "json"
        if (← sidecar.pathExists) && (← (sidecar.addExtension "trace").pathExists) then
          return some mod
        return none
  let setupTargets : Array (Option SourceTarget) :=
    if demand.setups then targets.map some else Array.replicate targets.size none
  -- Nothing to ask is not the same as asking and failing: skip the traversal entirely rather than
  -- pay a build context to answer an empty question.
  if statusModules.all Option.isNone && closureModules.isEmpty
      && facetModules.all Option.isNone && setupTargets.all Option.isNone then
    return blank
  let setupCollection (chosen : Array (Option SourceTarget)) :
      Lake.FetchM (Lake.Job (Array (Option Lean.ModuleSetup))) := do
    let jobs ← chosen.mapM fun target? => do
      match target? with
      | none => return Lake.Job.pure (α := Option Lean.ModuleSetup) none
      | some target =>
        -- `setupJob` parses the header outside any job and `parseImports'` *throws*, so an
        -- unparseable header would abort the collection's construction and zero every other
        -- target. `ensureJob` turns that throw into this job's own failure.
        let job ← Lake.ensureJob (setupJob target)
        return job.mapResult fun
          | .ok setup state => .ok (some setup) state
          | .error _ state => .ok none state
    return Lake.Job.collectArray jobs "lean-fmt exact setups"
  let build : Lake.FetchM (Lake.Job
      (Array (Option Bool) × Array (Option (Array Lean.Name)) × Array (Option String)
        × Array (Option Lean.ModuleSetup))) := do
    let statusJobs ← statusModules.mapM fun mod? => do
      match mod? with
      | none => return Lake.Job.pure (α := Option Bool) none
      | some mod =>
        let job ← mod.olean.fetch
        return job.mapResult fun
          | .ok _ state => .ok (some true) state
          | .error _ state => .ok (some false) state
    let closureJobs ← closureModules.mapM fun (_, mod) => do
      let job ← mod.transImports.fetch
      return job.mapResult fun
        | .ok mods state => .ok (some (mods.map (·.name))) state
        | .error _ state => .ok none state
    let facetJobs ← facetModules.mapM fun mod? => do
      match facetConfig?, mod? with
      | some config, some mod =>
        let job ← config.run (β := Lake.FacetOut facetName) mod
        return job.mapResult fun
          | .ok value state => .ok (some (config.format .json value)) state
          | .error _ state => .ok none state
      | _, _ => return Lake.Job.pure (α := Option String) none
    let statuses := Lake.Job.collectArray statusJobs "lean-fmt module evidence"
    let closures := Lake.Job.collectArray closureJobs "lean-fmt import closures"
    let facets := Lake.Job.collectArray facetJobs "lean-fmt official artifacts"
    let setups ← setupCollection setupTargets
    -- `zipWith` errors if either side errors, which is exactly why every per-target job above is
    -- `mapResult`-ed to `.ok` first: no collection can fail, so the tuple cannot either.
    return ((statuses.zipWith (·, ·) closures).zipWith (fun (s, c) f => (s, c, f)) facets).zipWith
      (fun (s, c, f) u => (s, c, f, u)) setups
  match ← withPhase "lake_graph" <| noBuildValuePerJob? workspace build with
  | none => return blank
  | some (statuses, closures, facets, probed) =>
    -- A short array would silently mis-pair facts with targets, which is worse than no batch.
    if statuses.size != statusModules.size || closures.size != closureModules.size
        || facets.size != facetModules.size || probed.size != setupTargets.size then
      return blank
    -- The one place this operation may build, and it builds setups only. A stale `.olean` *is* the
    -- answer for status, an unresolvable closure is a miss, and a missing facet is
    -- `lean-fmt compiler build`'s business — so none of those is retried. A setup that did not
    -- resolve is not an answer at all, and without it the target cannot be analyzed.
    --
    -- One build, on the calling thread, before any worker exists. Lake is not safe to run twice at
    -- once in one process: two contexts building the same module race on its output file. Measured
    -- — a 127-file `check` at twelve workers over an unbuilt tree reported five `broken` files and
    -- one infrastructure failure, all of them Lake builds clobbering each other, where the same run
    -- at one worker was clean. `tests/Suites/Ci.lean` is the gate.
    let stale := (setupTargets.zip probed).map fun (target?, setup?) =>
      if setup?.isNone then target? else none
    let setups ←
      if stale.all Option.isNone then pure probed
      else
        try
          let built ← withPhase "setup_build" <| workspace.runBuild
            (cfg := { verbosity := .quiet }) (setupCollection stale)
          if built.size != probed.size then pure probed
          else pure ((probed.zip built).map fun (probed?, built?) => probed?.orElse fun _ => built?)
        catch _ => pure probed
    let facts ← targets.zipIdx.mapM fun (target, index) => do
      -- The descriptor is decoded and consumed here and nowhere else. `readFacet?` recomputes the
      -- content hash and matches the module name and the exact source, so filesystem presence or a
      -- raw path never stands in for build validity.
      let artifact? ← do
        let some mod := target.module? | pure none
        let some encoded := facets[index]! | pure none
        let some facet := decodeFacetDescriptor? encoded | pure none
        readFacet? facet mod.name target.source
      return { current? := statuses[index]!, artifact?, setup? := setups[index]! }
    return {
      targets := facts
      imports := (closureModules.zip closures).foldl
        (init := Std.HashMap.emptyWithCapacity closureModules.size)
        fun map ((name, _), closure) => map.insert name closure
    }

/-- The trace file Lake writes for a workspace module, or `none` if the name is not a workspace
module. Cache currency reads recorded trace facts; it does not resolve imports. -/
def moduleTracePath? (workspace : Lake.Workspace) (name : Lean.Name) : Option FilePath :=
  (workspace.findModule? name).map (·.traceFile)

/-- Every path Lake would write compiled output to for a workspace module: the three `.olean` forms
and the trace. `none` if the name is not a workspace module.

Cache currency uses this to tell *unbuilt* from *unreadable*. A module with none of these files on
disk has no compiled output, so it contributed no grammar to anything; a module missing only its
trace has output whose currency cannot be recomputed, which is a different answer. -/
def moduleOutputPaths? (workspace : Lake.Workspace) (name : Lean.Name) : Option (Array FilePath) :=
  (workspace.findModule? name).map fun mod =>
    #[mod.oleanFile, mod.oleanServerFile, mod.oleanPrivateFile, mod.traceFile]

/-- One source-tier verdict per target, projected from facts the caller already fetched.

This takes `GraphFacts` rather than running its own traversal so that a caller wanting both evidence
and the artifact facet pays for one graph, not two. The `lakefile.lean` arm stays here because it is
not a graph question at all — Lake has no module for a lakefile, so currency means "does this file
still load as a workspace root". -/
def moduleEvidence (snapshot : Snapshot) (facts : GraphFacts) : IO (Array ModuleEvidence) := do
  if (← IO.getEnv "LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE") == some "1" then
    return Array.replicate snapshot.targets.size .needsFrontend
  let mut evidence := #[]
  for (target, index) in snapshot.targets.zipIdx do
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
      -- `needsFrontend` is the safe direction for a module the graph could not speak for: it costs
      -- an elaboration, where `current` would serve a projection of stale compiled output.
      evidence := evidence.push
        (if facts.targets[index]!.current? == some true then .current else .needsFrontend)
  return evidence

/-- The exact Lake setup for one target, for a caller that has exactly one.

`graph` with `demand.setups` answers a whole selection in one traversal and is what a batch run
uses. This is the fallback for a target that traversal left unanswered, and the language server's
path, where there is one file by construction. The two steps are the same — probe, then build what
the probe could not answer — minus the batching, and the failure comes back as a thrown error
against this file's own name rather than as a `none` at a position.

Calling this in a loop is what `graph` replaces, and the loop was measured: 34 targets, one full
traversal each, 3,528 ms in `setup_probe`, 8% of a cold `format --check`. -/
def exactSetup (snapshot : Snapshot) (target : SourceTarget) : IO Lean.ModuleSetup := do
  match ← withPhase "setup_probe" <|
      noBuildValuePerJob? snapshot.workspace (setupJob target) with
  | some setup => return setup
  | none => withPhase "setup_build" <|
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

The `[format]` fold exists because `line-width` is a runtime key.
Formatter identity is `(path, byteSize, mtime)` of the executable
(`Cache.lean`), so editing the old compile-time `canonicalWidth` still invalidated — a rebuild rewrites
the file. A *runtime* override changes output without touching the binary, so without this component
two projects on one machine at different widths would serve each other's cached `CanonicalLayout`.
`[lint]` settings are deliberately absent: they project over an unchanged canonical result and must
stay out of identity, as `CLAUDE.md` requires of rule selection. -/
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
