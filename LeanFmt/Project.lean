/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all Lake.Build.Run
import all Lake.DSL
import all Lake.Load.Lean.Elab
import all Lake.Load.Workspace
import all LeanFmt.ArtifactStore
import all LeanFmt.Config
import all LeanFmt.Digest
import all LeanFmt.Discovery
import all LeanFmt.Profile

import Std.Sync.Mutex
import Lake.Build.Module
import Lake.Config.Env
import Lake.Config.InstallPath

/-! Lake, held once.

This module owns the workspace load, complete non-`.lake` source selection, the exact module setup,
and one shared typed no-build graph. Everything a run needs from Lake — currency evidence, import
closures, module setups, the formatter's artifact facet — is fetched on that one graph and handed
back as plain values.

A traversal is the expensive thing, so the number of them is a gate rather than an implementation
detail: `tests/Suites/Performance.lean` counts them. Do not replace this with a Lake run per file.

`Provenance` is what keeps it honest. Lake's build setup describes bytes that are the file on disk;
an editor's unsaved buffer is not those bytes, so only `disk` may take that route. -/

open System

namespace LeanFmt.Internal.Project

open LeanFmt.Internal.Profile

/- Where a target's bytes came from, which decides whether Lake's *build* setup describes them.

`Module.recFetchSetup` takes a module's imports from the file on disk; `setupServerModule` takes
them from a header handed to it. That difference is the whole of this type. Only bytes that are the
file on disk can use the first, so only `disk` may. -/
private inductive Provenance where
  /-- Read from the file, unmodified. -/
  | disk
  /-- An editor buffer or stdin. Never `disk` even when the bytes happen to match the file: an
  editor promises nothing about what is saved. -/
  | buffer
  /-- A candidate this run produced. `fix` may reorder or drop an import (FMT004, FMT005) and
  `organize` exists to, so the imports on disk are the ones being changed. -/
  | rewritten
  deriving BEq

structure SourceTarget where private mk ::
  module? : Option Lake.Module
  path : FilePath
  relativePath : String
  source : String
  private provenance : Provenance
  /-- The **effective** configuration for this file: the closest recognized config at or above its
  directory, with its `extend` chain already composed. Carried
  per target rather than per run because two files in one run may legitimately disagree about
  `line-width` or `[lint]`. -/
  config : FormatterConfig
  /-- The directory whose config governs this file, root-relative. Two targets sharing a key share a
  configuration, which is what lets the caller resolve one `RulePlan` per distinct config instead of
  one per file. -/
  configKey : String

/- What the run has already asked the graph about imports. `asked` is separate from `resolved`
because three answers must stay apart: a name never asked about, a name Lake refuses (not a
workspace library module — absent from `resolved`), and a name whose closure would not resolve
(`some none`). FMT004 reads the second and third differently, so collapsing them moves reports. -/
/-- The two closures of one module, which answer different questions and must not be swapped.

`build` is Lake's `transImports`: everything the module transitively imports, which is everything
whose compiled output could have shaped how its own source elaborated. That is what **currency**
needs, and narrowing it would be a stale hit.

`visible` follows only `public import` edges: what a *dependent* sees through this module. That is
what **redundancy** needs. Under the module system a plain `import` is not re-exported, so a module
being in the build closure does not make its contents reachable — Lake draws the same distinction
itself, as `reachable := importAll || imp.isExported` in `fetchTransImportArts`.

Both come from one traversal because both walk the same `mod.input` nodes. -/
structure ImportClosures where private mk ::
  /-- Everything the module transitively imports. `none` if the graph could not resolve it. -/
  build : Option (Array Lean.Name) := none
  /-- Everything a dependent sees through it. `none` if the graph could not resolve it. Private
  because the one question anyone asks of it is membership; `sees` is that question, and holding
  the answer as a set rather than a list is what makes it cheap. -/
  private visible : Option (Std.HashSet Lean.Name) := none
  deriving Inhabited

/-- Does a dependent that writes an import of this module see `name` through it?

`false` for a closure the graph could not resolve. That is FMT004's degradation and the direction a
report-only rule must take: an unresolved closure loses at most one redundancy report and can never
fabricate one. Currency makes the opposite choice on its own closure; see
`ResultCache.closureDigests`. -/
def ImportClosures.sees (closure : ImportClosures) (name : Lean.Name) : Bool :=
  (closure.visible.map (·.contains name)).getD false

/-- What one selection asked of the import graph, and everything the answering traversal saw.

`resolved` is keyed by the names asked for; `edges` is keyed by every module those closures passed
through, which is a far larger set. Both come out of one walk. -/
private structure ClosureMemo where
  asked : Std.HashSet Lean.Name := {}
  resolved : Std.HashMap Lean.Name ImportClosures := {}
  edges : Std.HashMap Lean.Name (Array (Lean.Name × Bool)) := {}

/-- What the import graph answered: the closures the caller named, and the direct-import edges of
every module they reach. One walk produces both, and a caller that needs only one ignores the
other. -/
structure ImportGraph where private mk ::
  /-- Keyed by the names asked for. A name absent from the map is not a workspace library module. -/
  closures : Std.HashMap Lean.Name ImportClosures
  /-- Every module reached, mapped to all of its direct imports, each flagged `isExported`. -/
  edges : Std.HashMap Lean.Name (Array (Lean.Name × Bool))
  deriving Inhabited

structure Snapshot where private mk ::
  root : FilePath
  workspace : Lake.Workspace
  targets : Array SourceTarget
  workspaceLoadNanos : Nat
  selectionNanos : Nat
  private closures : Std.Mutex ClosureMemo

inductive ModuleEvidence where
  | current
  | needsFrontend
  deriving BEq

private def expectedVersion (pin : String) : String :=
  let version := (pin.splitOn ":").getLast!
  if version.startsWith "v" then (version.drop 1).toString else version

private def targetLeanInstall (root : FilePath) : IO Lake.LeanInstall := do
  let sysroot ←
    match ← IO.getEnv "LEAN_SYSROOT" with
    | some path =>
      pure (FilePath.mk path)
    | none =>
      let lean := (← IO.getEnv "LEAN").getD "lean"
      if lean.trimAscii.isEmpty then
        throw <| IO.userError "target Lean discovery was disabled by an empty LEAN value"
      let output ←
        IO.Process.output
            { cmd := lean
              args := #["--print-prefix"]
              cwd := root }
      unless output.exitCode == 0 do
        throw <|
            IO.userError
              s!"could not resolve the target Lean installation: \
          {output.stderr.trimAscii}"
      pure (FilePath.mk output.stdout.trimAscii.copy)
  let install ← Lake.LeanInstall.get sysroot
  unless install.githash == Lean.githash do
    throw <|
        IO.userError
          s!"target Lean revision {install.githash} does not match this \
      lean-fmt build ({Lean.githash}); install lean-fmt for the target toolchain"
  return install

def loadWorkspace (root : FilePath) : IO Lake.Workspace := do
  let pinPath := root / "lean-toolchain"
  -- Absence is the commonest first run there is -- the tool was pointed at the wrong directory --
  -- and `readFile`'s own failure answers it with an errno and the path it happened to try, which
  -- names neither the cause nor the argument the caller chose. Path errors name the caller's own
  -- argument; `--root` is that argument here even when it was defaulted rather than typed.
  unless ← pinPath.pathExists do
    throw <|
        IO.userError
          s!"not a Lean project: no lean-toolchain in {root}\n\
      run lean-fmt from the project root, or point it at one with --root PATH"
  let pin ← IO.FS.readFile pinPath
  let pin := pin.trimAscii.copy
  -- One lean-fmt build serves one toolchain because it loads the target's `.olean`s, and those
  -- load only in the compiler that wrote them. The remedy has to be spelled out: "install
  -- lean-fmt for the target toolchain" is advice the reader usually cannot act on, because for
  -- most toolchains no such release exists and nothing here says which one would.
  unless expectedVersion pin == Lean.versionString do
    throw <|
        IO.userError
          s!"target toolchain {pin} does not match this lean-fmt build \
      (Lean {Lean.versionString})\n\
      Lean's ABI is not stable across releases, so one lean-fmt build serves one toolchain.\n\
      Either move this project to a toolchain lean-fmt targets, or add lean-fmt as a Lake\n\
      dependency, which moves the toolchain for you. The version table is in the README:\n\
      https://github.com/jcreinhold/lean-fmt#install"
  let lean ← targetLeanInstall root
  let lake := Lake.LakeInstall.ofLean lean
  unless ← lake.lake.pathExists do
    throw <| IO.userError s!"target toolchain has no Lake executable at {lake.lake}"
  let elan? ← Lake.findElanInstall?
  let lakeEnvResult ← (Lake.Env.compute lake lean elan?).toIO'
  let lakeEnv ←
    match lakeEnvResult with
    | .ok environment =>
      pure environment
    | .error message =>
      throw <| IO.userError message
  let loaded ← Lake.loadWorkspace { lakeEnv, wsDir := root } |>.toBaseIO
  loaded.getDM <| throw <| IO.userError s!"could not load Lake workspace at {root}"

private def relativeLess (left right : SourceTarget) : Bool :=
  left.relativePath < right.relativePath

private def deduplicate (targets : Array SourceTarget) : Array SourceTarget :=
  let (_, unique) :=
    targets.foldl (init := (none, #[])) fun (previous, unique) target =>
      if previous == some target.relativePath then (previous, unique)
      else (some target.relativePath, unique.push target)
  unique

private def insideRoot (root path : FilePath) : Bool :=
  path == root || path.toString.startsWith (root.toString ++ FilePath.pathSeparator.toString)

/-- Whether a root-relative path lies inside Lake's build directory.

Gate 1 of the selection table, and nothing lifts it: no
configuration key, no `--config`, no explicit path, no `force-exclude` setting. `.lake` holds Lake's
build outputs and vendored dependency sources; writing there corrupts a build the user did not ask us
to touch. -/
private def insideLakeDirectory (relativePath : String) : Bool :=
  relativePath == ".lake" || relativePath.startsWith ".lake/" || relativePath.startsWith ".lake\\"

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
      provenance := .disk
      config := discovery.configFor relativePath
      configKey := discovery.configKeyFor relativePath }

/-- Resolve `.` and `..` without touching the filesystem.

`FilePath.normalize` only canonicalizes separators (`Init/System/FilePath.lean:83-89`), and
`realPath` is unusable here: an unsaved buffer's path need not exist. So the walk runs over
`components`. A `..` that would escape an absolute root is dropped rather than allowed to climb past
it, keeping `insideRoot` below meaningful on a path like `<root>/../etc`. -/
private def resolveLexically (path : FilePath) : FilePath :=
  let leadingSlash := path.toString.startsWith FilePath.pathSeparator.toString
  let resolved :=
    path.components.foldl (init := ([] : List String)) fun acc component =>
      if component == "" || component == "." then acc
      else if component == ".." then acc.dropLast else acc ++ [component]
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
buffer keeps the module identity its on-disk twin has. It does not inherit that twin's *setup*: the
provenance is `buffer`, so `setupJob` resolves the imports in the buffer rather than the ones on
disk, which is the whole point of an editor holding unsaved bytes. A path with nothing behind it
resolves to `none` and takes the standalone route `diagnosticSetup` already serves.

`spelling?` exists because "the string the caller wrote" and "the path to resolve" stopped being one
string once a caller spoke URIs. A language-server client names a document
`file:///…`, and an error naming the decoded path would name something the client never sent. The
gates are unchanged and there is still one implementation of them; only the noun in the message
moves. Every path-taking caller passes `none` and reads as before. -/
def unsavedTarget (workspace : Lake.Workspace) (discovery : Discovery.Discovery) (root : FilePath)
    (argument : String) (source : String) (spelling? : Option String := none) : IO SourceTarget :=
  do
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
  let path ←
    if ← candidate.pathExists then
      IO.FS.realPath candidate
    else
      pure candidate
  return {
      module? := workspace.findModuleBySrc? path
      path
      relativePath
      source
      provenance := .buffer
      config := discovery.configFor relativePath
      configKey := discovery.configKeyFor relativePath }

/- Load executable Lake configuration, select every requested source exactly once, and snapshot all
bytes before analysis. Module/standalone classification is hidden in `SourceTarget`.

One `Discovery` walk drives selection, not a walk of its own plus a root-only config. With no
requested files the selected set is what discovery kept:
gate 1, the ignore sources, and each file's *own* effective `include`/`exclude`.

An explicitly named file skips gates 2-4 unless its effective configuration sets `force-exclude`, and
never consults `include` even then — `include` answers "when I say nothing, format these", and naming
a path is saying something. Gate 1 is not skippable and lives in `snapshotTarget`, so it covers
both path forms. -/
def load (requestedRoot : FilePath) (discovery : Discovery.Discovery) (requested : Array FilePath) :
    IO Snapshot := do
  let root ← IO.FS.realPath requestedRoot
  let workspaceStarted ← IO.monoNanosNow
  let workspace ← loadWorkspace root
  let workspaceFinished ← IO.monoNanosNow
  let paths ←
    if requested.isEmpty then
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
  let targets ←
    if requested.isEmpty then
      pure targets
    else
      targets.filterM fun target => do
          unless target.config.forceExclude do
            return true
          if !discovery.sources.contains target.relativePath then
            return false
          return discovery.gateFor target.relativePath != .configExclude
  let selectionFinished ← IO.monoNanosNow
  return {
      root
      workspace
      targets := deduplicate (targets.qsort relativeLess)
      workspaceLoadNanos := workspaceFinished - workspaceStarted
      selectionNanos := selectionFinished - workspaceFinished
      closures := ← Std.Mutex.new {} }

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
      closures := ← Std.Mutex.new {} }

def loadAll (requestedRoot : FilePath) : IO Snapshot := do
  let root ← IO.FS.realPath requestedRoot
  let discovery ← Discovery.run root none
  let workspaceStarted ← IO.monoNanosNow
  let workspace ← loadWorkspace root
  let workspaceFinished ← IO.monoNanosNow
  let targets ←
    discovery.sources.mapM fun relative => do
        snapshotTarget workspace discovery root (root / FilePath.mk relative)
  let selectionFinished ← IO.monoNanosNow
  return {
      root
      workspace
      targets := deduplicate (targets.qsort relativeLess)
      workspaceLoadNanos := workspaceFinished - workspaceStarted
      selectionNanos := selectionFinished - workspaceFinished
      closures := ← Std.Mutex.new {} }

/- Resolve one already-selected source by filesystem identity. Path normalization and root
containment stay below the service boundary; callers receive the canonical immutable target or a
single ordinary miss. -/
def Snapshot.findTarget? (snapshot : Snapshot) (requested : FilePath) : IO (Option SourceTarget) :=
  do
  if requested.isAbsolute then
    return none
  try
    let path ← IO.FS.realPath (snapshot.root / requested)
    unless insideRoot snapshot.root path do
      return none
    return snapshot.targets.find? (·.path == path)
  catch _ =>
    return none

/-- The same file with different bytes: a candidate this run produced, to be validated under the
same module identity. The result is never `disk` again, whatever it started as — its imports are
what the rewrite made them, not what the file says. -/
def SourceTarget.withSource (target : SourceTarget) (source : String) : SourceTarget :=
  { target with
    source, provenance := .rewritten }

/- How many Lake graph traversals this run has started.

Every traversal in the product passes through one of the two operations below, and this is what
makes the count a gate rather than a description: a fourth traversal site cannot be added without
being counted, because there is nowhere else to start one from. A count derived instead by summing
`lake_graph`, `setup_probe`, and `setup_build` would read the same today and silently miss a site
brought in under a fourth phase name.

The mutex is not decoration. Batch runs traverse from the calling thread, but the fallback below
runs under each `ExactRun`'s own Lake lock, and two language-server requests hold two of those. -/
initialize graphTraversals : Std.Mutex Nat ←
  Std.Mutex.new 0

/- Report one traversal, as the run's running total.

A running total rather than a line per site, because `cache.*` records mean "the value now": a
consumer reading the last line gets the run's count whichever site wrote it, and no site needs to
know how many others there are. The lock is taken only when the channel is on, so a production run
pays one `getenv` per traversal — against a traversal, which is measured in seconds. -/
private def countTraversal : IO Unit := do
  unless ← enabled do
    return
  recordCount "lake_graphs" (← graphTraversals.atomically (modifyGet fun n => (n + 1, n + 1)))

/- One no-build graph's value, awaited job by job so one failure stays at its own position.

`monitorBuild` cannot do that. It returns `.error "build failed"` whenever `MonitorResult.isOk` is
false (`Lake/Build/Run.lean:333`), and `isOk` is `failures.isEmpty` (`:218-219`) over failures
`reportJob` accumulates for *every* registered job (`:129`) — so one failure outranks every per-job
`mapResult` and zeroes the batch. Awaiting the collection directly keeps the `mapResult` meaningful.
Measured on the artifact facet over `ArtifactLayout` (built) plus `Main` (never built):
`monitorBuild` gave hit=0/miss=2, this gives hit=1/miss=1.

No buffer swap, and none needed: with no monitor there is no `reportJob` and no `log.replay`, so a
job's log never reaches the caller's streams. The two entry points this replaced both needed one —
`checkNoBuild` builds its own monitor from a hardcoded config and redraws a spinner over our stderr,
and a hand-built one ran a monitor for the same reason. Neither is reachable now.

`finalizeBuild` is not called here either — under `noBuild` it turns staleness into
`IO.Process.exit` (`:367-368`), which no `catch` below it survives. Staleness is a `none`. -/
private def noBuildValuePerJob? {α : Type} (workspace : Lake.Workspace)
    (build : Lake.FetchM (Lake.Job α)) : IO (Option α) := do
  countTraversal
  try
    let jobs ← Lake.mkJobQueue
    let bctx ← Lake.mkBuildContext' workspace { noBuild := true, verbosity := .quiet } jobs
    let computation ← Lake.Workspace.startBuild bctx build
    let job ←
      match ← computation.wait with
      | .ok job _ =>
        pure job
      | .error _ _ =>
        return none
    match ← job.wait with
    | .ok value _ =>
      return some value
    | .error _ _ =>
      return none
  catch _ =>
    return none

/- The building traversal, and the run's other one. Quiet is not a caller's choice: a build Lake
narrates would write a monitor's spinner over a report on the same stream.

Quiet alone does not silence the monitor: `Verbosity.quiet` only clears `showProgress`
(`Lake/Build/Context.lean:48-50`), while `LogConfig.outLv` keeps its `.info` default
(`Lake/Util/Log.lean:608`), so any job whose `withLoggedIO` captured info-level output — including a
`` `Task.get` called from a `(sync := true)` task `` backtrace from Lake's own
`Module.computeExportInfo` awaiting jobs inside a `sync := true` continuation (lean4#13598's class;
the #13601 fix covered `recFetchSetup` only) — is reported with an `ℹ [x/y] Replayed` caption over our
report's stream. `outLv := .warning` withholds info captures; failures still surface, because the
monitor replays a failed job's whole log at `.trace` regardless (`Lake/Build/Run.lean:149`). -/
private def buildValue {α : Type} (workspace : Lake.Workspace) (build : Lake.FetchM (Lake.Job α)) :
    IO α := do
  countTraversal
  workspace.runBuild (cfg := { verbosity := .quiet, outLv := .warning }) build

/- One `-Dname=value` as `lean` reads it, or `none` if `LeanOptions` cannot carry the value.

`LeanOptions` holds exactly `String`, `Bool`, and `Nat` (`Lean/Util/LeanOptions.lean:16-20`), which
is the whole space a `ModuleSetup` can express, so this is a total decode of that space rather than
a subset of Lean's. It is the inverse of `LeanOptionValue.asCliFlagValue`, the encoder Lake used on
the way out.

It differs from `lean`'s own `setConfigOption` in one place: `lean` looks the name up in the option
declarations and takes the declared type, so a `String` option written `-Dfoo=true` stays the string
`"true"` there and becomes a `Bool` here. Reading it back through `KVMap` would then miss and take
the default. Matching that exactly needs `getOptionDecls`, which lives behind `import all Lean.Shell`
and would pull the server and the LCNF backend into every module that imports this one. -/
private def decodeLeanArgOption? (spelling : String) : Option Lean.LeanOption := do
  let separator := spelling.find (· == '=')
  guard <| !separator.IsAtEnd
  let name := (spelling.sliceTo separator).toString
  guard <| !name.isEmpty
  let raw := (spelling.sliceFrom (separator.next!)).toString
  let value : Lean.LeanOptionValue :=
    if raw == "true" then .ofBool true
    else
      if raw == "false" then .ofBool false
      else
        if raw.length ≥ 2 && raw.startsWith "\"" && raw.endsWith "\"" then
          .ofString (raw.drop 1 |>.dropEnd 1).toString
        else
          match raw.toNat? with
          | some number => .ofNat number
          | none => .ofString raw
  return { name := name.toName, value }

/- The options a module's Lake arguments set, in Lake's own order.

`lake build` spawns `lean <weakLeanArgs ++ leanArgs> … --setup setup.json`
(`Lake/Build/Module.lean:972`), so the command line and the setup are two channels and the command
line is applied second. `--setup` carries `options` and nothing else, so a project setting
`moreLeanArgs := #["-DwarningAsError=true"]` got an option the build applies and the exact frontend
did not — while `moduleConfiguration` folded both arrays into cache identity anyway, making the
entry conservative for a difference nobody could name. Folding them here makes the identity honest.

Only `-D` is folded, because only `-D` names something a `ModuleSetup` can carry. The rest of Lake's
arguments (`-w`, `--load-dynlib`, a bare `-o`) are `lean` shell flags with no setup equivalent, and
they stay in the cache identity, where a difference we cannot reproduce should count as a miss. -/
private def leanArgOptions (mod : Lake.Module) : Lean.LeanOptions :=
  let arguments := mod.weakLeanArgs ++ mod.leanArgs
  let (options, _) :=
    arguments.foldl (init := (({} : Lean.LeanOptions), false))
      fun (options, pendingSeparate) argument =>
      if pendingSeparate then
        match decodeLeanArgOption? argument with
        | some option => (options.append (Lean.LeanOptions.ofArray #[option]), false)
        | none => (options, false)
      else
        if argument == "-D" then (options, true)
        else
          if argument.startsWith "-D" then
            match decodeLeanArgOption? (argument.drop 2).toString with
            | some option => (options.append (Lean.LeanOptions.ofArray #[option]), false)
            | none => (options, false)
          else (options, false)
  options

/- The setup `lake build` would use, when this target's bytes are the ones `lake build` would read.

`mod.setup.fetch` is the build path: `recFetchSetup` over `mod.presetup`, which is a memoized facet
sitting beside `mod.olean` in the same graph. `setupServerModule` is the editor path, which Lake
documents as not constructing a proper trace state, computes its transitive imports through the
un-memoized `computeTransImportsAux`/`computePrecompileImportsAux`, and drops
`leanOptOverrides` — `recFetchPreSetup` folds those into `leanOptions` and `setupEditedModule` does
not, so a project setting one per package got options `lake build` applies and we ignored.

The editor path stays for the two provenances that need it and for files Lake has no module for.
The predicate is not "does it exist on disk": a saved-but-modified buffer exists and its imports are
the ones being typed.

`ensureJob` wraps both arms because `Lean.parseImports'` *throws*. Outside a job that throw escapes
into whatever is constructing the collection and takes every other target with it. -/
private def setupJob (target : SourceTarget) : Lake.FetchM (Lake.Job Lean.ModuleSetup) :=
  Lake.ensureJob do
    let job ←
      match target.module?, target.provenance with
      | some mod, .disk =>
        mod.setup.fetch
      | _, _ =>
        let header ← Lean.parseImports' target.source target.relativePath
        Lake.setupServerModule target.relativePath target.path (some header)
    -- The command line Lake would also have passed, folded in second, as Lake applies it.
    match target.module? with
    | none =>
      return job
    | some mod =>
      let extra := leanArgOptions mod
      if extra.values.isEmpty then
        return job
      return job.map fun setup => { setup with options := setup.options.append extra }

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
      mtime := 0 }

/-- The set of modules reachable from `root` over exported edges only, `root` excluded.

`edges` maps a module to its direct imports, each flagged with whether the import is exported; the
walk follows the exported ones. The flag rides along rather than being filtered out first so that
one map serves both this walk and currency's, which needs every import.

Excluding `root` matches `transImports`, whose
closure of `X` likewise does not contain `X`, so both closures answer "what else does importing this
bring in" and a caller cannot get a different answer by asking the wrong one.

**`import all` is not modelled, deliberately.** Lake propagates an `importAll` flag through the walk,
so `import all X` exposes more of `X` than `X` re-exports. Following exported edges alone therefore
*under*-approximates the visible set when the covering import is `import all` — FMT004 then misses a
true redundancy rather than inventing one, which is the direction a report-only rule must err in,
and the same direction `redundancyEligible` already takes. -/
private def visibleFrom (root : Lean.Name)
    (edges : Std.HashMap Lean.Name (Array (Lean.Name × Bool))) : Std.HashSet Lean.Name :=
  Id.run do
    -- The walk's own `seen` set *is* the answer, so nothing is copied out of it. Its one consumer
    -- asks membership, and answering that by scanning a list cost 38.6 s of a 58 s warm mathlib
    -- run: every import pair in every file scanned a closure averaging 1,185 names.
    --
    -- A sorted array and a binary search answer the same question in 0.4 GB less, because the set
    -- would be transient and the array retained. It was measured and rejected: the sort costs 7 s
    -- of a 25 s run, and warm footprint is not this product's peak — the cold run needs 5.9 GB
    -- whatever this holds.
    --
    -- Terminates on `seen` rather than on a bound, so a cyclic edge map cannot spin.
    let mut seen : Std.HashSet Lean.Name := {}
    let mut stack := #[root]
    while !stack.isEmpty do
      let name := stack.back!
      stack := stack.pop
      for (imp, exported) in edges[name]?.getD #[] do
        if exported && !seen.contains imp then
          seen := seen.insert imp
          stack := stack.push imp
    return seen

/-- Every module any of the given closures passes through, mapped to its direct imports, as one job
on the graph that is already running.

**One map for the whole selection, not one per root.** The closures overlap almost completely on a
real project, so a per-root map re-read and re-formatted the same module's imports once for every
module that transitively imports it, and Lake holds every root's job result at once — over mathlib,
8,834 maps of thousands of entries alive together. Measured on a warm mathlib `check`: 2.9 GB peak
footprint per root against 1.4 GB for the union, and 6.8 s of graph time against 2.3 s. The union
costs one entry per distinct module.

The build closures bound the union — everything visible is imported — so this fetches `mod.input`
for that set and nothing wider. Those fetches are the same memoized nodes `transImports` just used,
so the map costs the fold, not a second traversal.

A module whose input will not resolve is left out rather than failing the map, which keeps one bad
module from zeroing the other 8,833. Both consumers read that absence in their own direction:
currency misses, and `visibleFrom` sees an edge fewer. -/
private def importEdgesJob (roots : Array Lake.Module)
    (builds : Lake.Job (Array (Option (Array Lake.Module)))) :
    Lake.FetchM (Lake.Job (Std.HashMap Lean.Name (Array (Lean.Name × Bool)))) :=
  builds.bindM (sync := true) fun builds => do
    let mut members : Std.HashMap Lean.Name Lake.Module := {}
    for mod in roots do
      members := members.insert mod.name mod
    for build in builds do
      for mod in build.getD #[] do
        members := members.insert mod.name mod
    let ordered := members.toArray
    let inputJobs ←
      ordered.mapM fun (_, mod) => do
          let job ← mod.input.fetch
          return job.mapResult fun
              | .ok input state =>
                .ok
                  (some
                    (input.imports.filterMap fun imp => imp.module?.map (·.name, imp.isExported)))
                  state
              | .error _ state => .ok none state
    let inputs := Lake.Job.collectArray inputJobs "lean-fmt module inputs"
    return inputs.mapResult fun
        | .ok inputs state =>
          .ok
            ((ordered.zip inputs).foldl (init := Std.HashMap.emptyWithCapacity ordered.size)
              fun edges ((name, _), imports?) =>
              match imports? with
              | some imports => edges.insert name imports
              | none => edges)
            state
        | .error e state => .error e state

/-- What a run wants from one Lake graph.

Every field is a traversal cost, so absent means *do not fetch*, never "fetch and discard". -/
structure Demand where
  /-- Is each target's module up to date? -/
  status : Bool := false
  /-- What does each name in `extraImports` import — both closures, from one walk? -/
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
structure TargetFacts where private mk ::
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

structure GraphFacts where private mk ::
  /-- Aligned index-for-index with the `targets` argument, always. -/
  targets : Array TargetFacts
  /-- Keyed by the names passed as `extraImports`. A name absent from the map is not a workspace
  library module; a field of its `ImportClosures` is `none` when the graph could not resolve that
  closure. -/
  imports : Std.HashMap Lean.Name ImportClosures
  /-- Every module either closure walked through, mapped to its direct imports — all of them, not
  just the exported ones. This is `imports`' `build` field as a graph rather than a flattened list,
  and it is what lets a caller fold one digest per edge instead of one per closure member. -/
  edges : Std.HashMap Lean.Name (Array (Lean.Name × Bool))

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
  let blank : GraphFacts :=
    { targets := Array.replicate targets.size {}
      imports := Std.HashMap.emptyWithCapacity 0
      edges := Std.HashMap.emptyWithCapacity 0 }
  let statusModules : Array (Option Lake.Module) :=
    if demand.status then targets.map (·.module?) else Array.replicate targets.size none
  let closureModules : Array (Lean.Name × Lake.Module) :=
    if demand.closures then
      extraImports.filterMap fun name => (workspace.findModule? name).map (name, ·)
    else #[]
  let facetName := `module.leanFmtArtifact
  let facetConfig? ←
    if !demand.artifacts then
      pure none
    else if (← IO.getEnv "LEAN_FMT_DISABLE_ARTIFACT") == some "1" then
      pure none
    else
      pure (workspace.findModuleFacetConfig? facetName)
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
    | none =>
      pure (Array.replicate targets.size none)
    | some _ =>
      targets.mapM fun target =>
          match target.module? with
          | none => pure none
          | some mod => do
            let sidecar :=
              Lean.modToFilePath (mod.pkg.buildDir / "lean-fmt-artifacts") mod.name "json"
            if (← sidecar.pathExists) && (← (sidecar.addExtension "trace").pathExists) then
              return some mod
            return none
  let setupTargets : Array (Option SourceTarget) :=
    if demand.setups then targets.map some else Array.replicate targets.size none
  -- Nothing to ask is not the same as asking and failing: skip the traversal entirely rather than
  -- pay a build context to answer an empty question.
  if
      statusModules.all Option.isNone && closureModules.isEmpty && facetModules.all Option.isNone &&
        setupTargets.all Option.isNone then
    return blank
  let setupCollection (chosen : Array (Option SourceTarget)) :
    Lake.FetchM (Lake.Job (Array (Option Lean.ModuleSetup))) := do
    let jobs ←
      chosen.mapM fun target? => do
          match target? with
          | none =>
            return Lake.Job.pure (α := Option Lean.ModuleSetup) none
          | some target =>
            let job ← setupJob target
            return job.mapResult fun
                | .ok setup state => .ok (some setup) state
                | .error _ state => .ok none state
    return Lake.Job.collectArray jobs "lean-fmt exact setups"
  let build :
    Lake.FetchM
      (Lake.Job
        (Array (Option Bool) ×
          (Array (Option (Array Lake.Module)) × Std.HashMap Lean.Name (Array (Lean.Name × Bool))) ×
          Array (Option String) × Array (Option Lean.ModuleSetup))) :=
    do
    let statusJobs ←
      statusModules.mapM fun mod? => do
          match mod? with
          | none =>
            return Lake.Job.pure (α := Option Bool) none
          | some mod =>
            let job ← mod.olean.fetch
            return job.mapResult fun
                | .ok _ state => .ok (some true) state
                | .error _ state => .ok (some false) state
    let closureJobs ←
      closureModules.mapM fun (_, mod) => do
          let build ← mod.transImports.fetch
          return build.mapResult fun
              | .ok mods state => .ok (some mods) state
              | .error _ state => .ok none state
    let facetJobs ←
      facetModules.mapM fun mod? => do
          match facetConfig?, mod? with
          | some config, some mod =>
            let job ← config.run (β := Lake.FacetOut facetName) mod
            return job.mapResult fun
                | .ok value state => .ok (some (config.format .json value)) state
                | .error _ state => .ok none state
          | _, _ =>
            return Lake.Job.pure (α := Option String) none
    let statuses := Lake.Job.collectArray statusJobs "lean-fmt module evidence"
    let builds := Lake.Job.collectArray closureJobs "lean-fmt import closures"
    let edges ← importEdgesJob (closureModules.map (·.2)) builds
    let closures := builds.zipWith (·, ·) edges
    let facets := Lake.Job.collectArray facetJobs "lean-fmt official artifacts"
    let setups ← setupCollection setupTargets
    -- `zipWith` errors if either side errors, which is exactly why every per-target job above is
    -- `mapResult`-ed to `.ok` first: no collection can fail, so the tuple cannot either.
    return ((statuses.zipWith (·, ·) closures).zipWith (fun (s, c) f => (s, c, f)) facets).zipWith
        (fun (s, c, f) u => (s, c, f, u)) setups
  match ← withPhase "lake_graph" <| noBuildValuePerJob? workspace build with
  | none =>
    return blank
  | some (statuses, closures, facets, probed) =>
    -- A short array would silently mis-pair facts with targets, which is worse than no batch.
    if
        statuses.size != statusModules.size || closures.1.size != closureModules.size ||
          facets.size != facetModules.size ||
          probed.size != setupTargets.size then
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
    let stale :=
      (setupTargets.zip probed).map fun (target?, setup?) => if setup?.isNone then target? else none
    let setups ←
      if stale.all Option.isNone then
        pure probed
      else
        try
          let built ← withPhase "setup_build" <| buildValue workspace (setupCollection stale)
          if built.size != probed.size then
            pure probed
          else
            pure ((probed.zip built).map fun (probed?, built?) => probed?.orElse fun _ => built?)
        catch _ =>
          pure probed
    let facts ←
      targets.zipIdx.mapM fun (target, index) => do
          -- The descriptor is decoded and consumed here and nowhere else. `readFacet?` recomputes the
          -- content hash and matches the module name and the exact source, so filesystem presence or a
          -- raw path never stands in for build validity.
          let artifact? ←
            do
              let some mod := target.module? | pure none
              let some encoded := facets[index]! | pure none
              let some facet := decodeFacetDescriptor? encoded | pure none
              readFacet? facet mod.name target.source
          return { current? := statuses[index]!, artifact?, setup? := setups[index]! }
    return {
        targets := facts
        imports :=
          (closureModules.zip closures.1).foldl (init :=
            Std.HashMap.emptyWithCapacity closureModules.size) fun map ((name, _), build) =>
            map.insert name
              { build := build.map (·.map (·.name))
                -- The honest `none` survives the shared map: a root whose own input did not
                -- resolve has no entry, and an empty visible closure is a different answer from an
                -- unresolved one.
                visible :=
                  if closures.2.contains name then some (visibleFrom name closures.2) else none }
        edges := closures.2 }

/-- The transitive import closure of each named module, and of every selected target's module.

Same shape as `GraphFacts.imports` and the same three answers, so a caller reads it the same way.

**One fetch for the run, whichever consumer asks first.** Two consumers need closures and they name
different modules: FMT004 wants the closure of every *import* a header lists, and cache currency
wants the closure of every *selected module*. Fetched separately those were two traversals of one
graph — 16 ms and 8 ms over this repository's 127 warm files, and neither could see that the other
had just walked the same nodes. Resolving both sets on the first call pays the union's extra
`transImports` jobs once, inside a traversal that was happening anyway.

The selected targets are folded in here rather than by each caller, so neither has to know the
other exists: FMT004 asks for its imports and gets a map that happens to hold more, and every
lookup is by name.

**The memo lasts as long as the snapshot, which is a run.** Nothing here builds, so no module's
imports move under a `Project.load` snapshot. `Project.loadWorkspaceOnly`'s does outlive edits —
the language server holds one for its whole lifetime — which is why the single-file editor path
fetches its own closure and does not come through here. A `none` is remembered along with the
rest: a closure that would not resolve will not resolve on a second ask, and re-asking would spend
a traversal to learn it again. -/
def Snapshot.importClosures (snapshot : Snapshot) (names : Array Lean.Name) : IO ImportGraph :=
  snapshot.closures.atomically do
    let memo ← get
    let wanted := names ++ snapshot.targets.filterMap (·.module?.map (·.name))
    let missing :=
      wanted.foldl (init := #[]) fun missing name =>
        if memo.asked.contains name || missing.contains name then missing else missing.push name
    if missing.isEmpty then
      return { closures := memo.resolved, edges := memo.edges }
    let facts ← graph snapshot.workspace #[] missing { closures := true }
    let asked := missing.foldl (init := memo.asked) fun asked name => asked.insert name
    let resolved :=
      missing.foldl (init := memo.resolved) fun resolved name =>
        match facts.imports[name]? with
        | some closure => resolved.insert name closure
        | none => resolved
    let edges := facts.edges.fold (fun map name imports => map.insert name imports) memo.edges
    set ({ asked, resolved, edges } : ClosureMemo)
    return { closures := resolved, edges }

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
          let loaded ←
            Lake.loadWorkspaceRoot
                  { lakeEnv := snapshot.workspace.lakeEnv
                    wsDir := parent } |>.toBaseIO
          evidence := evidence.push (if loaded.isSome then .current else .needsFrontend)
      else
        evidence := evidence.push .needsFrontend
    | some _ =>
      -- `needsFrontend` is the safe direction for a module the graph could not speak for: it costs
      -- an elaboration, where `current` would serve a projection of stale compiled output.
      evidence :=
        evidence.push
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
  match ← withPhase "setup_probe" <| noBuildValuePerJob? snapshot.workspace (setupJob target) with
  | some setup =>
    return setup
  | none =>
    withPhase "setup_build" <| buildValue snapshot.workspace (setupJob target)

private def moduleConfiguration (mod : Lake.Module) : String :=
  String.intercalate "\u0000"
    [mod.name.toString, toString mod.pkg.id?, (Lean.toJson mod.leanOptions).compress,
      String.intercalate "\u0000" mod.leanArgs.toList,
      String.intercalate "\u0000" mod.weakLeanArgs.toList,
      String.intercalate "\u0000" (mod.dynlibs.map toString).toList,
      String.intercalate "\u0000" (mod.plugins.map toString).toList, toString mod.allowImportAll,
      toString mod.platformIndependent]

/- Identify the evaluated root-package policy used by Lake for sources outside a declared library.
Header bytes and import order remain in the source identity; ordered search roots and artifact
contents remain in the environment epoch. This value covers the remaining setup decisions without
running `setupServerModule` on an all-hit cache path. -/
def externalConfigurationIdentity (workspace : Lake.Workspace) : Digest :=
  let root := workspace.root
  Digest.ofString <|
    String.intercalate "\u0000"
      [toString root.id?, (Lean.toJson workspace.serverOptions).compress,
        toString root.precompileModules,
        String.intercalate "\u0000" (root.dynlibs.map toString).toList,
        String.intercalate "\u0000" (root.plugins.map toString).toList,
        String.intercalate "\u0000" (root.externLibs.map (·.name.toString)).toList,
        String.intercalate "\u0000" (root.extraDepTargets.map toString).toList]

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
      return Digest.ofString <|
          String.intercalate "\u0000"
            ["lakefile", target.relativePath, Lean.versionString, Lean.githash, format]
    return Digest.ofString <|
        String.intercalate "\u0000" ["external-source", target.relativePath, format]

end LeanFmt.Internal.Project
