/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all Lean.Shell
import all LeanFmt.Analysis
import all LeanFmt.Cache
import all LeanFmt.Config
import all LeanFmt.Edit
import all LeanFmt.Imports
import all LeanFmt.Profile
import all LeanFmt.Progress
import all LeanFmt.Project
import all LeanFmt.Semantic
import all LeanFmt.Suppression

import Lean.Util.Diff
import Std.Sync.CancellationToken
import Lake.Build.Module
import Lake.Build.Run
import Lake.Config.Env
import Lake.Config.InstallPath
import Lake.Load.Workspace

open System

namespace LeanFmt.Internal.Application

open LeanFmt.Internal.Profile

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

/-- Whether this mode's answer contains canonical text and so needs a projection to render.

`format` and `diff` render it; `check` and `fix` do not. `check` reports selected rules, so a
badly-laid-out but lint-clean file is `check`-clean. `fix` applies
admitted rule fixes at the file's **original** coordinates and does not reflow, like
`ruff check --fix` (run `fix` then `format` for both); a fixed file keeps its layout until `format`
runs. Keeping `check`/`fix` off this path also lets them take the source-only fast path on a
source-only selection, which needs no artifact. -/
def RunMode.rendersCanonical : RunMode → Bool
  | .check | .fix => false
  | .format | .diff => true

structure RunRequest where
  mode : RunMode
  root : FilePath
  files : Array FilePath
  cache : Bool := true
  configPath? : Option FilePath := none
  select : Array String := #[]
  ignore : Array String := #[]
  /-- Lifecycle/fixability selection, passed verbatim into
  `FormatterConfig.rulePlan` through a `CliSelection`. `extendSelect` adds to the selection;
  `fixable`/`unfixable`/`extendFixable` choose which selected rules' fixes `fix` applies; `preview`
  unlocks preview rules. -/
  extendSelect : Array String := #[]
  fixable : Array String := #[]
  unfixable : Array String := #[]
  extendFixable : Array String := #[]
  preview : Bool := false
  /-- `--reflow-comments` / `--no-reflow-comments`: a command-line override of the
  configuration's `reflow-comments`. `none` leaves every file's configuration as written. -/
  reflowComments? : Option Bool := none
  /-- Apply unsafe fixes too, not just safe ones. Decides which fixes `fix` admits into its patch
  (and `check`'s preview of it), never relaxing validation or conflict rejection. The
  rendering modes carry no rule fix — `format` publishes only layout, `diff` diffs only
  layout — so this flag changes only their reported withheld-unsafe count, not their bytes.
  Display-only fixes are unaffected: nothing applies them. -/
  unsafeFixes : Bool := false
  /-- `format --check`: the non-writing CI preview, meaningful only for
  `.format`. When `false` (the default), `format` publishes the canonical layout in place through the
  guarded path — the same publisher `fix` uses. When `true`, `format` renders but writes
  nothing and reports `would-format`/`clean`, the former default. `check`/`diff`/`fix` ignore
  it. -/
  formatCheck : Bool := false
  /-- How much candidate validation a publishing `format` owes its result. The default `.exact`
  structurally reparses the candidate and then admits it with a second render and
  `Validator.admit`; `--no-validate` sets `.structural`, which skips that final exact validator
  where the module's syntax frontier was admitted, still requiring the structural reparse. The
  CLI rejects every other mode and every non-publishing `format` form, so no other value ever
  reaches here — see `ValidationPolicy`. -/
  validationPolicy : ValidationPolicy := .exact
  /-- How many frontend children may run concurrently (`--workers`), or `none` to pick the number
  the way Lake picks it for its own build: `LEAN_NUM_THREADS` if that is set, else the machine's
  hardware concurrency. `resolveWorkers` does the picking. Scheduling only: every result is
  assembled by target index, so the report is byte-identical at any value. -/
  workers : Option Nat := none

/-- Whether this run publishes source. `fix` always does; `format` does unless `--check` demotes it to a
preview. A writer needs the validator child, so it must fall through to
`withExactRun` and stay off the cache-only preview fast paths — this is where `--check` reaches the
driver rather than stopping at `Cli.lean`. `check`/`diff` never write. -/
def RunRequest.writesFormat (request : RunRequest) : Bool :=
  request.mode == .format && !request.formatCheck

private abbrev SourceSnapshot :=
  Project.SourceTarget

structure FileReport where
  path : String
  status : String
  findings : Array Finding := #[]
  diagnostics : Array String := #[]
  formatted : Option String := none
  diff : Option String := none
  written : Bool := false
  /-- Fixes this file has that were withheld because they are unsafe and `--unsafe-fixes` was off —
  zero once the run opts in. Tells the user what `--unsafe-fixes` would add rather than leaving the
  withheld fixes invisible. -/
  withheldUnsafe : Nat := 0
  /-- Findings this file's source-suppression directives removed from the report. A nonzero count
  with an empty finding list means the file is clean only because a directive said so. -/
  suppressed : Nat := 0
  /-- Redundant-import (FMT004) candidates *withheld* from the report because a modifier or role
  reachability cannot reason about (`import all`, `meta import`, a re-exported `public import`) makes
  them unsafe even to name. Recorded, never silent. -/
  withheldRedundant : Nat := 0
  /-- Published under `format --no-validate`: the candidate was admitted on its structural reparse
  over an admitted syntax frontier, without the second render and `Validator.admit`. Zero on every
  default run and every non-publishing mode. -/
  validationBypassed : Nat := 0
  deriving Inhabited, Lean.ToJson

structure RunReport where
  mode : String
  files : Array FileReport
  findings : Nat
  changed : Nat
  written : Nat
  broken : Nat
  unbuilt : Nat
  rejected : Nat
  withheldUnsafe : Nat
  suppressed : Nat
  withheldRedundant : Nat
  /-- Files published under `format --no-validate` — summed `FileReport.validationBypassed`. -/
  validationBypassed : Nat := 0
  infrastructureFailures : Array String
  deriving Lean.ToJson

private structure ChildOutput where
  exitCode : UInt32
  stdout : String
  stderr : String

/-- A child that is running right now. A worker registers one at spawn and removes it when it reaps
it, so the registry's size is how many children are alive at that moment — the number
`active_children` reports. Nothing samples these to enforce a limit; a child caps its own heap.

`pgid` is the child's pid, which `setsid` also makes its process group's id. -/
private structure LiveChild where
  child : IO.Process.Child { stdin := .inherit, stdout := .null, stderr := .null }
  pgid : UInt32

/- A valid exact-analysis capability. Construction brackets its temporary storage, fixes the target
project and toolchain once, and owns collision-free request names. No caller can observe setup paths
or sequence cleanup. Batch envelopes use fresh child processes; the language server may instead
request an exact setup for its document-owned in-process analyzer. -/
structure ExactRun where private mk ::
  project : Project.Snapshot
  application : FilePath
  temporary : FilePath
  /-- How many frontend children may run concurrently, already resolved to a number. One takes the
  serial `runChild` path; above one, spawns register with `registry?` instead. -/
  workers : Nat
  /-- The children running now, or `none` at one worker, where one child runs at a time and the
  frame that spawned it is the only thing that needs to find it. Read for counting and for cleanup,
  never to decide whether to kill one. -/
  registry? : Option (IO.Ref (Array LiveChild))
  nextIndex : IO.Ref Nat
  /-- Setups already resolved for this run: root-relative path to the **source they were resolved
  from** and the setup itself.

  `Project.graph` fills this in one traversal for the files a run has decided will reach the
  frontend; `ExactRun.setupResult` reads it and falls back to the per-target `Project.exactSetup` on
  a miss. Empty is always correct — it just means every target pays its own traversal.

  **The source is stored and compared, not just the path.** A setup carries the header's imports
  (`setupJob` parses them out of the target's own bytes), and this run's writing modes hand the
  frontend a *rewritten* snapshot at the same path: `fix` may reorder or drop an import (FMT004,
  FMT005) and `organize` exists to. Keying on the path alone would validate a rewritten file against
  the imports it no longer has — precisely the check those modes perform. -/
  setups : IO.Ref (Std.HashMap String (String × Lean.ModuleSetup))
  /-- Setups retained for editor documents, keyed by the parsed module header rather than the whole
  buffer: ordinary edits do not alter imports and must not rebuild Lake's setup graph on every
  keystroke. Separate from `setups`, which deliberately keys rewritten sources by all bytes. -/
  documentSetups : IO.Ref (Std.HashMap String (String × Lean.ModuleSetup))
  /-- Held across every Lake call this run makes after its workers start. Lake is not safe to run
  twice at once inside one process: two build contexts building the same module race on its output
  file, and the fallback's `runBuild` monitor writes to the process's own stderr besides.
  `primeSetups` resolves the batch on one thread before any worker exists; this covers the per-target
  fallback behind it, which a worker reaches for a target the batch could not answer. -/
  lake : Std.Mutex Unit

private def writeSetup (directory : FilePath) (index : Nat) (setup : Lean.ModuleSetup) :
    IO FilePath := do
  let path := directory / s!"{index}.setup.json"
  IO.FS.writeFile path (Lean.toJson setup).compress
  return path

private def diagnosticSetup (snapshot : SourceSnapshot) : Lean.ModuleSetup :=
  match snapshot.module? with
  | some mod =>
    { name := mod.name
      package? := mod.pkg.id?
      isModule := true
      options := mod.leanOptions }
  | none => { name := `_unknown }

/- The setup for one target: the batch's answer if it has one for these exact bytes, otherwise a
per-target Lake resolution behind the run's lock. -/
private def ExactRun.setupResult (run : ExactRun) (snapshot : SourceSnapshot) :
    IO (Except IO.Error Lean.ModuleSetup) := do
  if let some (source, setup) := (← run.setups.get)[snapshot.relativePath]? then
    if source == snapshot.source then
      return Except.ok setup
  try
    return Except.ok (← run.lake.atomically (Project.exactSetup run.project snapshot))
  catch error =>
    return Except.error error

/-- Resolve and memoize the exact setup for an in-process document analyzer. Unlike `envelope`, this
returns no diagnostic substitute: a persistent snapshot may never be created under an approximate
setup. The parsed header identity changes exactly when the import-bearing part of the buffer does. -/
def ExactRun.setupSnapshot (run : ExactRun) (snapshot : SourceSnapshot) : IO Lean.ModuleSetup := do
  let input := Lean.Parser.mkInputContext snapshot.source snapshot.path.toString
  let (header, _, messages) ← Lean.Parser.parseHeader input
  let identity :=
    if messages.hasErrors then toString <| Digest.ofString snapshot.source
    else toString <| Digest.ofString (header.raw.unsetTrailing.reprint.getD "")
  if let some (cachedIdentity, setup) := (← run.documentSetups.get)[snapshot.relativePath]? then
    if cachedIdentity == identity then
      return setup
  let setup ← run.lake.atomically (Project.exactSetup run.project snapshot)
  run.documentSetups.modify (·.insert snapshot.relativePath (identity, setup))
  return setup

/-- The project's `[cache] closure` mode, read off any target: the key is project-level
configuration, so every target resolves to the same value, and an empty selection has no
closures to compute anyway — the default is never observed. -/
private def projectClosureMode (project : Project.Snapshot) : ClosureMode :=
  match project.targets[0]? with
  | some target => target.config.closureMode
  | none => .artifacts

/-- How many frontend children to run at once. `--workers N` decides it when given; otherwise this
picks the number the way Lake picks it for its own build — `LEAN_NUM_THREADS` if that is set, else
the hardware concurrency (`src/runtime/object.cpp`'s `get_lean_num_threads`). Lake bounds a build by
cores and nothing else, and a frontend child of ours costs about what a `lean` of Lake's costs, so
the same number is the right one. -/
private def resolveWorkers (requested : Option Nat) : IO Nat := do
  if let some workers := requested then
    return max workers 1
  if let some threads := (← IO.getEnv "LEAN_NUM_THREADS").bind (·.toNat?) then
    return max threads 1
  return max (System.Platform.Internal.getHardwareConcurrency ()).toNat 1

private def awaitRead (task : Task (Except IO.Error String)) : IO String := do
  match ← IO.wait task with
  | .ok contents =>
    return contents
  | .error error =>
    throw error

/-- The message a cancelled exact child raises, and the only way a caller can tell cancellation apart
from a real failure.

A string marker rather than an error constructor because `IO.Error` is Lean's and this is the one
distinction lean-fmt needs from it. `cancelled?` below is the reader; nothing should match the text by
hand. -/
def cancellationMessage : String :=
  "exact frontend child cancelled by request"

/-- Whether an error is this operation's cancellation, as opposed to a failure worth reporting. -/
def cancelled? (error : IO.Error) : Bool :=
  ((toString error).splitOn cancellationMessage).length > 1

/-- How long one frontend child may run before the run stops waiting for it.

Unbounded was the wrong default: a single mathlib module deadlocked its child and a whole-project
run sat on it for 45 minutes, producing nothing — no file named, no exit, no output, because a
report prints only at the end. A bound converts that into one named file and exit 2, and the other
8,840 files still get reported.

Ten minutes is deliberately far above any real file — the slowest mathlib module measured here
takes seconds — so this fires on a stall, not on slow work. `LEAN_FMT_CHILD_TIMEOUT_MS` overrides
it; `0` disables the bound for someone deliberately debugging a hang. -/
def childTimeoutMs : IO Nat := do
  match (← IO.getEnv "LEAN_FMT_CHILD_TIMEOUT_MS").bind (·.toNat?) with
  | some override =>
    return override
  | none =>
    return 600000

/-- The frontend child's task-pool size: what Lake gives its own `lean`, never what this process
inherited.

The child must not read `LEAN_NUM_THREADS` from the environment, because for this product that
variable already means something else — `resolveWorkers` reads it to decide how many children run
at once. A caller who writes `LEAN_NUM_THREADS=2` to keep a build off their whole machine was
silently also sizing each child's pool at 2, and that is the bug: the child elaborates with
`Elab.async := true`, so its own elaboration sits on a pool thread, and a tactic that spawns pooled
tasks and waits for them starves when the remaining threads are all themselves waiting.

Measured, on a two-level nest (`TacticM.parFirst` whose jobs each call `TacticM.parFirst`): the
child deadlocks at 1, 2, and 3 threads and finishes in 0.7 s at 4. The requirement is one thread per
simultaneously blocked wait plus one to make progress, so it scales with the nest's width, not with
a constant anyone can pick. The floor of 4 covers that measured case; the child timeout covers what
no floor can.

The size is free. Lean creates pool workers on demand, so raising the child from 2 to 12 over this
repository's 105 files moved nothing: 12.3-12.9 s against 12.7-13.2 s, 90.1 s user against 91.2 s,
and 829 MB peak against 832 MB. `LEAN_FMT_CHILD_THREADS` overrides it, which is how the deadlock
above was bisected. -/
def childThreads : IO Nat := do
  match (← IO.getEnv "LEAN_FMT_CHILD_THREADS").bind (·.toNat?) with
  | some override =>
    return max override 1
  | none =>
    return max 4 (System.Platform.Internal.getHardwareConcurrency ()).toNat

def timeoutMessage (budget : Nat) : String :=
  s!"exact frontend child ran past its {budget} ms bound and was stopped; \
    set LEAN_FMT_CHILD_TIMEOUT_MS to raise the bound, or 0 to remove it"

/-- The wall-clock instant a child spawned now must finish by, or `none` when the bound is off.
Computed per spawn, so a queued child's clock starts when it runs, not when the run began. -/
def childDeadline? : IO (Option Nat) := do
  match ← childTimeoutMs with
  | 0 =>
    return none
  | budget =>
    return some ((← IO.monoMsNow) + budget)

/- Poll instead of blocking on `wait`: a long-running server must be able to drop a request while it
is running, and this child is the only thing to drop. One look every 50 ms bounds how long a
cancelled request keeps working without spinning. A batch run passes `cancel? := none` and never
looks. -/
private partial def awaitChild
    (child : IO.Process.Child { stdin := .inherit, stdout := .piped, stderr := .piped })
    (stdoutTask stderrTask : Task (Except IO.Error String)) (cancel? : Option Std.CancellationToken)
    (deadline? : Option Nat := none) : IO ChildOutput := do
  match ← child.tryWait with
  | some exitCode =>
    return {
        exitCode
        stdout := ← awaitRead stdoutTask
        stderr := ← awaitRead stderrTask }
  | none =>
    let expired ←
      match deadline? with
      | some deadline =>
        do
          pure (decide ((← IO.monoMsNow) >= deadline))
      | none =>
        pure false
    if expired || (← cancel?.mapM (·.isCancelled)).getD false then
      try
        child.kill
      catch _ =>
        pure ()
      discard child.wait
      discard <| awaitRead stdoutTask
      discard <| awaitRead stderrTask
      let budget ← childTimeoutMs
      throw <| IO.userError (if expired then timeoutMessage budget else cancellationMessage)
    IO.sleep 50
    awaitChild child stdoutTask stderrTask cancel? deadline?

private def runChild (arguments : IO.Process.SpawnArgs)
    (cancel? : Option Std.CancellationToken := none) : IO ChildOutput := do
  let child ←
    IO.Process.spawn
        { cmd := arguments.cmd
          args := arguments.args
          cwd := arguments.cwd
          env := arguments.env
          inheritEnv := arguments.inheritEnv
          stdin := .inherit
          stdout := .piped
          stderr := .piped
          setsid := true }
  -- The piped runner, for a child whose answer is small enough to hold in memory and that runs
  -- one-at-a-time (the compiler-status probe). The batch frontend path is pipe-free: its
  -- envelopes are projection-sized and its children run `workers` at a time, and two pipe
  -- handles per child did not survive that scale — see `spawnChild`.
  recordCount "active_children" 1
  let stdoutTask ← IO.asTask child.stdout.readToEnd
  let stderrTask ← IO.asTask child.stderr.readToEnd
  awaitChild child stdoutTask stderrTask cancel? (← childDeadline?)

/-- The pipe-free equivalent of `awaitChild`, for children whose results travel on per-target
files. Same cancellation contract: one poll every 50 ms, and a cancelled child is killed and
reaped before the cancellation error propagates. -/
private partial def awaitChildExit
    (child : IO.Process.Child { stdin := .inherit, stdout := .null, stderr := .null })
    (cancel? : Option Std.CancellationToken) (deadline? : Option Nat := none) : IO UInt32 := do
  match ← child.tryWait with
  | some exitCode =>
    return exitCode
  | none =>
    let expired ←
      match deadline? with
      | some deadline =>
        do
          pure (decide ((← IO.monoMsNow) >= deadline))
      | none =>
        pure false
    if expired || (← cancel?.mapM (·.isCancelled)).getD false then
      try
        child.kill
      catch _ =>
        pure ()
      discard child.wait
      let budget ← childTimeoutMs
      throw <| IO.userError (if expired then timeoutMessage budget else cancellationMessage)
    IO.sleep 50
    awaitChildExit child cancel? deadline?

/-- Spawn one pipe-free child and wait for its exit code: the one-worker branch of `spawnChild`,
where one child runs at a time and the frame that spawned it is the only thing that needs to
find it. -/
private def spawnWait (arguments : IO.Process.SpawnArgs)
    (cancel? : Option Std.CancellationToken := none) : IO UInt32 := do
  let child ←
    IO.Process.spawn
        { cmd := arguments.cmd
          args := arguments.args
          cwd := arguments.cwd
          env := arguments.env
          inheritEnv := arguments.inheritEnv
          stdin := .inherit
          stdout := .null
          stderr := .null
          setsid := true }
  recordCount "active_children" 1
  awaitChildExit child cancel? (← childDeadline?)

/-- Spawn one pipe-free frontend child and wait for its exit code. At one worker this is
`spawnWait`: one child at a time, one admission counted. Above one, the child joins the registry
before it can run unobserved, and the `finally` kills and reaps a child its worker is walking
away from, so the registry and the process table never disagree.

Pipe-free because of what the pipes cost. The child is this same binary running
`__analyze-exact`; its envelope and diagnostics now travel on per-target files it writes itself
(the trailing output arguments `envelope` passes). The piped version held two handles per child
and drained them on dedicated reader threads, and under `--workers N > 1` those handles were not
released when the child was reaped: measured on a 1400-target run, the parent accumulated ~2
descriptors per child and hit `EMFILE` (\"too many open files\") around target 1300, failing
every remaining target's setup file. One worker was spared only because one child's handles were
collected before the next spawned. Files have no such lifecycle: the child closes its own
writes, and the parent unlinks each target's files when the target's envelope is decoded.

Nothing here bounds what a child may allocate. Lake bounds nothing either: it spawns one `lean` per
module and passes no `-M`, no `ulimit`, no `setrlimit`. lean-fmt used to divide a `--max-memory`
envelope between its children, which refused work on any project importing mathlib — 187 of 200
files at eight workers — because the number it divided counted each child's shared `.olean` mapping
in full. A child reading 2.05 GiB of RSS had a physical footprint of 173 MiB. The control that
remains is `--workers`. -/
private def ExactRun.spawnChild (run : ExactRun) (arguments : IO.Process.SpawnArgs)
    (cancel? : Option Std.CancellationToken := none) : IO UInt32 := do
  let some registry := run.registry? | spawnWait arguments cancel?
  let child ←
    IO.Process.spawn
        { cmd := arguments.cmd
          args := arguments.args
          cwd := arguments.cwd
          env := arguments.env
          inheritEnv := arguments.inheritEnv
          stdin := .inherit
          stdout := .null
          stderr := .null
          setsid := true }
  let entry : LiveChild :=
    { child
      pgid := child.pid }
  registry.modify (·.push entry)
  recordCount "active_children" (← registry.get).size
  try
    awaitChildExit entry.child cancel? (← childDeadline?)
  finally
    registry.modify (·.filter (·.pgid != entry.pgid))
    -- `pollChild` may already have reaped the child (its exit branch), and Lean's `tryWait` does
    -- not cache: a second successful-position `tryWait` raises ECHILD. A throw here therefore
    -- means "already reaped" — exactly the case where there is nothing to kill.
    let exited ←
      try
        pure (← entry.child.tryWait).isSome
      catch _ =>
        pure true
    unless exited do
      try
        entry.child.kill
      catch _ =>
        pure ()
      discard entry.child.wait

private def ExactRun.nextPathIndex (run : ExactRun) : IO Nat :=
  run.nextIndex.modifyGet fun index => (index, index + 1)

/-- Resolve these targets' Lake setups in one graph traversal, before any of them is analyzed.

Called with exactly the files a run has already decided will reach the frontend — never the whole
selection. The distinction is the whole point: on this repository all 34 targets reach it and one
traversal replaces 34, but on a large project where the cache and the source tier answer almost
everything, priming the whole selection would resolve setups nothing asks for. On the frozen
`mathlib-sample`, 1 of 62 targets reaches the frontend.

Folding this into `Project.graph`'s whole-selection call would save the second traversal, and it was
measured rather than argued (2026-07-27, cache-cold `check --select FMT011 --no-cache`, both arms in
one binary, interleaved, summing `phase.lake_graph_ms`). On this repository, 127 targets of which
124 reach the frontend, the fold won: 62 ms against 89 ms at the median. On the frozen
`mathlib-sample`, 63 targets of which 62 are artifact-served, it lost by 222 ms at the median over
eight pairs, favoured in 6 of 8 — because the whole-selection graph resolves 62 mathlib-scale
setups that nothing reads, where this call resolves none at all (`targets.size < 2` returns).
Reports were byte-identical across every pair on both corpora. The saving is one no-build traversal
and the cost scales with the selection, so the split stays.

It is also where every Lake build this run needs happens: `Project.graph` builds what its no-build
pass cannot answer, here, on one thread, before a worker exists. Lake cannot run twice at once in
one process, and the per-target fallback behind this used to put one build on each worker thread.

Best effort by construction. Anything this fails to resolve is absent from the map, and
`ExactRun.setupResult` falls back to the per-target path, holding `run.lake`. -/
private def ExactRun.primeSetups (run : ExactRun) (targets : Array SourceSnapshot) : IO Unit := do
  if targets.size < 2 then
    return
  let facts ←
    withPhase "setup_prime" <|
        Project.graph run.project.workspace targets (demand := { setups := true })
  run.setups.modify fun map =>
      (targets.zip facts.targets).foldl (init := map) fun map (target, resolved) =>
        match resolved.setup? with
        | some setup => map.insert target.relativePath (target.source, setup)
        | none => map

private def ExactRun.envelope (run : ExactRun) (snapshot : SourceSnapshot) (captureSemantic : Bool)
    (validator := false) (captureOccurrences : Bool := false)
    (format? : Option FormatConfig := none) (cancel? : Option Std.CancellationToken := none)
    (compiled : Bool := false) (validationPolicy : ValidationPolicy := .exact) :
    IO AnalysisEnvelope := do
  let index ← run.nextPathIndex
  -- Three phases: this operation once reported as one unnamed 43-second gap,
  -- and the three do entirely different work: `exact_setup` resolves the module's Lake setup in
  -- *this* process, `exact_child` is the frontend round trip in another one, and `envelope_decode`
  -- parses what came back. Only the middle one is elaboration; the outer two are this process's
  -- own cost and are the ones an optimization here could remove.
  let (setupResult, setupPath, sourcePath, outPath, errPath) ←
    withPhase "exact_setup" do
        let setupResult ← run.setupResult snapshot
        let setup :=
          match setupResult with
          | .ok setup => setup
          | .error _ => diagnosticSetup snapshot
        let setupPath ← writeSetup run.temporary index setup
        let sourcePath := run.temporary / s!"{index}.lean"
        IO.FS.writeFile sourcePath snapshot.source
        pure
            (setupResult, setupPath, sourcePath, run.temporary / s!"{index}.out",
              run.temporary / s!"{index}.err")
  try
    let threads ← childThreads
    let overrideName := if validator then "LEAN_FMT_TEST_VALIDATOR" else "LEAN_FMT_TEST_ANALYZER"
    let analyzer := (← IO.getEnv overrideName).map FilePath.mk |>.getD run.application
    let exitCode ←
      withPhase "exact_child" <|
          run.spawnChild
            { cmd := analyzer.toString
              -- The trailing capture token encodes the demanded semantic capabilities: "0" none, "1" the
              -- two semantic diagnostics, "2" diagnostics plus the info-tree occurrence fold. A direct
              -- three-argument invocation (every syntax-only harness) omits it and captures nothing.
              -- `occurrences` is only ever demanded together with the tier, so the token is a simple ladder.
              -- A leading "c" prefixes any of those forms and says the parent holds evidence that these
              -- exact bytes compiled, which is what lets the child skip elaborating declarations; it is a
              -- prefix rather than a suffix so that "4j<json>" keeps its payload at a fixed offset.
              -- "4s<json>" is "4j" under `--no-validate`: the child admits on the structural
              -- candidate reparse alone, and only over an admitted frontier.
              -- The two paths after it are the pipe-free transport: the child writes its envelope to the
              -- first and any failure diagnostic to the second (see `spawnChild` for what the pipes cost).
              args :=
                #["__analyze-exact", setupPath.toString, sourcePath.toString,
                  snapshot.path.toString,
                  (if compiled then "c" else "") ++
                    match format? with
                    | some format =>
                      -- "4j" is the exact candidate validation; "4s" is `--no-validate`'s
                      -- structural-reparse-only admission, valid only over an admitted
                      -- frontier (the child falls back to the exact path without one).
                      let tag := if validationPolicy == .structural then "4s" else "4j"
                      s!"{tag}{(Lean.toJson format).compress}"
                    | none =>
                      if captureOccurrences then "2" else if captureSemantic then "1" else "0",
                  outPath.toString, errPath.toString]
              -- The parallelism that matters is here, one process per file, and `resolveWorkers`
              -- picks its degree the way Lake picks its own. The child's pool is not a second
              -- ration of the machine to spend — `childThreads` explains what it is and why it
              -- costs nothing — but it must never be the inherited `LEAN_NUM_THREADS`, which for
              -- this product names the worker count instead.
              env :=
                run.project.workspace.augmentedEnvVars.push
                    ⟨"LEAN_NUM_THREADS", some (toString threads)⟩ |>.push
                  ⟨"LEAN_FMT_PROFILE_OUT", some errPath.toString⟩ }
            cancel?
    let errText ←
      if ← errPath.pathExists then
        IO.FS.readFile errPath
      else
        pure ""
    unless exitCode == 0 do
      throw <|
          IO.userError
            s!"exact frontend child failed for {snapshot.relativePath}: \
        {errText.trimAscii}"
    -- The child's own records ride back on the err file, which the child appends to when the
    -- profile channel is on (`LEAN_FMT_PROFILE_OUT`). Forwarding them here makes the
    -- elaboration/encode split visible from a parent profile; without it the child's internal
    -- cost is a single opaque `exact_child`. The counts come too: whether the candidate was
    -- reparsed or escalated to a second frontend is decided in the child and is invisible from
    -- outside it.
    if ← Profile.enabled then
      for line in errText.splitOn "\n"do
        if line.startsWith "phase." || line.startsWith "cache." then
          IO.eprintln line
    let envelope ←
      withPhase "envelope_decode" do
          unless ← outPath.pathExists do
            throw <|
                IO.userError
                  s!"exact frontend child produced no envelope for \
          {snapshot.relativePath}"
          let .ok json := Lean.Json.parse (← IO.FS.readFile outPath) |
            throw <|
                IO.userError
                  s!"exact frontend child returned invalid JSON for \
          {snapshot.relativePath}"
          match Lean.fromJson? json with
          | .ok envelope =>
            pure (envelope : AnalysisEnvelope)
          | .error error =>
            throw <|
                IO.userError
                  s!"exact frontend child returned an invalid result \
          for {snapshot.relativePath}: {error}"
    if let .error setupError := setupResult then
      if envelope.artifact?.isSome then
        throw <|
            IO.userError
              s!"could not establish the exact Lake setup for \
          {snapshot.relativePath}: {setupError}"
    return envelope
  finally
    if ← setupPath.pathExists then
      IO.FS.removeFile setupPath
    if ← sourcePath.pathExists then
      IO.FS.removeFile sourcePath
    if ← outPath.pathExists then
      IO.FS.removeFile outPath
    if ← errPath.pathExists then
      IO.FS.removeFile errPath

/- The frontend-native document emits groups, nesting, and line choices, and its linear renderer
breaks them against the effective `[format] line-width`. Because a runtime width changes canonical
bytes without changing the executable, `Project.configurationIdentity` folds the resolved value into
cache identity. The default is 100. -/

/-! ## Range formatting — unit selection over the layout source map

Everything below is pure and works on one whole-file render plus its
source map: the bytes emitted for a selected unit are **the bytes whole-file `format` produced for
it**, spliced out, never a separate rendering of a slice. So "never slice arbitrary bytes and parse
them as an exact module" is unreachable here — nothing here parses. -/

/-- Byte `stop - 1` of `text`, or `none` when the range is empty or out of bounds. -/
private def byteBefore? (bytes : ByteArray) (stop : Nat) : Option UInt8 :=
  if stop == 0 || stop > bytes.size then none else bytes[stop - 1]?

/-- Does this unit's *rendered* output end at a line boundary?

This is the reflow-stability test, and it asks about the **output** rather than the source because
`Doc.fits` walks the tail of the work list: a unit whose rendering ends in a break (`hard`, a
broken `line`, or a newline-bearing `verbatim` — `Doc.lean:174-188`) stops that walk, so nothing
after it can re-decide its layout. Measured:
a unit that is *not* so terminated is rebroken by a one-character tail. -/
private def unitEndsAtLineBoundary (rendered : ByteArray) (mark : Mark) : Bool :=
  byteBefore? rendered mark.output.stop == some 10 -- '\n'

/-- The inclusive index run of layout units a request expands to, or `none` when there are no units.

The three steps:

1. every unit the request intersects — the units tile the source gap-free, so this is a contiguous run;
2. an **empty** request selects the single unit containing its offset, the one starting there if it
   sits exactly on a boundary, and the last unit when it is at end of file;
3. **extend forward while the last selected unit does not end at a line boundary.** Step 3 is why a
   range surface can promise anything about the text outside it. Without it, `def a := 1 def b := 2`
   lets a request rewrite the first command with bytes whose layout was decided by the second — so
   re-running the formatter would move them again, and the reported actual range would have been
   wrong. It terminates because extension stops at the final unit even when the source deliberately
   has no final newline. -/
private def selectUnits (rendered : ByteArray) (marks : Array Mark) (requested : SourceRange) :
    Option (Nat × Nat) :=
  Id.run do
    if marks.isEmpty then
      return none
    let final := marks.size - 1
    -- Step 1/2: the first unit whose extent reaches past the request start.
    let mut first := final
    for index in [0:marks.size]do
      if marks[index]!.source.stop > requested.start then
        first := index
        break
    let mut last := first
    if requested.stop > requested.start then
      for index in [0:marks.size]do
        if marks[index]!.source.start < requested.stop then
          last := max last index
    -- Step 3.
    while last < final && !unitEndsAtLineBoundary rendered marks[last]! do
      last := last + 1
    return some (first, last)

/-- One range request's answer: the spliced text and the range it actually formatted. -/
structure RangeResult where
  /-- Normalized text: the source outside the actual range, with the rendered units inside it. -/
  text : String
  requested : SourceRange
  /-- The hull of the selected units. **May span lines the caller did not edit** — a stated
  consequence of reflow, from `selectUnits` step 3. -/
  actual : SourceRange
  /-- The selected units' source-map entries, `output` re-based onto `text`. -/
  marks : Array Mark

/-- Splice one whole-file render down to the units a request expands to.

`normalized` and `rendered` are the same file before and after layout; `marks` is the source map
the admitted frontend-native layout produced. The result is

    normalized[0, actual.start)  ++  rendered[out.start, out.stop)  ++  normalized[actual.stop, end)

so every byte outside the actual range is the caller's own, unmoved. Selecting every unit reproduces
`rendered` exactly, the whole-file/full-range equivalence. The whitespace prefix
of the next unit is part of the preceding boundary: include it without including the next unit's
first token, so formatting a scope opener can establish the following unit's vertical separation
and owner-relative indentation through a narrow edit. The LSP range test covers both
cases. -/
def sliceRange (normalized rendered : String) (marks : Array Mark) (requested : SourceRange) :
    Option RangeResult :=
  Id.run do
    let renderedBytes := rendered.toUTF8
    let some (first, last) := selectUnits renderedBytes marks requested | return none
    let actual : SourceRange := ⟨marks[first]!.source.start, marks[last]!.source.stop⟩
    let outputStop :=
      Id.run do
        let mut stop := marks[last]!.output.stop
        if let some next := marks[last + 1]? then
          if next.output.start == stop then
            while
              stop < next.output.stop &&
                (renderedBytes[stop]! == 0x20 || renderedBytes[stop]! == 0x09 ||
                  renderedBytes[stop]! == 0x0a ||
                  renderedBytes[stop]! == 0x0d) do
              stop := stop + 1
        return stop
    let output : SourceRange := ⟨marks[first]!.output.start, outputStop⟩
    let normalizedBytes := normalized.toUTF8
    let slice (bytes : ByteArray) (range : SourceRange) : String :=
      (String.fromUTF8? (bytes.extract range.start range.stop)).getD ""
    let before := slice normalizedBytes ⟨0, actual.start⟩
    let body := slice renderedBytes output
    let after := slice normalizedBytes ⟨actual.stop, normalizedBytes.size⟩
    -- Output offsets are re-based onto the spliced text: the body starts where `before` ends.
    let shift := before.utf8ByteSize
    let selectedMarks := marks.extract first (last + 1)
    let selected :=
      selectedMarks.mapIdx fun index mark =>
        let stop := if index + 1 == selectedMarks.size then output.stop else mark.output.stop
        { mark with
          output := ⟨mark.output.start - output.start + shift, stop - output.start + shift⟩ }
    return some { text := before ++ body ++ after, requested, actual, marks := selected }

/-- What a user is told when lean-fmt cannot finish a file through no fault of their code.

Every branch that reaches this left the file untouched, so the message leads with that, says
plainly whose defect it is, and gives the one action available. `technical` is the single
implementation clause; it goes last and is labelled as report material, because it is written for
whoever fixes the bug rather than for the person reading the terminal. Before this existed the
whole message was that clause, including a mangled private constructor name. -/
private def internalFailure (technical : String) : String :=
  s!"lean-fmt hit a problem it could not work around, so this file was left unchanged. Your code \
    is fine — this is a defect in lean-fmt, not in what you wrote. Please report it at \
    https://github.com/jcreinhold/lean-fmt/issues and attach this file if you can. Include this \
    line in the report: {technical}"

private def canonicalAnalysis (snapshot : SourceSnapshot) (renderCanonical : Bool)
    (analysis : AnalysisEnvelope) : IO SemanticAnalysis := do
  match
    SemanticAnalysis.ofArtifact snapshot.source snapshot.config.format.lineWidth analysis.artifact?
      analysis.diagnostics with
  | .ok semantic =>
    if semantic.result?.isNone then
      return semantic
    if renderCanonical then
      match analysis.canonical?, analysis.validationFailure? with
      | some layout, none =>
        recordCount "path_exact_render" 1
        return semantic.withCanonical layout
      | none, some failure =>
        recordCount "path_validation_failure" 1
        let clause := s!"the check on {failure.gate.describe} did not pass ({failure.detail})"
        throw <| IO.userError (internalFailure clause)
      | _, _ =>
        recordCount "path_validation_failure" 1
        throw <| IO.userError (internalFailure "no layout was produced")
    return semantic
  | .error reason =>
    -- A file this projection cannot hold is one file's outcome, not the run's. Everything else
    -- here means the child and the source disagree, which is the run's problem.
    if reason.startsWith unrepresentablePrefix then
      return .broken #[reason]
    throw <| IO.userError (internalFailure reason)

/-- Analyze one snapshot: build the exact envelope the plan demanded and project it, rendering canonical
layout when `renderCanonical`.

Every finding — source, syntax, and the owned `.semantic` FMT012 rename — is computed once, on the
**original** projection (`canonicalAnalysis` → `ofArtifact?`), at the file's own coordinates, and
`fix` applies it there. The retired `reprojectCanonical` re-ran the whole
registry over the *rendered* text so a fix could land in canonical coordinates: with the layout/fix
split, no fix is computed or applied at canonical coordinates, so there is nothing to re-project.
`captureOccurrences` still gates the info-tree fold that supplies FMT012's occurrence at original
coordinates (the walk already runs here for diagnostics); `captureSemantic` and `validator` are
unchanged. -/
def ExactRun.analyzeSnapshot (run : ExactRun) (snapshot : SourceSnapshot) (renderCanonical : Bool)
    (validator := false) (captureSemantic : Bool := false) (captureOccurrences : Bool := false)
    (cancel? : Option Std.CancellationToken := none) (compiled : Bool := false)
    (validationPolicy : ValidationPolicy := .exact) : IO SemanticAnalysis := do
  canonicalAnalysis snapshot renderCanonical
      (←
        run.envelope snapshot captureSemantic validator captureOccurrences (format? :=
            if renderCanonical then some snapshot.config.format else none) (cancel? := cancel?)
            (compiled := compiled) (validationPolicy := validationPolicy))

/- Bracket a complete exact-analysis run. The capability is constructed only after a real fallback
or editor request needs it; cache-only and ordinary-evidence batch runs create no temporary state.

Above one, `workers` creates the child registry. Nothing polls it to enforce anything; the run
counts its children and cleans up after them, and that is all. -/
def withExactRun (project : Project.Snapshot) (workers : Nat := 1) (action : ExactRun → IO α) :
    IO α := do
  let temporary ← IO.FS.createTempDir
  let nextIndex ← IO.mkRef 0
  let setups ← IO.mkRef { }
  let documentSetups ← IO.mkRef { }
  let registry? ←
    if workers > 1 then
      some <$> IO.mkRef #[]
    else
      pure none
  let run : ExactRun :=
    { project
      application := ← IO.appPath
      temporary
      workers
      registry?
      nextIndex
      setups
      documentSetups
      lake := ← Std.Mutex.new () }
  -- Test-only (`LEAN_FMT_TEST_FD_REPORT`): bracket the run with this process's open-descriptor
  -- count, so a scale suite can assert a batch leaves no per-target descriptors behind. Counted
  -- from `/dev/fd`, which macOS and Linux both provide; off this channel nothing is read.
  let reportFds := (← IO.getEnv "LEAN_FMT_TEST_FD_REPORT") == some "1"
  if reportFds then
    IO.eprintln s!"test.fds_open_start={(← ("/dev/fd" : FilePath).readDir).size}"
  try
    action run
  finally
    if reportFds then
      IO.eprintln s!"test.fds_open_end={(← ("/dev/fd" : FilePath).readDir).size}"
    IO.FS.removeDirAll temporary

/-- Does an analysis in hand answer what this run demands? Asked of a cache hit and of an analysis
just projected from a module artifact — the same question, so it must have one answer.

This *is* `Cache.Decision.Provided.meets`, the function `LeanFmt.Cache.Spec` proves `demand_met`
about. It used to be a separate reimplementation here, and the model knew nothing of two of its
three clauses — so `serves_complete` was proved about a decision more permissive than the one
running. The clauses are documented on `Provided.meets` itself, next to the definition.

The other half, `Entry.identityCurrent`, runs in `LeanFmt.Cache`, which is where digests can be
observed. `Cache.Decision.serves` is their conjunction and is the whole cache decision. -/
private def analysisServes (requiredTier : Tier) (demandedCaps : SemanticCaps)
    (renderCanonical : Bool) (analysis : SemanticAnalysis) : Bool :=
  (providedOf analysis).meets
    { tier := requiredTier, caps := demandedCaps, renderCanonical := renderCanonical }

private def availableAnalysis (plan : RulePlan) (renderCanonical applies : Bool)
    (evidence : Project.ModuleEvidence) (snapshot : SourceSnapshot)
    (cached? : Option SemanticAnalysis) (officialArtifact? : Option ModuleArtifact) :
    IO (Option SemanticAnalysis) := do
  let demandedCaps := plan.demandedCaps applies
  if let some analysis := cached? then
    if analysisServes plan.requiredTier demandedCaps renderCanonical analysis then
      return some analysis
  if
      plan.requiredTier == .source && !renderCanonical && evidence == .current &&
        !Suppression.mayContainDirective snapshot.source then
    -- Source rules index the normalized string, so this shortcut and the artifact path produce
    -- findings in one coordinate system and remain interchangeable in the result cache. They are
    -- also now the same call: `runRules` folds over the one registry either way, so this path can
    -- no longer decide a rule differently from the artifact path. It used to, by passing a literal
    -- `true` where the artifact path passed the artifact's own flag.
    -- Gated on `renderCanonical` because it takes no artifact, and canonical text cannot be
    -- rendered without the projection an artifact carries. `check` and
    -- `fix` both reach it on a source-only selection: `fix` no longer renders, so a
    -- `fix --select FMT003` takes the shortcut and applies the dedup at original coordinates
    -- without a frontend run. Also gated on the absence of a directive sigil: suppression is parsed
    -- only from the syntax projection (`ofArtifact?`), so a directive-bearing file must take the
    -- artifact path even when its selected rules are all source-tier — otherwise its
    -- `SuppressionFacts` would default empty and the directive silently do nothing.
    -- `mayContainDirective` is a superset test, so this over-fetches only on files that mention the
    -- sigil without a valid directive, never under-fetches.
    let normalized := (LosslessSource.normalize snapshot.source).1
    recordCount "path_source_shortcut" 1
    return some <|
        SemanticAnalysis.success normalized
          (runSourceRules normalized snapshot.config.format.lineWidth)
  else if renderCanonical then
    return none
  else if let some artifact := officialArtifact? then
    -- A non-rendering syntax/semantic run with a current artifact — `check`/`fix --select FMT01x` — is
    -- served here from the plugin projection, no frontend run. There is
    -- no longer a syntax branch that declines here to force an `ExactRun` re-projection: it retired
    -- with `reprojectCanonical` (no fix is computed at canonical coordinates), so a syntax
    -- `--select` costs one artifact read, never a second frontend pass. A rendering run declines
    -- above (`renderCanonical`) and elaborates the source: the artifact carries a projection, not a
    -- layout, and rendering it under one post-import environment measured both slower and wrong.
    --
    -- The projection is checked against the demand by the same predicate a cache hit answers to.
    -- A build-produced artifact carries no compiler diagnostics, so it projects at `.syntax`; when
    -- it went unchecked a `--select FMT012` on a module with a current facet reported **clean**
    -- while the same selection with `LEAN_FMT_DISABLE_ARTIFACT=1` reported the deprecation.
    -- `runRules` drops every semantic rule when the facts are `.syntax` (`Rules.lean`), so the
    -- silence was total and nothing downstream could notice.
    let analysis ← canonicalAnalysis snapshot renderCanonical { artifact? := some artifact }
    if analysisServes plan.requiredTier demandedCaps renderCanonical analysis then
      return some analysis
    recordCount "artifact_tier_miss" 1
    return none
  else
    return none

private structure DiffSource where
  lines : List String
  finalNewline : Bool

private def diffSource (source : String) : DiffSource :=
  if source.isEmpty then { lines := [], finalNewline := false }
  else
    let finalNewline := source.endsWith "\n"
    let pieces := source.splitOn "\n"
    { lines := if finalNewline then pieces.dropLast else pieces, finalNewline }

/-- A line, paired with whether the file ends right here with no terminating newline.

The flag is part of the line's **identity**, not decoration, which is why this type exists.
`diffSource` reads the terminator into `finalNewline` and drops it from `lines`, so `"a\n"` and `"a"`
both project to `["a"]`. A diff over bare strings would pair them as unchanged and print nothing —
for the one edit the retired final-newline rule existed to make. Carrying the flag into the compared
element makes those two lines unequal, so the edit appears. It also places the `\ No newline` marker
correctly: the marker belongs to whichever side holds the flag. -/
private abbrev DiffLine :=
  String × Bool

private def diffLines (source : DiffSource) : Array DiffLine :=
  let lines := source.lines.toArray
  lines.mapIdx fun index line => (line, !source.finalNewline && index + 1 == lines.size)

/-- Lines of unchanged context around each change, as `diff -U3` and every review tool default to. -/
private def diffContext : Nat :=
  3

/-- Render an edit script as unified diff.

`Lean.Diff.diff` (`Lean/Util/Diff.lean:170`) supplies the edit script — a histogram diff, the
family `git diff --histogram` uses. Only the hunking is ours: core's `linesToString` (`:201`) prints
the whole script with `-`/`+`/` ` markers and no `@@` headers, which is not a format any tool
consumes.

This replaced a `unifiedDiff` that was not a diff: it emitted every old line as `-` and every new
line as `+` under one synthesized header, having never looked for a common line. Correct output —
applying it reproduces the file — and useless, because a one-line change reprinted the file. It only
ever ran on the retired trailing-whitespace / final-newline fixes, so it was tolerable; now `diff`
points at canonical layout and is the surface on which formatting is reviewed, where a
whole-file rewrite defeats the mode's only purpose. -/
private def unifiedDiff (path before after : String) : String :=
  Id.run do
    let old := diffLines (diffSource before)
    let new := diffLines (diffSource after)
    let script := Lean.Diff.diff old new
    -- How many lines of each side precede entry `i`. Line numbers in a hunk header are counted,
    -- not searched for: an entry absent from one side still has a position *in* that side, the count
    -- of what came before it.
    let mut oldBefore : Array Nat := Array.emptyWithCapacity script.size
    let mut newBefore : Array Nat := Array.emptyWithCapacity script.size
    let mut oldSeen := 0
    let mut newSeen := 0
    for (action, _) in script do
      oldBefore := oldBefore.push oldSeen
      newBefore := newBefore.push newSeen
      match action with
      | .skip =>
        oldSeen := oldSeen + 1;
        newSeen := newSeen + 1
      | .delete =>
        oldSeen := oldSeen + 1
      | .insert =>
        newSeen := newSeen + 1
    -- Windows of `diffContext` around every change, merged where they touch. Two changes closer than
    -- `2 * diffContext` share a hunk rather than repeating the context between them.
    let mut ranges : Array (Nat × Nat) := #[]
    for index in [0:script.size]do
      if script[index]!.1 != .skip then
        let start := index - min index diffContext
        let stop := min (script.size - 1) (index + diffContext)
        match ranges.back? with
        | some (previousStart, previousStop) =>
          if start ≤ previousStop + 1 then
            ranges := ranges.pop.push (previousStart, max previousStop stop)
          else
            ranges := ranges.push (start, stop)
        | none =>
          ranges := ranges.push (start, stop)
    let mut out := s!"--- a/{path}\n+++ b/{path}\n"
    for (start, stop) in ranges do
      let mut oldCount := 0
      let mut newCount := 0
      for index in [start:stop + 1]do
        match script[index]!.1 with
        | .skip =>
          oldCount := oldCount + 1;
          newCount := newCount + 1
        | .delete =>
          oldCount := oldCount + 1
        | .insert =>
          newCount := newCount + 1
      -- A hunk covering none of a side starts *at* the line it sits before, not one past it: a pure
      -- insertion into an empty file is `-0,0`, which is what every diff consumer expects to read.
      let oldStart := if oldCount == 0 then oldBefore[start]! else oldBefore[start]! + 1
      let newStart := if newCount == 0 then newBefore[start]! else newBefore[start]! + 1
      out := out ++ s!"@@ -{oldStart},{oldCount} +{newStart},{newCount} @@\n"
      for index in [start:stop + 1]do
        let (action, line, endsWithoutNewline) := script[index]!
        out := out ++ action.linePrefix ++ line ++ "\n"
        if endsWithoutNewline then
          out := out ++ "\\ No newline at end of file\n"
    return out

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
  let candidates : Array (String × Array String) :=
    #[("/usr/bin/stat", #["-f", "%Lp", path.toString]), ("stat", #["-c", "%a", path.toString])]
  for (command, arguments) in candidates do
    try
      let output ← IO.Process.output { cmd := command, args := arguments }
      if output.exitCode == 0 then
        if let some mode := parseOctal? output.stdout.trimAscii.copy then
          return mode
    catch _ =>
      pure ()
  throw <| IO.userError s!"could not read source permissions: {path}"

private def publicationTemp (path : FilePath) : IO FilePath := do
  let pid ← IO.Process.getPID
  let nonce ← IO.monoNanosNow
  return FilePath.mk s!"{path}.lean-fmt-tmp-{pid}-{nonce}"

private def runBeforeWriteHook (path : FilePath) : IO Unit := do
  if let some command← IO.getEnv "LEAN_FMT_TEST_BEFORE_WRITE" then
    let output ← IO.Process.output { cmd := command, args := #[path.toString] }
    unless output.exitCode == 0 do
      throw <| IO.userError "test before-write hook failed"

private def publishAtomic (path : FilePath) (original output : String) : IO (Except String Unit) :=
  do
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

/- Findings index the normalized source, so edits are prepared against it and the result is returned
to the file's own line-ending form on the way out. Preparing edits against the raw bytes would place
every edit past its intended offset in a CRLF file. -/
private structure PreparedFile where
  findings : Array Finding
  normalized : String
  lineEndings : LineEndings
  patch : Patch
  /-- Reported findings whose fix is unsafe and was not admitted into `patch` (opt-in was off):
  what `--unsafe-fixes` would additionally apply. -/
  withheldUnsafe : Nat
  /-- How many config-selected findings a source directive suppressed. -/
  suppressed : Nat
  /-- FMT004 candidates withheld by exposure-changing modifiers (see `FileReport.withheldRedundant`). -/
  withheldRedundant : Nat

/-- The formatted text in the file's own line-ending form, i.e. what a write would produce. -/
private def PreparedFile.output (prepared : PreparedFile) : String :=
  LosslessSource.denormalize prepared.patch.formatted prepared.lineEndings

/-- Whether publishing this would alter the file.

**Not `patch.changed`.** That asks whether the patch carries fix edits, which was the same
question only while the patch was based on the file's own bytes. Based on canonical text it is a
different question and the wrong one: a file needing layout but no fixes has an empty edit set, so
`patch.changed` is `false` while the output differs on every line. Comparing the output to the
source is the question all three callers actually meant. -/
private def PreparedFile.changed (prepared : PreparedFile) : Bool :=
  prepared.patch.formatted != prepared.normalized

/-- Order findings by position, then code, so a report is deterministic regardless of which layer
produced a finding (a rule, or the suppression projection's `FMT900`/`FMT901`). -/
private def reportOrder (left right : Finding) : Bool :=
  if left.range.start != right.range.start then left.range.start < right.range.start
  else
    if left.range.stop != right.range.stop then left.range.stop < right.range.stop
    else left.code < right.code

/-- Project the source-suppression layer over the config-selected findings.

Applied **after** `plan.findings` (config selection), so unused is computed against the
config-selected set. Returns the reported findings — survivors plus the
`FMT900` unused and `FMT901` malformed self-diagnostics, which are *not* themselves suppressible and
bypass config selection (formatter self-diagnostics, always on in v1) — and the suppressed count.

Directive scopes index the normalized source, so this projection is exact for the **report**, which
the user reads against their own unmoved bytes. Suppression shapes only the report; it never touches
a patch. `prepareFile` builds its patch from the config-selected findings, suppression-free, and
`FMT900`/`FMT901` (report-only, not suppressible) never enter one — keeping `check`'s report patch
and `fix`'s applied patch in agreement: both index the same normalized
bytes the directive scopes do, so no scope ever maps onto reflowed canonical offsets. An editor may
still apply an `FMT900` removal from the report; batch `fix` does not. -/
private def projectSuppression (result : SemanticResult) (bytes : ByteArray)
    (selected : Array Finding) : Array Finding × Nat :=
  let outcome := Suppression.apply result.suppression bytes selected
  let reported := (outcome.kept ++ result.suppression.malformed ++ outcome.unused).qsort reportOrder
  (reported, outcome.suppressed)

/-! ## Import findings — computed fresh in IO, merged pre-selection

The import family (FMT003/04/05) is not in the `RuleImpl` engine, so it is not stored in the
cached `SemanticResult`. FMT003/05 are pure over the file's own header, but FMT004 depends on
*other* files through the Lake graph, so **none** of it enters the source-digest result cache —
caching a graph fact under a single file's digest would serve a stale answer the moment an
unrelated import changed. Import findings are recomputed every run here and merged into the report
before selection (`plan.findings`), so `--select imports`, per-file ignores, and suppression all
apply to them uniformly. -/

private def anyImportSelected (plan : RulePlan) : Bool :=
  importRuleInfos.any (plan.selected.contains ·.code)

/-- The import findings for one already-parsed header at `normalized`'s coordinates, plus the
withheld-redundant count. Each rule is gated on selection so an unselected FMT004 never consults the
graph closure. Pure — the caller did the IO (header parse, closure fetch). -/
private def importFindingsOfHeader (plan : RulePlan) (format : FormatConfig)
    (covers : Lean.Name → Lean.Name → Bool) (header : Imports.HeaderModel) (normalized : String) :
    Array Finding × Nat :=
  Id.run do
    let mut findings : Array Finding := #[]
    let mut withheld := 0
    if plan.selected.contains "FMT003" then
      findings := findings ++ Imports.duplicateFindings header normalized
    if plan.selected.contains "FMT005" then
      findings :=
        findings ++ Imports.orderFindings header normalized format.importLayout format.importGroups
    if plan.selected.contains "FMT004" then
      let (redundant, w) := Imports.redundantFindings header covers
      findings := findings ++ redundant
      withheld := w
    return (findings, withheld)

/-- The distinct written import module names of `header`, the keys FMT004's closure fetch needs. -/
private def headerImportNames (header : Imports.HeaderModel) : Array Lean.Name :=
  header.imports.foldl (init := #[]) fun acc stmt =>
    if acc.contains stmt.module then acc else acc.push stmt.module

/-- Build a closure lookup for `names` (empty unless FMT004 is selected), then compute one file's
import report. Used by the single-file editor path; the batch `execute` path shares one closure fetch
across all files instead (`computeImportReports`). -/
private def singleImportReport (plan : RulePlan) (workspace : Lake.Workspace) (normalized : String)
    (format : FormatConfig) : IO (Array Finding × Nat) := do
  unless anyImportSelected plan do
    return (#[], 0)
  match ← Imports.parseHeaderModel normalized with
  | none =>
    return (#[], 0)
  | some header =>
    let covers : Lean.Name → Lean.Name → Bool ←
      if plan.selected.contains "FMT004" then
        let facts ← Project.graph workspace #[] (headerImportNames header) { closures := true }
        pure fun outer inner => (facts.imports[outer]?.map (·.sees inner)).getD false
      else
        pure fun _ _ => false
    return importFindingsOfHeader plan format covers header normalized

/-- Compute every target's import report in one pass: parse all headers, ask for the union of their
import closures (FMT004 only), then project per file. Returns one `(findings, withheldRedundant)`
per snapshot, aligned with `snapshots`.

It takes the snapshot rather than the workspace so the closures come from
`Project.Snapshot.importClosures`, which the cache's currency check also asks. Whichever runs first
traverses; the second reads the memo. -/
private def computeImportReports (plans : Array RulePlan) (project : Project.Snapshot)
    (snapshots : Array SourceSnapshot) : IO (Array (Array Finding × Nat)) := do
  -- Per-file plans, because the effective configuration is per file: two files in one run
  -- can disagree about whether an import rule is selected. The shared closure fetch still happens once
  -- for the whole batch — it is keyed on whether *any* file wants FMT004, never on each file's answer.
  unless plans.any anyImportSelected do
    return Array.replicate snapshots.size (#[], 0)
  let headers ←
    snapshots.mapM fun snapshot => do
        let (normalized, _) := LosslessSource.normalize snapshot.source
        return (normalized, ← Imports.parseHeaderModel normalized)
  let covers : Lean.Name → Lean.Name → Bool ←
    if plans.any (·.selected.contains "FMT004") then
      let names :=
        headers.foldl (init := #[]) fun acc (_, header?) =>
          match header? with
          | some header =>
            (headerImportNames header).foldl (init := acc) fun acc name =>
              if acc.contains name then acc else acc.push name
          | none => acc
      let imports ← project.importClosures names
      pure fun outer inner => (imports.closures[outer]?.map (·.sees inner)).getD false
    else
      pure fun _ _ => false
  return (headers.zip (plans.zip snapshots)).map fun ((normalized, header?), plan, snapshot) =>
      match header? with
      | none => (#[], 0)
      | some header => importFindingsOfHeader plan snapshot.config.format covers header normalized

/-- The fix this product would actually apply for a finding, or `none`.

Two independent conditions, both easy to forget. The rule must be *fix*-selected — the
`fixable`/`unfixable` axis, not the same axis as being reported — and the fix's
effective applicability must be admitted under this run's `--unsafe-fixes`.

Named because it has more than one caller and they must not drift: `prepareFile` decides which
edits a write publishes, and the language server decides which code actions it offers. An editor
offering a quickfix the command line would refuse is the same defect as an editor reporting a
finding the command line does not — a second answer for the same bytes. -/
def admittedFix? (plan : RulePlan) (unsafeFixes : Bool) (finding : Finding) : Option Fix := do
  let fix ← finding.fix?
  guard <| plan.fixableSelected.contains finding.code && fix.applicability.admitted unsafeFixes
  return fix

/-- Project one analysis into the edits a preview or write would apply — one of two independent
patches, keyed on `renderCanonical`:

- **Layout patch** (`format`/`diff`, `renderCanonical`). `base := canonical.text`, the reflowed
  bytes, and the patch carries **no** rule fix. The render is the whole answer: `format` publishes
  `output` in place (`formatFile`; `format --check` previews it), `diff` diffs
  `normalized` against it. A rule fix belongs to `fix`, never layout.
- **Fix patch** (`fix`; `check` computes it for the report). `base := normalized`, the file's own
  bytes, and the patch carries the admitted fixes from `selected` at **original** coordinates.
  `fix` validates and publishes it; it does not reflow. Because layout and fix never share a
  coordinate system here, the old gap — canonicalizing `namespace     Alpha` deletes four
  bytes — can no longer move a fix off the bytes it was reported against.

The report (`findings`) is `result.findings` (joined with `reportImports`) at original coordinates
in every mode, independent of which patch is built — it is what the user, whose file has not moved,
sees.

**Applicability gates the patch, not the report.** Every finding with a fix is reported (with its
effective applicability, already resolved by `plan.findings`), but only the *admitted* fixes enter
the patch: a non-admitted fix is stripped to `none` before `preparePatch`, which then only ever
assembles edits that will actually be published. Admission is `Applicability.admitted unsafeFixes`,
the one rule `fix` and its `check` preview share, so a preview shows what a write would do. -/
private def prepareFile (plan : RulePlan) (renderCanonical unsafeFixes : Bool)
    (reportImports : Array Finding) (withheldRedundant : Nat) (snapshot : SourceSnapshot)
    (analysis : SemanticAnalysis) : Except FileReport PreparedFile := do
  let some result := analysis.result? |
    throw
        (baseReport snapshot
          (if (unbuiltDependency? analysis.diagnostics).isSome then "unbuilt"
          else
            if (unrepresentableProjection? analysis.diagnostics).isSome then "rejected"
            else "broken")
          #[] analysis.diagnostics)
  let (normalized, lineEndings) := LosslessSource.normalize snapshot.source
  -- Import findings (`reportImports`, normalized coordinates) join the engine's findings *before*
  -- selection, so `--select imports`, per-file ignores, and suppression treat them like any rule.
  -- FMT003 applies at original coordinates and needs no canonical recomputation: the fix patch
  -- applies it on `normalized`, and the layout patch carries no fix at all.
  let selected := plan.findings snapshot.relativePath (result.findings ++ reportImports)
  let (findings, suppressed) := projectSuppression result normalized.toUTF8 selected
  -- The fix patch is built from the config-selected findings *unaffected by suppression*:
  -- suppression shapes the report (`findings`), never the bytes a write publishes, so a directive
  -- silences a diagnostic without changing output. Feeding the suppression-projected set here would
  -- put the `FMT900`/`FMT901` removal edits into the patch, so `check` would report a change `fix`
  -- never makes; both stay agreed by ignoring the self-diagnostics for the patch.
  let (base, baseFindings) :=
    match (if renderCanonical then result.canonical? else none) with
    -- Layout patch: reflow only, no rule fix. `canonical?` is populated for any rendering run
    -- (`analysisServes`/`availableAnalysis` guarantee it), so a rendering run never falls to the fix arm.
    | some canonical => (canonical.text, (#[] : Array Finding))
    -- Fix patch (`fix`) / report patch (`check`): admitted fixes on the file's own bytes.
    | none => (normalized, selected)
  -- A fix enters the patch only when its rule is fix-selected (`fixable`/`unfixable` axis)
  -- *and* its applicability is admitted. A selected-but-unfixable rule is still reported
  -- (its finding is in `findings`); only the patch drops the fix — the same shape as a withheld
  -- unsafe fix.
  let admitted :=
    baseFindings.map fun finding =>
      if (admittedFix? plan unsafeFixes finding).isSome then finding
      else { finding with fix? := none }
  let patch ←
    match preparePatch base admitted with
    | .ok patch =>
      pure patch
    | .error error =>
      throw (baseReport snapshot "rejected" findings #[toString error])
  -- Counted over reported findings (original coordinates), which are the same rules as
  -- `baseFindings` in the same number, so the coordinate system does not matter to a count.
  let withheldUnsafe :=
    findings.foldl (init := 0) fun total finding =>
      match finding.fix? with
      | some fix =>
        if !fix.applicability.admitted unsafeFixes && fix.applicability == .unsafe then total + 1
        else total
      | none => total
  return { findings, normalized, lineEndings, patch, withheldUnsafe, suppressed, withheldRedundant }

private inductive PreviewMode where
  | check
  | format
  | diff

private def RunMode.preview? : RunMode → Option PreviewMode
  | .check => some .check
  | .format => some .format
  | .diff => some .diff
  | .fix => none

/-- Mirrors `RunMode.rendersCanonical` for the preview subset; `fix` renders and is not a preview. -/
private def PreviewMode.rendersCanonical : PreviewMode → Bool
  | .check => false
  | .format | .diff => true

private def previewFile (mode : PreviewMode) (plan : RulePlan) (unsafeFixes : Bool)
    (reportImports : Array Finding) (withheldRedundant : Nat) (snapshot : SourceSnapshot)
    (analysis : SemanticAnalysis) : IO FileReport := do
  match
    prepareFile plan mode.rendersCanonical unsafeFixes reportImports withheldRedundant snapshot
      analysis with
  | .error report =>
    return report
  | .ok prepared =>
    let findings := prepared.findings
    let withheldUnsafe := prepared.withheldUnsafe
    let suppressed := prepared.suppressed
    let withheldRedundant := prepared.withheldRedundant
    match mode with
    | .check =>
      return {
          (baseReport snapshot (if findings.isEmpty then "clean" else "findings") findings) with
          withheldUnsafe, suppressed, withheldRedundant }
    | .format =>
      if prepared.changed then
        return { (baseReport snapshot "would-format" findings) with
            formatted := some prepared.output, withheldUnsafe, suppressed, withheldRedundant }
      return { (baseReport snapshot "clean" findings) with
          withheldUnsafe, suppressed, withheldRedundant }
    | .diff =>
      if prepared.changed then
        -- Both sides of the diff are normalized: a CRLF file must not read as every line changed.
        return { (baseReport snapshot "would-diff" findings) with
            diff :=
              some (unifiedDiff snapshot.relativePath prepared.normalized prepared.patch.formatted),
            withheldUnsafe, suppressed, withheldRedundant }
      return { (baseReport snapshot "clean" findings) with
          withheldUnsafe, suppressed, withheldRedundant }

private def fixFile (run : ExactRun) (plan : RulePlan) (unsafeFixes : Bool)
    (reportImports : Array Finding) (withheldRedundant : Nat) (snapshot : SourceSnapshot)
    (analysis : SemanticAnalysis) : IO FileReport := do
  -- `fix` does not render: the patch bases on the file's own `normalized`
  -- bytes and applies the admitted fixes from `selected` — FMT003 among them — at original
  -- coordinates. No reflow, no canonical recomputation.
  match
    prepareFile plan (renderCanonical := false) unsafeFixes reportImports withheldRedundant snapshot
      analysis with
  | .error report =>
    return report
  | .ok prepared =>
    let findings := prepared.findings
    let withheldUnsafe := prepared.withheldUnsafe
    let suppressed := prepared.suppressed
    let withheldRedundant := prepared.withheldRedundant
    unless prepared.changed do
      return { (baseReport snapshot "clean" findings) with
          withheldUnsafe, suppressed, withheldRedundant }
    let output := prepared.output
    -- The validator re-elaborates the bytes a write would publish, line endings included. It
    -- renders no canonical text: the question is whether these bytes elaborate, and rendering a
    -- layout for a candidate nothing will print is wasted work.
    let candidate := snapshot.withSource output
    let validation ←
      withPhase "validation" <|
          run.analyzeSnapshot candidate (renderCanonical := false) (validator := true)
    if let some report := validationReport snapshot findings validation then
      return report
    match ← publishAtomic snapshot.path snapshot.source output with
    | .error message =>
      return { (baseReport snapshot "rejected" findings #[message]) with
          withheldUnsafe, suppressed, withheldRedundant }
    | .ok _ =>
      return { (baseReport snapshot "fixed"
            findings) with
          formatted := some output
          written := true
          withheldUnsafe, suppressed, withheldRedundant }

/-- Publish the canonical layout in place — `format`'s default disposition.

Structurally `fixFile` with the *layout* base: renders the layout patch
(`renderCanonical := true`, so `patch.formatted = canonical.text` and the patch carries no rule
fix), short-circuits `clean` when the file already is canonical, and publishes the admitted bytes
through `publishAtomic` — the same guarded path (stale-source check + atomic lossless write) `fix`
and `organize` use. `format` applies no rule fix; those belong to `fix`. Status `formatted` +
`written` mirrors `fix`'s `fixed`; the write bytes are `prepared.output`, denormalized to the
file's own line endings, so a CRLF file stays CRLF.

Publication is per file, the moment this file's candidate is admitted. It used to be deferred
into one all-or-nothing batch at run end, which coupled every target's fate to every other's: one
broken file — and on a 1400-file run, one resource-exhausted child — rejected over a thousand
admitted files, and every output was retained in memory for the whole run. Per-file publication
keeps each file's transaction atomic (temp file, stale-source check, rename) and lets a target's
output die with the target. -/
private def formatFile (plan : RulePlan) (unsafeFixes : Bool) (reportImports : Array Finding)
    (withheldRedundant : Nat) (snapshot : SourceSnapshot) (analysis : SemanticAnalysis) :
    IO FileReport := do
  -- The bypass flag travels with the admitted layout; a file this run published (or found
  -- clean) under `--no-validate` carries it into the run's accounting either way.
  let validationBypassed :=
    match analysis.result?.bind (·.canonical?) with
    | some canonical => if canonical.validation.bypassed then 1 else 0
    | none => 0
  match
    prepareFile plan (renderCanonical := true) unsafeFixes reportImports withheldRedundant snapshot
      analysis with
  | .error report =>
    return report
  | .ok prepared =>
    let findings := prepared.findings
    let withheldUnsafe := prepared.withheldUnsafe
    let suppressed := prepared.suppressed
    let withheldRedundant := prepared.withheldRedundant
    unless prepared.changed do
      return { (baseReport snapshot "clean" findings) with
          withheldUnsafe, suppressed, withheldRedundant, validationBypassed }
    let output := prepared.output
    -- Admission already read these exact normalized bytes back under this setup and found the
    -- same commands, so nothing here re-reads them. What that reading proves is `Validator.admit`'s
    -- business, and on the reparse path it is a parse, not an elaboration — see
    -- `Analysis.reparseCandidate`.
    match ← publishAtomic snapshot.path snapshot.source output with
    | .error message =>
      return { (baseReport snapshot "rejected" findings #[message]) with
          withheldUnsafe, suppressed, withheldRedundant }
    | .ok _ =>
      return { (baseReport snapshot "formatted"
            findings) with
          formatted := some output
          written := true
          withheldUnsafe, suppressed, withheldRedundant, validationBypassed }

def ExactRun.checkSnapshot (run : ExactRun) (plan : RulePlan) (snapshot : SourceSnapshot) :
    IO FileReport := do
  let analysis ← run.analyzeSnapshot snapshot (renderCanonical := false)
  -- The editor `check` path never applies fixes, so opt-in is irrelevant to its output; it
  -- reports every finding's applicability and withholds nothing itself. It computes its own
  -- single-file import report (batch runs share one closure fetch via `computeImportReports`).
  let (normalized, _) := LosslessSource.normalize snapshot.source
  let (reportImports, withheldRedundant) ←
    singleImportReport plan run.project.workspace normalized snapshot.config.format
  previewFile .check plan (unsafeFixes := false) reportImports withheldRedundant snapshot analysis

private def summarize (modeString : String) (files : Array FileReport)
    (failures : Array String := #[]) : RunReport :=
  let findings := files.foldl (fun total file => total + file.findings.size) 0
  let changed :=
    files.foldl
      (fun total file =>
        if
            file.status == "findings" || file.status == "would-format" ||
              file.status == "would-diff" ||
              file.status == "fixed" ||
              file.status == "formatted" ||
              file.status == "would-organize" ||
              file.status == "organized" then
          total + 1
        else total)
      0
  let written := files.foldl (fun total file => if file.written then total + 1 else total) 0
  let broken :=
    files.foldl (fun total file => if file.status == "broken" then total + 1 else total) 0
  let unbuilt :=
    files.foldl (fun total file => if file.status == "unbuilt" then total + 1 else total) 0
  let rejected :=
    files.foldl (fun total file => if file.status == "rejected" then total + 1 else total) 0
  let withheldUnsafe := files.foldl (fun total file => total + file.withheldUnsafe) 0
  let suppressed := files.foldl (fun total file => total + file.suppressed) 0
  let withheldRedundant := files.foldl (fun total file => total + file.withheldRedundant) 0
  let validationBypassed := files.foldl (fun total file => total + file.validationBypassed) 0
  { mode := modeString, files, findings, changed, written, broken, unbuilt, rejected,
    withheldUnsafe, suppressed, withheldRedundant, validationBypassed,
    infrastructureFailures := failures }

/-! ## Report positions

Every offset in this product is a normalized-source **byte** offset, but a compiler-style line, a
GitHub annotation, a SARIF region, and a JUnit case name all want a line and a column. That
conversion needs the source text, and `RunReport` deliberately does not carry it.

Re-reading each file inside the renderer was rejected: it would put IO inside a renderer that
must stay pure, and — worse — it would race the run itself. `fix` and `format` publish
in place, so by the time a renderer ran, the bytes on disk would be the *rewritten* ones while
every finding still indexes the original coordinates. Every position in the report would be
silently wrong on the runs that changed something.

Adding the positions to `FileReport` was also rejected: that structure is the canonical report and
its derived `ToJson` is a compatibility surface. A
rendering aid does not belong in it.

So execution — which holds the original bytes and nothing else does — resolves only the offsets the
finished report mentions, and hands them to presentation beside the report. Allocation is bounded
by the **number of findings**, not by project size: a clean file contributes nothing, and a file
with one finding stores two positions rather than a line table for its whole source. -/

/-- 1-based line, 1-based **codepoint** column. The same encoding `--range-lines`
(`Cli.offsetOfLineColumn`) uses, so what a caller sends and what a report returns are one encoding. -/
structure Position where
  line : Nat
  column : Nat
  deriving Inhabited, BEq, Repr

/-- Line/column for the normalized byte offsets a report mentions, keyed by report path.

Deliberately not a line table. A consumer can only ask about an offset the report already named, which
keeps this bounded; an offset the report never named has no answer. -/
structure PositionIndex where private mk ::
  private entries : Std.HashMap String (Std.HashMap Nat Position)

/-- The index for a report with no positions to resolve — `organize`, and any caller rendering a
format that needs none. -/
def PositionIndex.empty : PositionIndex :=
  ⟨{ }⟩

def PositionIndex.position? (index : PositionIndex) (path : String) (offset : Nat) :
    Option Position := do
  let file ← index.entries[path]?
  file[offset]?

/-- Resolve a set of normalized byte offsets in one forward pass.

Offsets are sorted so the walk is linear in the source rather than one walk per offset. An
offset past the end clamps to the end, for the same reason `offsetOfLineColumn` clamps — an
end-of-file position is legitimate for a zero-width finding to name, and failing on it would be
worse than pointing at the last character. -/
private def positionsOf (normalized : String) (offsets : Array Nat) : Std.HashMap Nat Position :=
  Id.run do
    let sorted := offsets.qsort (· < ·)
    let bytes := normalized.toUTF8
    let mut resolved : Std.HashMap Nat Position := { }
    let mut index := 0
    let mut offset := 0
    let mut line := 1
    let mut column := 1
    while index < sorted.size do
      let target := sorted[index]!
      if target ≤ offset || offset ≥ bytes.size then
        resolved := resolved.insert target ⟨line, column⟩
        index := index + 1
      else if bytes[offset]! == 10 then
        line := line + 1
        column := 1
        offset := offset + 1
      else
        column := column + 1
        offset := offset + 1
        -- Advance past this codepoint's continuation bytes (0b10xxxxxx), so a column counts
        -- code points and not bytes. The inverse of `Cli.offsetOfLineColumn`'s own inner walk.
        while offset < bytes.size && bytes[offset]! &&& 0xC0 == 0x80 do
          offset := offset + 1
    return resolved

/-- Resolve every finding position in a finished report against the sources the run actually read.

`snapshots` hold the bytes as they were *before* any publication, which is the coordinate system every
finding indexes. Files with no findings are skipped entirely. -/
private def resolvePositions (snapshots : Array SourceSnapshot) (files : Array FileReport) :
    PositionIndex :=
  Id.run do
    let mut entries : Std.HashMap String (Std.HashMap Nat Position) := { }
    for file in files do
      if file.findings.isEmpty then
        continue
      let some snapshot := snapshots.find? (·.relativePath == file.path) | continue
      let offsets := file.findings.flatMap fun finding => #[finding.range.start, finding.range.stop]
      let (normalized, _) := LosslessSource.normalize snapshot.source
      entries := entries.insert file.path (positionsOf normalized offsets)
    return ⟨entries⟩

/-- The index for one buffer whose bytes the caller already holds.

The stdin surface needs this: its source never became a project snapshot, so `resolvePositions`
has nothing to look it up in, and the CLI that decoded the bytes is the only holder. `normalized`
must be the normalized form, since that is what findings index. -/
def PositionIndex.ofSource (path : String) (normalized : String) (findings : Array Finding) :
    PositionIndex :=
  if findings.isEmpty then .empty
  else
    let offsets := findings.flatMap fun finding => #[finding.range.start, finding.range.stop]
    ⟨Std.HashMap.emptyWithCapacity.insert path (positionsOf normalized offsets)⟩

/-- `resolvePositions` under the `positions` phase.

The index's *lookups* were measured and its **build** explicitly left unmeasured —
`report-bench` constructs the index before any clock starts (`LeanFmtTest.lean`). The build is the
one part of rendering that is O(source bytes) rather than O(findings), so it is the part a
pathological source could make expensive, and it had never been timed. This is where.

Lean is strict, so binding the result inside the phase evaluates it inside the phase; nothing here
relies on the caller forcing it. -/
private def profiledPositions (snapshots : Array SourceSnapshot) (files : Array FileReport) :
    IO PositionIndex :=
  withPhase "positions" do
    -- `withPhase "positions" <| pure (resolvePositions ..)` is what stood here, and it measured
    -- nothing: Lean is strict, so the argument to `pure` is evaluated to build the closure *before*
    -- `withPhase` starts its timer. The phase read 0 ms on every workload including a 4 MB file with
    -- its only finding at the last byte, which is what exposed it. Under a `do` the index is built
    -- when the action runs, inside the bracket.
    -- `IO.lazyPure`, not a `let`: Lean's compiler is free to float a pure computation that does not
    -- depend on the action's state out of the closure, and a plain `let` here still read 0 ms. A
    -- thunk is forced when the action runs, which is inside the bracket by construction.
    IO.lazyPure fun _ => resolvePositions snapshots files

/-- What one run produced: the canonical report, and the line/column resolution presentation
needs to render it. Two values rather than one enriched report, because `RunReport` is a
compatibility surface and `PositionIndex` is a rendering aid — folding the second into the first
would put presentation data in the canonical semantic report. -/
structure RunOutcome where
  report : RunReport
  positions : PositionIndex

/-- What one batch target produced, however it produced it. The worker writes this whole value
at the target's index; the fold afterwards is the only place ordering exists, which is what makes
the report byte-identical at any `--workers`. -/
private structure FileOutcome where
  report : FileReport
  analysis? : Option SemanticAnalysis
  failure? : Option String

/-- One target's whole assignment for a worker. This was a four-deep nest of pairs zipped at the
call site, which is a shape that only ever gets deeper. -/
private structure TargetWork where
  snapshot : SourceSnapshot
  /-- Whatever the decisions above already answered this target with, if any. -/
  available? : Option SemanticAnalysis
  importReport : Array Finding × Nat
  plan : RulePlan
  /-- Lake's verdict that this module's build is current: successful-compilation evidence for
  exactly these bytes, and what lets a frontend child skip elaborating declarations. -/
  compiled : Bool

/- The per-target body of the batch loop: obtain the analysis the earlier decisions left
unanswered, then run the mode's rule phase. Extracted so the serial path and the worker pool
execute the same text; every throw becomes the target's `infrastructure-failure`, exactly what the
serial loop's `catch` reported. -/
private def processOneTarget (exactRun : ExactRun) (request : RunRequest) (renderCanonical : Bool)
    (demanded : Tier) (demandedCaps : SemanticCaps) (target : TargetWork) : IO FileOutcome := do
  let { snapshot, available?, importReport := ir, plan, compiled } := target
  try
    -- Anything left unanswered elaborates its source. There used to be a branch here that loaded the
    -- module's `.olean` and rendered from the artifact instead; it was deleted when the candidate
    -- stopped needing a second frontend. On 200 mathlib-importing modules at four workers the
    -- artifact route ran 336.8 s and rejected 12 files with `Unknown constant`; the exact route ran
    -- 279.0 s and rejected 1. It was slower *and* wrong, because it renders every command under one
    -- post-import environment instead of the live per-command one. What the artifact is good at is
    -- above this line: `availableAnalysis` answers a non-rendering `check` from it without any
    -- frontend at all, 12.4 s for the same 200 files.
    let analysis ←
      match available? with
      | some analysis =>
        pure analysis
      | none =>
        exactRun.analyzeSnapshot snapshot renderCanonical (captureSemantic := demanded == .semantic)
            (captureOccurrences := demandedCaps.occurrences) (compiled := compiled)
            (validationPolicy := request.validationPolicy)
    let report ←
      withPhase "rules" <|
          match request.mode with
          | .fix => fixFile exactRun plan request.unsafeFixes ir.1 ir.2 snapshot analysis
          | .check => previewFile .check plan request.unsafeFixes ir.1 ir.2 snapshot analysis
          -- `format` publishes in place by default; `--check` demotes it to the preview.
          | .format =>
            if request.formatCheck then
              previewFile .format plan request.unsafeFixes ir.1 ir.2 snapshot analysis
            else formatFile plan request.unsafeFixes ir.1 ir.2 snapshot analysis
          | .diff => previewFile .diff plan request.unsafeFixes ir.1 ir.2 snapshot analysis
    return {
        report
        analysis? := some analysis
        failure? := none }
  catch error =>
    let message := toString error
    return {
        report :=
          { path := snapshot.relativePath
            status := "infrastructure-failure"
            diagnostics := #[message] }
        analysis? := none
        failure? := some s!"{snapshot.relativePath}: {message}" }

/-- Pull targets from the shared index until none remain. One worker is the serial loop; several
are `--workers N`. Workers write only their own outcomes slot; the shared refs they read (`setups`,
the temp-file counter) are either immutable after `primeSetups` or atomic. -/
private partial def batchWorker (exactRun : ExactRun) (request : RunRequest)
    (renderCanonical : Bool) (demanded : Tier) (demandedCaps : SemanticCaps)
    (work : Array TargetWork) (next : IO.Ref Nat) (outcomes : IO.Ref (Array (Option FileOutcome)))
    (progress : Progress.Progress) : IO Unit := do
  let index ← next.modifyGet fun n => (n, n + 1)
  if h : index < work.size then
    let target := work[index]
    let outcome ← processOneTarget exactRun request renderCanonical demanded demandedCaps target
    outcomes.modify (·.set! index (some outcome))
    LeanFmt.Progress.advance progress target.snapshot.path.toString
    batchWorker exactRun request renderCanonical demanded demandedCaps work next outcomes progress

/- Execute one immutable user request. This operation owns workspace discovery, exact module
selection, source snapshots, trusted-artifact validation, fallback, deterministic aggregation, and
resource intent. No caller can sequence or retain those mechanisms independently. -/
def execute (request : RunRequest) : IO RunOutcome := do
  let workers ← resolveWorkers request.workers
  recordCount "workers" workers
  let root ← IO.FS.realPath request.root
  let configPath? :=
    request.configPath?.map fun path => if path.isAbsolute then path else root / path
  let cli : CliSelection :=
    { select := request.select, extendSelect := request.extendSelect, ignore := request.ignore,
      fixable := request.fixable, unfixable := request.unfixable,
      extendFixable := request.extendFixable, preview := request.preview }
  -- Startup milestones: one stderr line before each phase that can sit silent for seconds on a
  -- real project, so an interactive run never looks hung. TTY-gated like the progress display
  -- (`Progress.start`): piped stderr -- suites, CI logs, editor pipes -- stays untouched.
  let milestone (message : String) : IO Unit := do
    let tty ← (← IO.getStderr).isTty
    let term ← IO.getEnv "TERM"
    if tty && term != some "dumb" then
      IO.eprintln s!"lean-fmt: {message}"
  -- Discovery is timed separately from the workspace load and the selection snapshot because it
  -- is the one phase this feature added to every run's critical path: a single tree walk. Folding
  -- it into an existing phase would hide the cost.
  milestone "discovering configuration and sources..."
  let discoveryStarted ← IO.monoNanosNow
  let discovery ← Discovery.run root configPath?
  let discovery := discovery.overrideReflowComments request.reflowComments?
  recordDuration "discovery" ((← IO.monoNanosNow) - discoveryStarted)
  -- The fallback plan is resolved first and unconditionally, so an invalid CLI selector is still
  -- a hard error on a run that selects no files at all — the behavior before configuration became
  -- per-file. It is also the strategy plan's seed.
  let basePlan ←
    match discovery.fallback.rulePlan cli with
    | .ok plan =>
      pure plan
    | .error message =>
      throw <| IO.userError message
  let mut announced : Array String := #[]
  for notice in discovery.fallback.notices ++ basePlan.notices do
    unless announced.contains notice do
      announced := announced.push notice
      IO.eprintln s!"lean-fmt: {notice}"
  milestone "loading the Lake workspace..."
  let project ← Project.load root discovery request.files
  recordDuration "workspace_load" project.workspaceLoadNanos
  recordDuration "selection_snapshot" project.selectionNanos
  let snapshots := project.targets
  milestone s!"selected {snapshots.size} {if snapshots.size == 1 then "file" else "files"}"
  -- One `RulePlan` per **distinct effective configuration**, not one per file: `configKey` is
  -- the directory whose config governs a target, so files sharing a config share a plan and a
  -- project with one config still resolves exactly one. Selection stays a projection — this
  -- changes which findings are shown per file, never what a run obtains or what a cache entry is
  -- keyed on.
  let mut planByKey : Std.HashMap String RulePlan := { }
  let mut plans : Array RulePlan := #[]
  for target in snapshots do
    match planByKey[target.configKey]? with
    | some plan =>
      plans := plans.push plan
    | none =>
      let plan ←
        match target.config.rulePlan cli with
        | .ok plan =>
          pure plan
        | .error message =>
          throw <| IO.userError message
      planByKey := planByKey.insert target.configKey plan
      plans := plans.push plan
      for notice in target.config.notices ++ plan.notices do
        unless announced.contains notice do
          announced := announced.push notice
          IO.eprintln s!"lean-fmt: {notice}"
  -- Import findings are computed fresh here, once, before any cache path: FMT003/05 are pure
  -- over each file's header, but FMT004 reads the Lake graph, so none of it is cacheable under a
  -- file's own digest (`computeImportReports`). One shared closure fetch covers every file; the
  -- result is threaded into `previewFile`/`fixFile` so selection and suppression apply to import
  -- findings like any rule's.
  let importStarted ← IO.monoNanosNow
  let importReports ← computeImportReports plans project snapshots
  recordDuration "import_findings" ((← IO.monoNanosNow) - importStarted)
  let application ← IO.appPath
  let epochStarted ← IO.monoNanosNow
  if request.cache then
    milestone "checking cached results..."
  let cache? ←
    if request.cache then
      ResultCache.open? project.workspace application (projectClosureMode project)
    else
      pure none
  let epochFinished ← IO.monoNanosNow
  recordPhase "cache_epoch" epochStarted epochFinished
  let lookupStarted ← IO.monoNanosNow
  let cached ←
    match cache? with
    | none =>
      pure (Array.replicate snapshots.size none)
    | some cache =>
      cache.readAll project snapshots
  let lookupFinished ← IO.monoNanosNow
  recordPhase "cache_lookup" lookupStarted lookupFinished
  -- An entry that cannot serve this run is demoted to a miss here, once, so that every path below
  -- treats it as one. A `check` run caches a result with no canonical text; a later `format`
  -- hitting it would otherwise short-circuit straight to "clean" for every file in the project.
  let renderCanonical := request.mode.rendersCanonical
  -- The apply signal: only `fix` applies rule fixes, so only `fix` demands
  -- the FMT012 occurrence fold. It is distinct from `renderCanonical` now that layout and fix are
  -- split — `format`/`diff` render but apply nothing; `fix` applies but no longer renders.
  let applies := request.mode == .fix
  -- What selected rules must obtain. Formatting is tracked independently by `renderCanonical`
  -- and always reaches the exact frontend.
  --
  -- Selection is per file, but what a run must *obtain* is decided once, for the
  -- whole batch, as the **union** of what any file demands. Two facts force that: the artifact
  -- fetch and the semantic capture are batch operations, and over-obtaining is only a cost while
  -- under-obtaining is a wrong answer. The union is seeded at `.source`, not at the fallback
  -- plan's tier, so a root config that selects syntax rules cannot make a project whose files all
  -- override it pay for syntax.
  let unionRequiredTier :=
    plans.foldl (init := Tier.source) fun tier plan => tier.max plan.requiredTier
  let demanded := unionRequiredTier
  let demandedCaps : SemanticCaps :=
    plans.foldl (init := { }) fun caps plan =>
      let wanted := plan.demandedCaps applies
      { occurrences := caps.occurrences || wanted.occurrences }
  -- Serving a cache entry stays a *per-file* question: it is that file's own required tier that decides
  -- whether a stored result answers it, never the batch union.
  let indexHits := cached.foldl (init := 0) fun n c? => if c?.isSome then n + 1 else n
  let cached :=
    (cached.zip plans).map fun (cached?, plan) =>
      cached?.filter (analysisServes plan.requiredTier (plan.demandedCaps applies) renderCanonical)
  -- `index_hits` counts entries the index answered with; `served` counts those that survived
  -- the tier/caps demotion above. They differ exactly when a stored result cannot answer this
  -- run's mode, so reporting both separates "the entry was invalidated" from "the entry was
  -- inadequate".
  recordCount "targets" snapshots.size
  recordCount "index_hits" indexHits
  let served := cached.foldl (init := 0) fun n c? => if c?.isSome then n + 1 else n
  recordCount "served" served
  recordCount "path_cache_hit" served
  -- A writing `format` is not served here: it must reach `withExactRun` for the
  -- validator child before it publishes, so it is excluded from both cache-only preview fast
  -- paths. `format --check`, which writes nothing, keeps them.
  if !request.writesFormat && cached.all Option.isSome then
    if let some previewMode := request.mode.preview? then
      let mut files := #[]
      for (((snapshot, cached?), importReport), plan) in
        ((snapshots.zip cached).zip importReports).zip plans do
        if let some analysis := cached? then
          files :=
            files.push
              (←
                withPhase "rules" <|
                    previewFile previewMode plan request.unsafeFixes importReport.1 importReport.2
                      snapshot analysis)
      let positions ← profiledPositions snapshots files
      return { report := summarize request.mode.toString files, positions }
  -- The plugin artifact carries reconstructible syntax but never semantic diagnostics, so a
  -- syntax-tier selection is answered from it without a frontend and a semantic one is not.
  -- A rendering run does not fetch it at all: layout needs the live per-command environment, not a
  -- projection, and the renderer that once read this was deleted. Fetching it anyway cost a
  -- no-build Lake traversal whose result nothing could read.
  let artifactServes := !renderCanonical && unionRequiredTier != Tier.source
  -- Source evidence and the artifact facet are one traversal. They were two, and the second was
  -- pure waste: both ask the same graph about the same modules at the same moment, and a
  -- `BuildStore` is per-`startBuild`, so nothing the first resolved was reused by the second.
  let evidenceStarted ← IO.monoNanosNow
  milestone "resolving module build state..."
  let facts ←
    Project.graph project.workspace snapshots (demand :=
        { status := true, artifacts := artifactServes })
  let evidence ← Project.moduleEvidence project facts
  let artifacts := facts.targets.map (·.artifact?)
  let evidenceFinished ← IO.monoNanosNow
  recordPhase "module_evidence" evidenceStarted evidenceFinished
  if artifactServes then
    recordCount "official_artifact_hit" (artifacts.countP (·.isSome))
    recordCount "official_artifact_miss" (artifacts.countP (·.isNone))
  let available ←
    ((((snapshots.zip cached).zip evidence).zip artifacts).zip plans).mapM fun
        | ((((snapshot, cached?), sourceEvidence), artifact?), plan) =>
          availableAnalysis plan renderCanonical applies sourceEvidence snapshot cached? artifact?
  if !request.writesFormat && available.all Option.isSome then
    if let some previewMode := request.mode.preview? then
      let analyses := available.filterMap id
      let files ←
        (((snapshots.zip analyses).zip importReports).zip plans).mapM
            fun (((snapshot, analysis), ir), plan) =>
            previewFile previewMode plan request.unsafeFixes ir.1 ir.2 snapshot analysis
      if let some cache := cache? then
        withPhase "cache_write" <|
            cache.writeAll project snapshots available (prune := request.files.isEmpty)
      let positions ← profiledPositions snapshots files
      return { report := summarize request.mode.toString files, positions }
  milestone "starting the toolchain..."
  withExactRun project workers fun exactRun => do
      -- Exactly the files the decisions above left unanswered, which is exactly the set that
      -- will spawn a frontend child and so need a Lake setup.
      exactRun.primeSetups <|
          (snapshots.zip available).filterMap fun (snapshot, available?) =>
            if available?.isNone then some snapshot else none
      let work :=
        ((((snapshots.zip available).zip importReports).zip plans).zip evidence).map
          fun ((((snapshot, available?), importReport), plan), evidence) =>
          { snapshot, available?, importReport, plan, compiled := evidence == .current }
      let outcomes ← IO.mkRef (Array.replicate work.size (none : Option FileOutcome))
      let next ← IO.mkRef 0
      -- Progress counts the targets the decisions above left unanswered — exactly the work that
      -- can take minutes on a cold run. An all-served run never reaches here and never shows one.
      let progress ← LeanFmt.Progress.start request.mode.toString work.size
      if workers > 1 && work.size > 1 then
        -- Several workers: one shared child registry (`withExactRun` creates it), outcomes by index.
        -- Dedicated priority is required, not tuning: workers block on child waits and file IO,
        -- and pooled blocking tasks can starve a small pool (`LEAN_NUM_THREADS=1` is a supported
        -- setting).
        let tasks ←
          (List.range (min workers work.size)).mapM fun _ =>
              IO.asTask
                (batchWorker exactRun request renderCanonical demanded demandedCaps work next
                  outcomes progress)
                Task.Priority.dedicated
        let mut firstError? : Option IO.Error := none
        for task in tasks do
          match ← IO.wait task with
          | .ok _ =>
            pure ()
          | .error error =>
            if firstError?.isNone then
              firstError? := some error
        if let some error := firstError? then
          throw error
      else
        batchWorker exactRun request renderCanonical demanded demandedCaps work next outcomes
            progress
      LeanFmt.Progress.finish progress
      let mut files := #[]
      let mut failures := #[]
      let mut analyses := #[]
      for outcome? in ← outcomes.get do
        let some outcome :=
          outcome? | throw <| IO.userError "a batch worker finished without reporting its target"
        files := files.push outcome.report
        analyses := analyses.push outcome.analysis?
        if let some failure := outcome.failure? then
          failures := failures.push failure
      if let some cache := cache? then
        withPhase "cache_write" <|
            cache.writeAll project snapshots analyses (prune := request.files.isEmpty)
      let positions ← profiledPositions snapshots files
      return { report := summarize request.mode.toString files failures, positions }

/-! ## The stdin/stdout stream surface

This is the raw-bytes-to-stdout path
deliberately left unbuilt when file-target `format` learned to write in place. It is a separate
operation from `execute` rather than a flag on it, because almost every clause of a batch run is wrong
here: there is no selection to discover, no cache to consult, no file to publish, and exactly one
target. Threading that through `execute` would put a `stdin?` conditional on each of those decisions;
keeping them apart lets each one state its own invariant once. -/

structure StreamRequest where
  mode : RunMode
  root : FilePath
  /-- The caller's own `--stdin-filename` argument, verbatim. It is an identity, **never** a
  destination: nothing in this operation can write it, and it need not exist. Errors name this
  string rather than a resolved path, as every other path-taking surface does. -/
  filename : String
  /-- The buffer, already decoded from stdin. -/
  source : String
  /-- A normalized-source byte range to format, or the whole buffer. Meaningful only for a
  rendering mode; only this operation accepts one. -/
  range? : Option SourceRange := none
  configPath? : Option FilePath := none
  selection : CliSelection := { }
  unsafeFixes : Bool := false
  formatCheck : Bool := false

structure StreamReport where
  path : String
  status : String
  findings : Array Finding := #[]
  diagnostics : Array String := #[]
  /-- The bytes to stream, in the buffer's own line-ending form. `none` for a non-emitting mode
  (`check`, `format --check`) and for a buffer that did not analyze — a broken buffer streams
  nothing rather than echoing its input, so a shell redirect cannot write it back over a good
  file. -/
  output : Option String := none
  diff : Option String := none
  /-- Set only for a range request. `actual` is the hull of the selected layout units and may
  span lines the caller did not edit. -/
  requested? : Option SourceRange := none
  actual? : Option SourceRange := none
  /-- The selected units' source map, indexing `output`. -/
  sourceMap : Array Mark := #[]
  changed : Bool := false

private def rangeJson (range : SourceRange) : Lean.Json :=
  Lean.Json.mkObj [("start", Lean.toJson range.start), ("stop", Lean.toJson range.stop)]

/-- `Mark` is `LeanFmt.Doc`'s, and `Doc` has no business knowing about JSON — the encoder lives here,
beside the one surface that reports a source map. -/
private def markJson (mark : Mark) : Lean.Json :=
  Lean.Json.mkObj [("source", rangeJson mark.source), ("output", rangeJson mark.output)]

def StreamReport.toJson (report : StreamReport) : Lean.Json :=
  Lean.Json.mkObj <|
    [("schema", Lean.Json.str "lean-fmt.stream.v1"), ("path", Lean.Json.str report.path),
        ("status", Lean.Json.str report.status), ("changed", Lean.Json.bool report.changed),
        ("findings", Lean.toJson report.findings),
        ("diagnostics", Lean.toJson report.diagnostics)] ++
      (match report.output with
      -- The bytes go in the JSON too. Text mode puts them on stdout bare; a `--json` caller asked
      -- for one structured document and must not have to run the command twice to get the result out
      -- of it. Named `formatted` to match the file-target report's `FileReport.formatted`.
      | some output => [("formatted", Lean.Json.str output)]
      | none => []) ++
      (match report.diff with
      | some diff => [("diff", Lean.Json.str diff)]
      | none => []) ++
      (match report.requested? with
      | some range => [("requestedRange", rangeJson range)]
      | none => []) ++
      (match report.actual? with
      | some range => [("actualRange", rangeJson range)]
      | none => []) ++
      (if report.sourceMap.isEmpty then []
      else [("sourceMap", Lean.Json.arr (report.sourceMap.map markJson))])

/-- The exact half of `stream`, against a run the caller already holds.

`stream` resolves a root, a discovery, a workspace, and an envelope on every call, which is
right for a one-shot pipe and wrong for a session: a language server holds all four for its
lifetime and would otherwise pay `Project.loadWorkspaceOnly` per keystroke. Everything below the
resolution is identical, so it lives here and `stream` is the resolving wrapper.

This is what "no second formatter" means concretely: the LSP surface enters
*here*, not through a parallel rendering path, so a range answer served to an editor and the same
range piped through `--stdin` are the same bytes computed by the same code.

The supplied envelope may come from the isolated child path or a document-owned incremental
frontend; projection, rule execution, validation, range slicing, and rendering do not distinguish
them. -/
def ExactRun.streamEnvelope (run : ExactRun) (target : Project.SourceTarget) (plan : RulePlan)
    (mode : RunMode) (envelope : AnalysisEnvelope) (range? : Option SourceRange := none)
    (unsafeFixes : Bool := false) (formatCheck : Bool := false) : IO StreamReport := do
  let project := run.project
  let renderCanonical := mode.rendersCanonical
  let analysis ← canonicalAnalysis target renderCanonical envelope
  let marks := analysis.result?.bind (·.canonical?) |>.map (·.sourceMap) |>.getD #[]
  let (normalized, _) := LosslessSource.normalize target.source
  let (reportImports, withheldRedundant) ←
    singleImportReport plan project.workspace normalized target.config.format
  match
    prepareFile plan renderCanonical unsafeFixes reportImports withheldRedundant target
      analysis with
  | .error report =>
    return {
        path := report.path
        status := report.status
        findings := report.findings
        diagnostics := report.diagnostics }
  | .ok prepared =>
    let findings := prepared.findings
    let base : StreamReport := { path := target.relativePath, status := "clean", findings }
    match mode with
    | .check =>
      return { base with
          status := if findings.isEmpty then "clean" else "findings"
          changed := !findings.isEmpty }
    | .diff =>
      unless prepared.changed do
        return base
      return { base with
          status := "would-diff"
          changed := true
          diff :=
            some (unifiedDiff target.relativePath prepared.normalized prepared.patch.formatted) }
    | .fix =>
      unless prepared.changed do
        return { base with output := some prepared.output }
      return { base with
          status := "fixed"
          changed := true
          output := some prepared.output }
    | .format =>
      let sliced? :=
        range?.bind fun range => sliceRange prepared.normalized prepared.patch.formatted marks range
      let (text, requested?, actual?, sourceMap) :=
        match sliced? with
        | some result => (result.text, some result.requested, some result.actual, result.marks)
        | none => (prepared.patch.formatted, none, none, marks)
      let output := LosslessSource.denormalize text prepared.lineEndings
      let changed := text != prepared.normalized
      if formatCheck then
        return { base with
            status := if changed then "would-format" else "clean"
            changed, requested?, actual?, sourceMap }
      return { base with
          status := if changed then "formatted" else "clean"
          output := some output
          changed, requested?, actual?, sourceMap }

def ExactRun.streamSnapshot (run : ExactRun) (target : Project.SourceTarget) (plan : RulePlan)
    (mode : RunMode) (range? : Option SourceRange := none) (unsafeFixes : Bool := false)
    (formatCheck : Bool := false) (cancel? : Option Std.CancellationToken := none) :
    IO StreamReport := do
  let renderCanonical := mode.rendersCanonical
  let applies := mode == .fix
  let demandedCaps := plan.demandedCaps applies
  let demanded := plan.requiredTier
  let envelope ←
    run.envelope target (captureSemantic := demanded == .semantic) (captureOccurrences :=
        demandedCaps.occurrences) (format? :=
        if renderCanonical then some target.config.format else none) (cancel? := cancel?)
  run.streamEnvelope target plan mode envelope range? unsafeFixes formatCheck

/-- Format, check, diff, or fix one unsaved buffer and stream the answer.

Every clause of the streaming contract is enforced here:

- **No write.** `publishAtomic` is not reachable from this operation. `fix`/`format` return their
  bytes in `output` for the caller to redirect; the file, if there even is one, is untouched.
- **No persistent cache.** `ResultCache` is never opened. A cache entry is keyed on a digest bound
  to a file on disk, and unsaved bytes have no disk state to bind — the same rule an editor session
  follows.
- **The isolated stream envelope.** One `withExactRun` and a fresh child per request. The language
  server uses the same capability's setup and projection operations around its persistent document
  frontend, without introducing a second formatter.
- **Identity is required.** `Project.unsavedTarget` applies every gate the file path applies,
  including the `.lake` floor, and resolves the effective configuration from the buffer's location,
  so the same bytes get the same answer whether they arrive by path or by pipe.

The exact frontend response retains the complete admitted layout for this surface. Batch cache hits
and unsaved streams consume the same text, source map, formatter metrics, and validation metrics;
no caller reaches back into the transport envelope for a second partial representation. -/
def stream (request : StreamRequest) : IO StreamReport := do
  let root ← IO.FS.realPath request.root
  let configPath? :=
    request.configPath?.map fun path => if path.isAbsolute then path else root / path
  let discovery ← Discovery.run root configPath?
  let project ← Project.loadWorkspaceOnly root
  let target ←
    Project.unsavedTarget project.workspace discovery root request.filename request.source
  let plan ←
    match target.config.rulePlan request.selection with
    | .ok plan =>
      pure plan
    | .error message =>
      throw <| IO.userError message
  for notice in target.config.notices ++ plan.notices do
    IO.eprintln s!"lean-fmt: {notice}"
  withExactRun project (action := fun run =>
      run.streamSnapshot target plan request.mode (range? := request.range?) (unsafeFixes :=
        request.unsafeFixes) (formatCheck := request.formatCheck))

/-- Organize one unsaved buffer's imports, validated and returned rather than written.

`organize` below is the batch operation: it walks a selection, validates, and publishes
atomically. An editor cannot use it — the bytes belong to a buffer that may never have been saved,
and the client, not this process, applies the edit. What the two must not disagree about is *which*
rewrite happens and whether it is allowed to happen, so both call `Imports.parseHeaderModel` +
`Imports.organize` for the candidate and `analyzeSnapshot (validator := true)` for the verdict.
Only the last step differs: `publishAtomic` there, a returned `String` here.

Validation is not optional just because this path does not write. The reorder is observable to
elaboration — which is why it is opt-in — so a header that stops
elaborating must be refused before it reaches the user's buffer, just as it is refused before it
reaches their file.

`none` means the header is already canonical. An `.error` names why the rewrite was refused. -/
def ExactRun.organizeSnapshot (run : ExactRun) (target : Project.SourceTarget)
    (cancel? : Option Std.CancellationToken := none) : IO (Except String (Option String)) := do
  let (normalized, lineEndings) := LosslessSource.normalize target.source
  let some header ← Imports.parseHeaderModel normalized | return .ok none
  let output :=
    LosslessSource.denormalize
      (Imports.organize header normalized target.config.format.importLayout
        target.config.format.importGroups)
      lineEndings
  if output == target.source then
    return .ok none
  let validation ←
    run.analyzeSnapshot (target.withSource output) (renderCanonical := false) (validator := true)
        (cancel? := cancel?)
  match validation.result? with
  | none =>
    let detail :=
      if validation.diagnostics.isEmpty then "the organized header did not elaborate"
      else String.intercalate "; " validation.diagnostics.toList
    return .error s!"organize imports was refused: {detail}"
  | some _ =>
    return .ok (some output)

structure OrganizeRequest where
  root : FilePath
  files : Array FilePath
  configPath? : Option FilePath := none
  /-- Report what would change without writing (like `check` for the organizer). -/
  check : Bool := false
  /-- How many frontend children may validate candidates concurrently (`--workers`), or `none`
  to pick the number the way Lake picks it for its own build (`resolveWorkers`). Outcomes are
  assembled by target index, so the report is identical at any value. -/
  workers : Option Nat := none
  /-- Read and write the result cache (`--no-cache` disables both): stored validation verdicts
  let a re-run skip the frontend for a candidate it has already validated. -/
  cache : Bool := true

/-- One organize worker's answer for one target. -/
private structure OrganizeOutcome where
  report : FileReport
  /-- An infrastructure-failure note for the run trailer. -/
  failure? : Option String := none
  /-- The validation analysis of a candidate this worker ran the frontend for — the verdict the
  run stores and the next probe serves. `none` when no child ran (clean, or the probe answered),
  and when validation found an unbuilt dependency: that outcome says nothing about the bytes
  (`storableAnalysis`), so it is reported but never stored. -/
  validation? : Option SemanticAnalysis := none

/-- Whether organize's validation child captures the semantic-diagnostics projection (capture
"1") or runs bare (capture "0"). The projection is what a stored verdict serves later: "0"
leaves the entry at `.syntax` tier, so a `.semantic` selection misses and recomputes; "1" makes
the stored analysis serve every non-`fix` demand.

Default-on, measured (2026-07-30, local repo 8-file mathlib-closure batch, min of two runs,
summed `exact_child_ms`): capture "0" 8158 ms vs capture "1" 8052 ms — the diagnostics capture
is noise beside elaboration, so the one elaboration serves every later command it can. The
occurrence fold (capture "2") is deliberately not paid: only `fix` consumes it, and organize's
product is not fixes. -/
private def organizeHarvestFindings : IO Bool :=
  return true

/-- Validate and publish one organize candidate. One worker is the serial loop; several are
`--workers N`. Workers write only their own outcomes slot, and `publishAtomic` targets a
distinct path per slot, so the shared state they touch (`next`, `outcomes`, the setup refs
inside `exactRun`) is either atomic or immutable after `primeSetups`. -/
private partial def organizeWorker (exactRun : ExactRun)
    (work :
      Array
        (SourceSnapshot × Option String × Option (Cache.Decision.ElabVerdict × SemanticAnalysis)))
    (next : IO.Ref Nat) (outcomes : IO.Ref (Array (Option OrganizeOutcome))) : IO Unit := do
  let index ← next.modifyGet fun n => (n, n + 1)
  if h : index < work.size then
    let (snapshot, candidate?, probe?) := work[index]
    match candidate? with
    | none =>
      outcomes.modify (·.set! index (some { report := baseReport snapshot "clean" }))
    | some output =>
      try
        match probe? with
        | some (.rejected, verdict) =>
          -- The stored verdict *is* the validation this run would have run — same bytes, same
          -- closure — and its diagnostics are the report. No child is spawned.
          outcomes.modify
              (·.set! index
                (some { report := baseReport snapshot "rejected" #[] verdict.diagnostics }))
        | some (.elaborates, _) =>
          match ← publishAtomic snapshot.path snapshot.source output with
          | .error message =>
            outcomes.modify
                (·.set! index (some { report := baseReport snapshot "rejected" #[] #[message] }))
          | .ok _ =>
            outcomes.modify
                (·.set! index
                  (some
                    {
                      report :=
                        { (baseReport snapshot "organized") with
                          formatted := some output, written := true } }))
        | none =>
          let candidate := snapshot.withSource output
          let validation ←
            exactRun.analyzeSnapshot candidate (renderCanonical := false) (validator := true)
                (captureSemantic := ← organizeHarvestFindings)
          match validation.result? with
          | none =>
            -- An unbuilt dependency is not a verdict about the bytes — report it and store
            -- nothing, so the next run validates again rather than serving a stored rejection.
            let unbuilt := (unbuiltDependency? validation.diagnostics).isSome
            outcomes.modify
                (·.set! index
                  (some
                    { report :=
                        baseReport snapshot (if unbuilt then "unbuilt" else "rejected") #[]
                          validation.diagnostics
                      validation? := if unbuilt then none else some validation }))
          | some _ =>
            match ← publishAtomic snapshot.path snapshot.source output with
            | .error message =>
              outcomes.modify
                  (·.set! index (some { report := baseReport snapshot "rejected" #[] #[message] }))
            | .ok _ =>
              outcomes.modify
                  (·.set! index
                    (some
                      { report :=
                          { (baseReport snapshot "organized") with
                            formatted := some output, written := true }
                        validation? := some validation }))
      catch error =>
        let message := toString error
        let report : FileReport :=
          { path := snapshot.relativePath, status := "infrastructure-failure",
            diagnostics := #[message] }
        outcomes.modify
            (·.set! index
              (some { report, failure? := some s!"{snapshot.relativePath}: {message}" }))
    organizeWorker exactRun work next outcomes

/-- The opt-in "organize imports" capability, exposing no graph
internals — text in, text out. It rewrites each target's surface header to canonical form:
duplicates removed (FMT003's safe edit) and each blank-line/comment group sorted by module name
(FMT005's reorder). The reorder is *observable to elaboration*, which
is why it is opt-in and never part of unattended `fix`; redundant imports (FMT004) are report-only
and are **not** removed here.

Every rewrite that changes a file is validated by re-elaboration before it is written — the same
trusted-artifact discipline `fix` uses (`fixFile`) — so an organized header that fails to elaborate
is rejected, never published. A clean project never constructs the validator. -/
def organize (request : OrganizeRequest) : IO RunReport := do
  let root ← IO.FS.realPath request.root
  let configPath? :=
    request.configPath?.map fun path => if path.isAbsolute then path else root / path
  let discovery ← Discovery.run root configPath?
  for notice in discovery.fallback.notices do
    IO.eprintln s!"lean-fmt: {notice}"
  let project ← Project.load root discovery request.files
  let snapshots := project.targets
  -- The canonical header rewrite is pure (no graph): compute every candidate first, and only
  -- pay for the validator if some file actually changes. `Imports.organizeCandidate?` is the one
  -- definition — the cache's live set computes the same candidates when it prunes.
  let candidates ←
    snapshots.mapM fun snapshot =>
        Imports.organizeCandidate? snapshot.source snapshot.config.format.importLayout
          snapshot.config.format.importGroups
  let anyChange := candidates.any Option.isSome
  if request.check || !anyChange then
    let files :=
      (snapshots.zip candidates).map fun (snapshot, candidate?) =>
        baseReport snapshot (if candidate?.isSome then "would-organize" else "clean")
    return summarize "organize" files
  let workers ← resolveWorkers request.workers
  recordCount "workers" workers
  let epochStarted ← IO.monoNanosNow
  let cache? ←
    if request.cache then
      ResultCache.open? project.workspace (← IO.appPath) (projectClosureMode project)
    else
      pure none
  recordPhase "cache_epoch" epochStarted (← IO.monoNanosNow)
  -- The verdict probe, before any dispatch: a stored verdict *is* the validation this run would
  -- perform (same candidate bytes, same closure), so a hit makes the worker pool idle for that
  -- file. `none` everywhere means validate — a candidate never seen, or one whose last outcome
  -- was unbuilt, which is never stored.
  let probes ←
    match cache? with
    | none =>
      pure
          (Array.replicate snapshots.size
            (none : Option (Cache.Decision.ElabVerdict × SemanticAnalysis)))
    | some cache =>
      do
        let probing :=
          ((snapshots.zip candidates).zipIdx).filterMap fun ((snapshot, candidate?), index) =>
            candidate?.map fun output => (index, snapshot.withSource output)
        let found ← withPhase "cache_lookup" <| cache.probeVerdicts project (probing.map (·.2))
        let mut perIndex :=
          Array.replicate snapshots.size
            (none : Option (Cache.Decision.ElabVerdict × SemanticAnalysis))
        for ((index, _), verdict?) in probing.zip found do
          perIndex := perIndex.set! index verdict?
        recordCount "verdict_hits" (found.countP Option.isSome)
        pure perIndex
  withExactRun project workers (action := fun exactRun => do
      -- Only a snapshot with a candidate rewrite and no stored verdict is validated, so only
      -- those reach the frontend.
      exactRun.primeSetups <|
          ((snapshots.zip candidates).zip probes).filterMap fun ((snapshot, candidate?), probe?) =>
            if candidate?.isSome && probe?.isNone then some snapshot else none
      let work :=
        ((snapshots.zip candidates).zip probes).map fun ((snapshot, candidate?), probe?) =>
          (snapshot, candidate?, probe?)
      let outcomes ← IO.mkRef (Array.replicate work.size (none : Option OrganizeOutcome))
      let next ← IO.mkRef 0
      if workers > 1 && work.size > 1 then
        -- The batch pattern (`execute`): dedicated priority is required because workers block on
        -- child waits, and pooled blocking tasks can starve a small pool.
        let tasks ←
          (List.range (min workers work.size)).mapM fun _ =>
              IO.asTask (organizeWorker exactRun work next outcomes) Task.Priority.dedicated
        let mut firstError? : Option IO.Error := none
        for task in tasks do
          match ← IO.wait task with
          | .ok _ =>
            pure ()
          | .error error =>
            if firstError?.isNone then
              firstError? := some error
        if let some error := firstError? then
          throw error
      else
        organizeWorker exactRun work next outcomes
      let mut files := #[]
      let mut failures := #[]
      let mut validations : Array (SourceSnapshot × SemanticAnalysis) := #[]
      for ((snapshot, candidate?, _), outcome?) in work.zip (← outcomes.get)do
        let some outcome :=
          outcome? | throw <| IO.userError "an organize worker finished without reporting its target"
        files := files.push outcome.report
        if let some failure := outcome.failure? then
          failures := failures.push failure
        match candidate?, outcome.validation? with
        | some output, some validation =>
          validations := validations.push (snapshot.withSource output, validation)
        | _, _ =>
          pure ()
      -- Every validation becomes a stored verdict: a published file's entry is its live analysis
      -- for the next `check`/`format`, a rejected candidate's broken entry is the rejection the
      -- next probe serves. Unbuilt outcomes are excluded upstream (`OrganizeOutcome.validation?`).
      if let some cache := cache? then
        withPhase "cache_write" <|
            cache.writeAll project (validations.map (·.1)) (validations.map (some ·.2)) (prune :=
              request.files.isEmpty)
      return summarize "organize" files failures)

/-- The whole analysis side of `__analyze-exact`: read the setup and source, run the exact
frontend at the capture mode, and return the encoded envelope. Transport — stdout for a direct
invocation, per-target files for the batch parent — is `runAnalyzeChild`'s, not this one's. -/
private unsafe def analyzeChildEnvelope (setupPath snapshotPath displayPath : String)
    (rawCaptureMode : String) : IO String := do
  -- The compile-evidence prefix comes off first so every form below reads exactly as it did before
  -- there was one.
  let compiled := rawCaptureMode.startsWith "c"
  let captureMode := if compiled then (rawCaptureMode.drop 1).copy else rawCaptureMode
  -- The parent's `exact_child` minus the child's `child_analyze` left about 170 ms per file
  -- unattributed, and this is the half of it the child can see. A `ModuleSetup` names an artifact
  -- path for every module in the closure, so on a deep closure the JSON is large and parsing it is
  -- not free; the remainder outside this bracket is process spawn and binary load, which the child
  -- cannot measure from inside itself.
  let (setup, source) ←
    withPhase "child_setup" do
        let .ok setupJson :=
          Lean.Json.parse
            (← IO.FS.readFile setupPath) | throw <| IO.userError "invalid ModuleSetup JSON"
        let .ok (setup : Lean.ModuleSetup) :=
          Lean.fromJson? setupJson | throw <| IO.userError "invalid ModuleSetup payload"
        let source ← IO.FS.readFile snapshotPath
        pure (setup, source)
  -- "0" none, "1" semantic diagnostics, "2" diagnostics plus the info-tree occurrence
  -- fold, "3" test/audit-only comment ownership, "draft[:WIDTH]" the deliberately unvalidated test
  -- hook, "4[:WIDTH]" the structurally/idempotently admitted layout at a bare margin, and
  -- "4j<json>" the same with the full `FormatConfig` (which a bare margin predates: the config
  -- gained pinned comments and a body policy after the width ladder). "4s" is any of the "4"
  -- forms under `--no-validate`'s structural policy; without the "c" prefix's compiled evidence
  -- the child has no admitted frontier and validates exactly anyway.
  --
  -- Two phases, on this side of the process boundary where the parent cannot see: `child_analyze`
  -- is the frontend itself, `child_encode` is turning its result into the JSON the parent reads
  -- back. A projection runs about 10x the size of its source, so the second is not
  -- obviously small, and the parent's `exact_child` covers both without distinguishing them. These
  -- records go to the profile channel (stderr, or the file `LEAN_FMT_PROFILE_OUT` names — the
  -- batch parent points it at the target's err file and forwards the lines); the envelope travels
  -- alone.
  let (validatedFormat?, validationPolicy) ←
    match captureMode.splitOn ":" with
    | ["4"] =>
      pure (some ({ } : FormatConfig), ValidationPolicy.exact)
    | ["4s"] =>
      pure (some ({ } : FormatConfig), ValidationPolicy.structural)
    | ["4", width] =>
      pure (width.toNat?.map fun width => { lineWidth := width }, ValidationPolicy.exact)
    | ["4s", width] =>
      pure (width.toNat?.map fun width => { lineWidth := width }, ValidationPolicy.structural)
    | _ =>
      if captureMode.startsWith "4j" || captureMode.startsWith "4s" then
        do
          let policy :=
            if captureMode.startsWith "4s" then ValidationPolicy.structural
            else ValidationPolicy.exact
          let .ok json :=
            Lean.Json.parse
              (captureMode.drop
                  2).copy | throw <| IO.userError "invalid FormatConfig JSON in capture mode"
          let .ok (format : FormatConfig) :=
            Lean.fromJson?
              json | throw <| IO.userError "invalid FormatConfig payload in capture mode"
          pure (some format, policy)
      else
        pure (none, ValidationPolicy.exact)
  let draftWidth? :=
    match captureMode.splitOn ":" with
    | ["draft"] => some 100
    | ["draft", width] => width.toNat?
    | _ => none
  let format :=
    match validatedFormat?, draftWidth? with
    | some validated, _ => validated
    | none, some width => { lineWidth := width }
    | none, none => { }
  let envelope ←
    withPhase "child_analyze" <|
        analyzeExact setup source displayPath (captureSemantic :=
          captureMode == "1" || captureMode == "2") (captureOccurrences := captureMode == "2")
          (captureComments := captureMode == "3") (captureFormatDraft := draftWidth?.isSome)
          (validateFormatDraft := validatedFormat?.isSome) (format := format) (compiled := compiled)
          (validationPolicy := validationPolicy)
  withPhase "child_encode" do
      -- `IO.lazyPure` for the reason `profiledPositions` documents: a plain `let` of a pure value
      -- can be floated out of the action's closure, and then the bracket times nothing. The
      -- `utf8ByteSize` check below is not sufficient on its own — it forces the value, but not
      -- necessarily *here*.
      let encoded ← IO.lazyPure fun _ => (Lean.toJson envelope).compress
      -- `utf8ByteSize` is O(1) and forces the encoding inside the phase rather than at the
      -- write below, where it would be attributed to nothing. An empty encoding is also not a
      -- thing a real envelope produces, so the check is worth its line independent of the timing.
      if encoded.utf8ByteSize == 0 then
        throw <| IO.userError "exact frontend produced an empty analysis encoding"
      pure encoded

private unsafe def runAnalyzeChild (args : List String) : IO UInt32 := do
  -- The capture mode is a trailing optional argument: a direct three-argument invocation omits it
  -- and captures no optional frontend fact, and its envelope goes to stdout. The batch parent
  -- adds the two transport paths — the envelope's destination and the diagnostics file — which
  -- is the pipe-free transport `spawnChild` documents: this process holds the parent's inherited
  -- descriptors plus its own `.olean` mmaps, and a protocol that adds two pipe handles per child
  -- to the *parent* is what exhausted them on a 1400-target run. A failure lands in the
  -- diagnostics file so the parent's report can name it; an uncaught exception with null stderr
  -- would be a status with no message.
  let (setupPath, snapshotPath, displayPath, captureMode, transport?) ←
    match args with
    | [setupPath, snapshotPath, displayPath] =>
      pure (setupPath, snapshotPath, displayPath, "0", none)
    | [setupPath, snapshotPath, displayPath, captureMode] =>
      pure (setupPath, snapshotPath, displayPath, captureMode, none)
    | [setupPath, snapshotPath, displayPath, captureMode, outPath, errPath] =>
      pure (setupPath, snapshotPath, displayPath, captureMode, some (outPath, errPath))
    | _ =>
      return 2
  try
    let encoded ← analyzeChildEnvelope setupPath snapshotPath displayPath captureMode
    match transport? with
    | some (outPath, _) =>
      IO.FS.writeFile outPath encoded
    | none =>
      IO.println encoded
    return 0
  catch error =>
    match transport? with
    | some (_, errPath) =>
      IO.FS.writeFile errPath s!"{error}\n"
      return 1
    | none =>
      throw error

private unsafe def runExtractChild (args : List String) : IO UInt32 := do
  let [moduleName, moduleFile, output] := args | return 2
  match ← compilerArtifact? moduleName.toName moduleFile with
  | some artifact =>
    writeArtifactAtomic output artifact
  | none =>
    if let some parent := (output : FilePath).parent then
      IO.FS.createDirAll parent
    IO.FS.writeFile output "null"
  return 0

private unsafe def runValidateCandidateChild (args : List String) : IO UInt32 := do
  let [setupPath, sourcePath, candidatePath, displayPath, width] := args | return 2
  let some width := width.toNat? | return 2
  let .ok setupJson := Lean.Json.parse (← IO.FS.readFile setupPath) | return 2
  let .ok (setup : Lean.ModuleSetup) := Lean.fromJson? setupJson | return 2
  let source ← IO.FS.readFile sourcePath
  let candidate ← IO.FS.readFile candidatePath
  let result ← validateCandidateExact setup source candidate displayPath { lineWidth := width }
  IO.println (Lean.toJson result).compress
  return 0

private unsafe def measureCacheEpoch (args : List String) : IO UInt32 := do
  let [root] := args | return 2
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

/-- One file's resolved configuration with provenance: which config governs it, what every effective
setting is and where it came from, which ignore sources are in force, and whether the file would be
selected — with the deciding gate.

This is read-only and deterministic. It runs the same `Discovery.run` a real run does and asks it
the same questions, rather than re-deriving selection independently: an introspection command that
answers from its own model of the rules is worth less than no command, because it agrees with the
rules until the moment it matters. -/
structure ConfigSetting where
  key : String
  value : String
  origin : String
  deriving Lean.ToJson

structure ConfigReport where
  path : String
  relativePath : String
  configFile : String
  contributingFiles : Array String
  ignoreSources : Array String
  settings : Array ConfigSetting
  notices : Array String
  gate : Nat
  gateDescription : String
  selected : Bool
  deriving Lean.ToJson

def describeConfig (requestedRoot : FilePath) (configPath? : Option FilePath) (argument : String) :
    IO ConfigReport := do
  let root ← IO.FS.realPath requestedRoot
  let configPath? := configPath?.map fun path => if path.isAbsolute then path else root / path
  -- Pre-check by the caller's own argument, as the selection surface does
  -- (`CLAUDE.md`: path errors name the caller's own argument).
  unless ← System.FilePath.pathExists (System.FilePath.mk argument) do
    throw <| IO.userError s!"selected file does not exist: {argument}"
  let absolute ← IO.FS.realPath (System.FilePath.mk argument)
  let relative := (Lake.relPathFrom root absolute).toString
  -- Timed here as well as in `execute`, and for the same reason: this is the one entry point
  -- that runs discovery and nothing else, so it is how the walk's cost is measured without the
  -- per-file pipeline on top of it.
  let discoveryStarted ← IO.monoNanosNow
  let discovery ← Discovery.run root configPath?
  recordDuration "discovery" ((← IO.monoNanosNow) - discoveryStarted)
  let (key, config) := discovery.governing relative
  let outsideRoot :=
    absolute != root &&
      !absolute.toString.startsWith (root.toString ++ System.FilePath.pathSeparator.toString)
  let insideLake :=
    relative == ".lake" || relative.startsWith ".lake/" || relative.startsWith ".lake\\"
  let notLean := absolute.extension != some "lean"
  let gate :=
    if outsideRoot || insideLake || notLean then Discovery.Gate.floor
    else discovery.explain relative
  return {
      path := absolute.toString
      relativePath := relative
      configFile :=
        if key.isEmpty && config.origins.isEmpty then "(none — built-in defaults)"
        else if key.isEmpty then "(project root)" else key
      contributingFiles := config.contributingFiles
      ignoreSources := if config.respectGitignore then discovery.ignoreSources else #[]
      settings := config.describe.map fun (key, value, origin) => { key, value, origin }
      notices := config.notices
      gate := gate.number
      gateDescription := gate.describe
      selected := gate == .selected }

structure CleanReport where
  root : String
  removed : Bool
  deriving Lean.ToJson

def clean (requestedRoot : FilePath) : IO CleanReport := do
  let root ← IO.FS.realPath requestedRoot
  let cache := root / ".lean-fmt-cache"
  let removed ← cache.pathExists
  if removed then
    IO.FS.removeDirAll cache
  return { root := root.toString, removed }

/-- Where `compiler build` runs. -/
structure CompilerRequest where
  root : FilePath := "."

structure CompilerSetupReport where
  schema : String
  package : String
  plugin : String
  facet : String
  toolchain : String
  guidance : Array String
  deriving Lean.ToJson

def compilerSetupReport : CompilerSetupReport :=
  { schema := "lean-fmt.compiler-setup.v1"
    package := "lean-fmt"
    plugin := "LeanFmtCompilerPlugin:shared"
    facet := "leanFmtArtifact"
    toolchain := s!"Lean {Lean.versionString} ({Lean.githash})"
    guidance :=
      #["the plugin is optional: without it a syntax-tier rule runs the exact frontend and reports the same finding",
        "add lean-fmt as a Lake dependency using the source and revision you trust",
        "set plugins := #[`@«lean-fmt»/LeanFmtCompilerPlugin:shared] on the package, not on each lean_lib",
        "the guillemets are required: lean-fmt is not a legal Lean identifier",
        "for lake lint, set lintDriver := \"«lean-fmt»/«lean-fmt»\" and lintDriverArgs := #[\"check\"]",
        "run `lean-fmt compiler build` to extract every workspace module's artifact in one lake invocation",
        "editing the plugin re-elaborates every module that loads it; that trace edge is what makes the artifact trustworthy"] }

/-- Build every workspace module's `leanFmtArtifact` sidecar in one `lake build` invocation.

Lake owns the build: topological order, parallelism, and cache reuse — a module whose olean is
fresh pays only for extraction, and dependency packages (mathlib) are never targets because
`Project.loadAll` enumerates the root package's modules. Hand-enumerating targets per module
would re-traverse the same graph once per module instead of computing one fixpoint. Stdio is
inherited so the user watches Lake's own progress; the exit code is Lake's. -/
def compilerBuild (request : CompilerRequest) : IO UInt32 := do
  let root ← IO.FS.realPath request.root
  let project ← Project.loadAll root
  let facetName := `module.leanFmtArtifact
  let some config := project.workspace.findModuleFacetConfig? facetName |
    throw <|
        IO.userError
          "the leanFmtArtifact facet is not registered in this workspace; install the plugin first        (lean-fmt compiler setup)"
  let mut seen : Std.HashSet Lean.Name := { }
  let mut modules := #[]
  for snapshot in project.targets do
    if let some mod := snapshot.module? then
      unless seen.contains mod.name do
        seen := seen.insert mod.name
        modules := modules.push mod
  if modules.isEmpty then
    IO.eprintln "lean-fmt: no modules selected; nothing to build"
    return 0
  -- The workspace this command already loaded, rather than whatever `lake` a PATH lookup finds.
  -- Shelling out left a window where the two disagreed about the toolchain, and `officialArtifacts`
  -- already reaches the same facet the same way.
  try
    discard <|
        project.workspace.runBuild do
          let jobs ← modules.mapM (config.run (β := Lake.FacetOut facetName) ·)
          return Lake.Job.collectArray jobs "lean-fmt artifact facets"
    return 0
  catch error =>
    IO.eprintln s!"lean-fmt: {error}"
    return 1

/-- Dispatch only the private subprocess/profiling protocol. Ordinary product commands return
`none` and cannot observe setup paths, module artifacts, or process limits. -/
unsafe def runInternal? (args : List String) : IO (Option UInt32) :=
  match args with
  | "__analyze-exact" :: rest => some <$> runAnalyzeChild rest
  | "__validate-candidate" :: rest => some <$> runValidateCandidateChild rest
  | "__extract-artifact" :: rest => some <$> runExtractChild rest
  | "__measure-cache-epoch" :: rest => some <$> measureCacheEpoch rest
  | _ => pure none

end LeanFmt.Internal.Application
