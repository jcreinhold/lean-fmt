/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

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

/- Run one shared Lake no-build graph and recover one status per module. Lake's public runner only
returns aggregate success; the exact-toolchain `import all` boundary lets this private capability
await the typed jobs without parsing monitor output or showing callers a lifecycle. -/
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
This is the graph fact FMT004 (redundant import) consumes; a `RuleImpl` cannot fetch it
(`Rules.lean:17-19`), so this produces it and the application threads it into the finding set.

The `startBuild`/`wait` pattern matches `batchModuleStatuses`: it is *not* `runBuild`, so an out-of-date
target cannot trigger the `noBuild` process-exit (`finalizeBuild` → `IO.Process.exit`, which only fires
under `runBuild`). A fetch that errors under `noBuild` — the closure would need a build to resolve —
maps to the empty closure, a graceful miss: FMT004 then never reports a redundancy *through* that
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

/- The same graph fact as `importClosures`, but with the failure distinguished from the empty answer.

`importClosures` maps a failed fetch to `#[]`, which is right for FMT004: an unresolvable closure
there loses at most one report-only redundancy finding and can never fabricate one. It is **wrong for
cache currency**, where the closure decides what must be compared. An empty closure means "nothing to
check", so folding the error into `#[]` would turn an unknown answer into a *permissive* one — a
stale hit, the one direction currency must never degrade toward.

So this returns `none` for a module whose closure could not be resolved, and the caller misses. The
two operations stay separate rather than one calling the other, because they differ in which failure
direction is safe, and that is a per-caller judgement no flag should be able to flip.

A name absent from the workspace is omitted from the result entirely; `closureDigest?` treats a
missing entry as `none` for the same reason. -/
def importClosures? (workspace : Lake.Workspace) (names : Array Lean.Name) :
    IO (Array (Lean.Name × Option (Array Lean.Name))) := do
  let resolved := names.filterMap fun name =>
    (workspace.findModule? name).map fun mod => (name, mod)
  if resolved.isEmpty then return #[]
  let registeredJobs ← Lake.mkJobQueue
  let context ← Lake.mkBuildContext' workspace { noBuild := true } registeredJobs
  let computation : Lake.Job (Lake.Job (Array (Option (Array Lean.Name)))) ←
    Lake.Workspace.startBuild context do
      let jobs ← resolved.mapM fun (_, mod) => do
        let job ← mod.transImports.fetch
        return job.mapResult fun
          | .ok mods state => .ok (some (mods.map (·.name))) state
          | .error _ state => .ok none state
      return Lake.Job.collectArray jobs "lean-fmt currency closures"
  let closuresJob ← match ← computation.wait with
    | .ok job _ => pure job
    | .error _ _ => throw <| IO.userError "could not construct currency closures"
  let closures ← match ← closuresJob.wait with
    | .ok closures _ => pure closures
    | .error _ _ => throw <| IO.userError "could not collect currency closures"
  return (resolved.zip closures).map fun ((name, _), closure) => (name, closure)

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

/- Ask `isCurrent`'s question and keep the answer's *value*.

`checkNoBuild` computes the build and returns whether it succeeded, discarding what it produced
(`Lake/Build/Run.lean:405-414`); `BuildResult.isOk` is definitionally `out.isOk` (`:320-321`), so
its `Bool` is exactly "`out` was `.ok`". Every caller that then wants the value runs the identical
graph a second time to get it.

That second traversal was measured: over 34 modules, the probe cost 3,676 ms and the build that
repeated it 3,663 ms — the same work, twice, for 16% of a cold run. This returns `out` itself, so the
up-to-date case traverses once.

Written out rather than delegated to `checkNoBuild` because there is nothing to delegate to: Lake
exposes the decision or the value, never both. The pieces below are Lake's own, reached through the
exact-toolchain `import all` boundary, exactly as `batchModuleStatuses` reaches them. The buffer
swap is `isCurrent`'s, for `isCurrent`'s reason: this builds its own monitor from a hardcoded
`noBuild` config and would otherwise redraw a spinner over our stderr. -/
def noBuildValue? {α : Type} (workspace : Lake.Workspace)
    (build : Lake.FetchM (Lake.Job α)) : IO (Option α) := do
  let buffer ← IO.mkRef { : IO.FS.Stream.Buffer }
  let stdout ← IO.setStdout (.ofBuffer buffer)
  let stderr ← IO.setStderr (.ofBuffer buffer)
  -- The two halves are timed rather than bracketed, and reported after the streams are restored:
  -- `withPhase` writes to stderr, which is this operation's own buffer for its whole duration — a
  -- phase emitted in here goes into the buffer and is discarded with it. Nothing inside this
  -- function can report on itself.
  let contextNanos ← IO.mkRef 0
  let fetchNanos ← IO.mkRef 0
  try
    let cfg : Lake.BuildConfig := { noBuild := true, verbosity := .quiet }
    -- Split because the two halves have different lifetimes. Context construction depends on the
    -- workspace only, so a long-lived session could in principle build it once; the fetch reads the
    -- artifacts on disk *now*, which is the whole point of the probe and cannot be reused across a
    -- rebuild. Which half the 105 ms per LSP request lives in decides whether that is worth doing.
    let contextStarted ← IO.monoNanosNow
    let jobs ← Lake.mkJobQueue
    let mctx ← Lake.mkMonitorContext cfg jobs
    let bctx ← Lake.mkBuildContext' workspace cfg jobs
    let fetchStarted ← IO.monoNanosNow
    contextNanos.set (fetchStarted - contextStarted)
    let job ← Lake.Workspace.startBuild bctx build
    let result ← Lake.monitorBuild mctx job
    fetchNanos.set ((← IO.monoNanosNow) - fetchStarted)
    -- `finalizeBuild` is deliberately not called: it is the one that turns a stale `noBuild` into
    -- `IO.Process.exit` (`:367-368`). Staleness is a `none` here, and the caller builds.
    return result.out.toOption
  finally
    discard <| IO.setStdout stdout
    discard <| IO.setStderr stderr
    recordDuration "nobuild_context" (← contextNanos.get)
    recordDuration "nobuild_fetch" (← fetchNanos.get)

/- Every target's setup job in one collection, so one graph traversal answers the whole batch.
Each job's own failure becomes a `none` at that position rather than failing the collection: one
module that cannot resolve must not zero the other 126. -/
private def batchedSetupJob (targets : Array SourceTarget) :
    Lake.FetchM (Lake.Job (Array (Option Lean.ModuleSetup))) := do
  let jobs ← targets.mapM fun target => do
    let job ← setupJob target
    return job.mapResult fun
      | .ok setup state => .ok (some setup) state
      | .error _ state => .ok none state
  return Lake.Job.collectArray jobs "lean-fmt exact setups"

/-- Exact Lake setups for a whole batch: **one** no-build traversal, then **one** build of whatever
that traversal could not answer.

`exactSetup` constructs a Lake build context, starts a build, and monitors it once *per target*, over
the same graph every time. Measured on this repository: 34 targets, 3,528 ms in `setup_probe`, one
full traversal each, for 8% of a cold `format --check`.

Batching the build matters for more than that traversal. A Lake build is not safe to run twice at
once inside one process — two contexts building the same module race on its output file, and
`noBuildValue?` swaps the process-wide stdout and stderr besides. Left to the per-target fallback,
those builds happen on the batch's worker threads, one per unbuilt target, all at once: a 127-file
`check` at twelve workers over an unbuilt tree reported five `broken` files and one infrastructure
failure, all of them Lake builds clobbering each other, where the same run at one worker was clean.
Here they are one build on the calling thread, before any worker starts.

`none` at a position means that target's setup did not resolve, from artifacts or from a build. It
is not an answer: the caller falls back to `exactSetup`, which reports the failure against that
file's own name. A batch that fails outright degrades to all-`none` rather than to an error, so this
can never decide a setup differently from the per-target path. -/
def exactSetups? (snapshot : Snapshot) (targets : Array SourceTarget) :
    IO (Array (Option Lean.ModuleSetup)) := do
  if targets.isEmpty then return #[]
  let allMissing := Array.replicate targets.size none
  let probed ←
    try
      match ← withPhase "setup_probe" <|
          noBuildValue? snapshot.workspace (batchedSetupJob targets) with
      -- A short array would silently mis-pair setups with targets, which is worse than not batching.
      | some setups => pure (if setups.size == targets.size then setups else allMissing)
      | none => pure allMissing
    catch _ => pure allMissing
  let stale := targets.zipIdx.filter fun (_, index) => probed[index]!.isNone
  if stale.isEmpty then return probed
  try
    let built ← withPhase "setup_build" <| snapshot.workspace.runBuild
      (cfg := { verbosity := .quiet }) (batchedSetupJob (stale.map (·.1)))
    if built.size != stale.size then return probed
    return stale.zipIdx.foldl (init := probed) fun setups ((_, original), position) =>
      match built[position]! with
      | some setup => setups.set! original (some setup)
      | none => setups
  catch _ =>
    return probed

def exactSetup (snapshot : Snapshot) (target : SourceTarget) : IO Lean.ModuleSetup := do
  match ← withPhase "setup_probe" <| noBuildValue? snapshot.workspace (setupJob target) with
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
