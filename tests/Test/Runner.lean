module

public import Test

import all Test.Unit.Cases

import Std.Sync.Mutex

/-!
# The suite orchestrator

`tests/run-all.sh`'s successor, and the package's `testDriver`. One command answers "is the tree
green": the unit tier runs in-process first (it is fast, and its failure makes the suites mostly
moot — `--skip-unit` exists for the other direction), then the selected suites are built in **one**
up-front `lake build` and run as executables. Building once is what retires both the per-suite
`lake build` overhead and the concurrent-build hazard `tests/modes` documents: during the run, no
suite shares the build with another.

Suites declare how they may overlap, and the orchestrator is the only thing that knows the whole
schedule:

- `parallel` suites own temp worlds — fixture projects with their own `.lake`, scratch trees — and
  run up to `--jobs` at a time.
- `workspace` suites build fixtures or write scratch inside this package's workspace. They run
  under one lock, so they serialize with each other but overlap `parallel` suites.
- `exclusive` suites run alone: after every other lane has drained, one at a time.
- `slow` suites (minutes, git clones, timing measurements) are out of the default set; `--all`
  includes them and `--suites` names them explicitly.

The terminal contract is `run-all.sh`'s, kept: one line per suite with PASS/FAIL and seconds, a
slowest-suites tail, and a scratch directory of full logs printed only when there is something to
read in it.
-/

open LeanFmt.Test

namespace LeanFmt.Test.Runner

/-- How a suite may overlap other suites. -/
inductive Lane where
  | «parallel»
  | workspace
  | exclusive
  deriving Repr, BEq, Inhabited

/-- One registered suite. The executable is `suite-<name>` by convention. -/
structure Suite where
  name : String
  lane : Lane
  slow : Bool := false
  deriving Inhabited

def Suite.exeName (suite : Suite) : String := s!"suite-{suite.name}"

/-- The suite registry. Adding a suite is a `lean_exe «suite-<name>»` in the lakefile plus one
line here; a name in either place but not the other fails loudly (the build step for the first,
this list for the second). -/
private def registered : Array Suite := #[
  { name := "block-formatter", lane := .«parallel» },
  { name := "cache", lane := .workspace },
  { name := "catalog", lane := .workspace },
  { name := "check", lane := .workspace },
  { name := "collection-formatter", lane := .«parallel» },
  { name := "comments", lane := .«parallel» },
  { name := "command-formatter", lane := .«parallel» },
  { name := "declaration-formatter", lane := .«parallel» },
  { name := "discovery", lane := .«parallel» },
  { name := "downstream", lane := .exclusive, slow := true },
  { name := "term-formatter", lane := .«parallel» },
  { name := "module-formatter", lane := .«parallel» },
  { name := "native-layout", lane := .workspace },
  { name := "performance", lane := .workspace, slow := true },
  { name := "stream", lane := .workspace, slow := true },
  { name := "style", lane := .«parallel» },
  { name := "suppression", lane := .workspace },
  { name := "syntax", lane := .workspace },
  { name := "validator", lane := .«parallel» },
  { name := "watch", lane := .exclusive },
  { name := "compiler", lane := .exclusive },
  { name := "format-suppression", lane := .«parallel» },
  { name := "formatter", lane := .«parallel» },
  { name := "formatter-adapter", lane := .«parallel» },
  { name := "application-formatter", lane := .workspace },
  { name := "boundary", lane := .«parallel» },
  { name := "incremental", lane := .«parallel» },
  { name := "imports", lane := .workspace },
  { name := "layout", lane := .«parallel» },
  { name := "lossless", lane := .«parallel» },
  { name := "lsp", lane := .workspace },
  { name := "modes", lane := .exclusive },
  { name := "reporting", lane := .workspace },
  { name := "scale", lane := .«parallel» },
  { name := "semantic", lane := .«parallel» },
  { name := "lsp-acceptance", lane := .exclusive, slow := true }
]

/-- What a run was asked to do. -/
structure Options where
  /-- Include `slow` suites. -/
  all : Bool := false
  /-- Run exactly these suites, ignoring the slow tag. -/
  suites : Option (Array String) := none
  /-- Print the registry and exit. -/
  list : Bool := false
  /-- Worker count for the non-exclusive lanes. -/
  jobs : Nat := 4
  /-- Do not run the unit tier first. -/
  skipUnit : Bool := false
  /-- Run only the unit tier. -/
  unitOnly : Bool := false

private def usage : String :=
  "usage: test-suites [--all] [--suites NAME...] [--list] [--jobs N] [--skip-unit] [--unit-only]"

private def parseArgs (args : List String) : Except String Options := do
  let arguments := args.toArray
  let mut options : Options := {}
  let mut index := 0
  while index < arguments.size do
    match arguments[index]! with
    | "--all" => options := { options with all := true }
    | "--list" => options := { options with list := true }
    | "--skip-unit" => options := { options with skipUnit := true }
    | "--unit-only" => options := { options with unitOnly := true }
    | "--jobs" =>
      index := index + 1
      match arguments[index]? with
      | some count =>
        match count.toNat? with
        | some jobs => options := { options with jobs := max jobs 1 }
        | none => throw s!"--jobs expects a number, got: {count}"
      | none => throw "--jobs expects a number"
    | "--suites" =>
      index := index + 1
      let mut names : Array String := #[]
      while index < arguments.size && !(arguments[index]!.startsWith "--") do
        names := names.push arguments[index]!
        index := index + 1
      if names.isEmpty then
        throw "--suites expects at least one name"
      index := index - 1
      options := { options with suites := some (options.suites.getD #[] ++ names) }
    | argument => throw s!"unknown argument: {argument}"
    index := index + 1
  return options

/-- The suites `options` selects, in registry order. An unknown name is an error, not a silent skip
— a typo must not produce a green run of the wrong set. -/
private def select (options : Options) : Except String (Array Suite) := do
  match options.suites with
  | some names =>
    let mut selected : Array Suite := #[]
    for name in names do
      match registered.find? (·.name == name) with
      | some suite => selected := selected.push suite
      | none => throw s!"unknown suite: {name} (registry: \
          {", ".intercalate (registered.map (·.name)).toList})"
    return selected
  | none =>
    return registered.filter fun suite => options.all || !suite.slow

/-- The recorded outcome of one suite run. -/
private structure Outcome where
  suite : Suite
  passed : Bool
  elapsedSec : Nat
  output : String

/-- Run one suite's executable, capturing everything it says. -/
private def runSuite (root : System.FilePath) (suite : Suite) : IO Outcome := do
  let started ← IO.monoNanosNow
  let result ← runProc (root / ".lake" / "build" / "bin" / suite.exeName).toString
    (cwd? := some root)
  let elapsedSec := ((← IO.monoNanosNow) - started) / 1000000000
  return { suite, passed := result.exitCode == 0, elapsedSec,
           output := result.stdout ++ result.stderr }

private def pad (text : String) (width : Nat) : String :=
  text ++ String.ofList (List.replicate (width - text.length) ' ')

/-- Print the per-suite line the way `run-all.sh` did: name, verdict, seconds. -/
private def report (outcome : Outcome) : IO Unit :=
  IO.println s!"{pad outcome.suite.name 28} {if outcome.passed then "PASS" else "FAIL"}  \
    {pad (toString outcome.elapsedSec) 4}s"

/-- Build every selected executable in one invocation, so the run itself contains no builds. -/
private def buildSuites (root : System.FilePath) (suites : Array Suite) : IO Unit := do
  -- The product binary is built alongside: every suite drives it, so a source edit that
  -- only rebuilds the suite would test a stale product.
  let result ← runProc "lake" (#["-q", "build", "lean-fmt"] ++ suites.map (·.exeName))
    (cwd? := some root)
  ensure (result.exitCode == 0) s!"suite executables failed to build:\n{result.stderr}"

/-- One worker of the lane pool: pull the next index, run it, record it, repeat. -/
private partial def worker (root : System.FilePath) (suites : Array Suite)
    (next : Std.Mutex Nat) (workspaceLock : Std.Mutex Unit)
    (collected : Std.Mutex (Array Outcome)) : IO Unit := do
  let index ← next.atomically fun state => do
    let index ← state.get
    state.set (index + 1)
    return index
  if index < suites.size then
    let suite := suites[index]!
    let outcome ←
      if suite.lane == .workspace then
        workspaceLock.atomically fun _ => runSuite root suite
      else
        runSuite root suite
    report outcome
    collected.atomically fun state => state.modify (·.push outcome)
    worker root suites next workspaceLock collected

/-- Run the non-exclusive lanes through a worker pool. `workspace` suites hold one lock, so they
serialize with each other while overlapping the `parallel` lane. -/
private def runLanes (root : System.FilePath) (suites : Array Suite) (jobs : Nat) :
    IO (Array Outcome) := do
  let next ← Std.Mutex.new 0
  let workspaceLock ← Std.Mutex.new ()
  let collected ← Std.Mutex.new (#[] : Array Outcome)
  let workers := min jobs (max suites.size 1)
  let tasks ← (List.range workers).mapM fun _ =>
    IO.asTask (worker root suites next workspaceLock collected) Task.Priority.dedicated
  for task in tasks do
    IO.ofExcept (← IO.wait task)
  collected.atomically fun state => state.get

end LeanFmt.Test.Runner

open LeanFmt.Test.Runner

public def main (args : List String) : IO UInt32 := do
  let options ← match parseArgs args with
    | .ok options => pure options
    | .error error => do
      IO.eprintln s!"{error}\n{usage}"
      return 2
  if options.list then
    for suite in registered do
      let tags := #[
        if suite.lane == .«parallel» then some "parallel" else none,
        if suite.lane == .workspace then some "workspace" else none,
        if suite.lane == .exclusive then some "exclusive" else none,
        if suite.slow then some "slow" else none].filterMap id
      IO.println s!"{pad suite.name 28} {", ".intercalate tags.toList}"
    return 0
  let root ← repoRoot
  let selected ← match select options with
    | .ok selected => pure selected
    | .error error => do
      IO.eprintln s!"{error}\n{usage}"
      return 2
  unless options.skipUnit do
    let code ← runCases "unit" allCases []
    unless code == 0 do
      IO.eprintln "the unit tier failed; suites not run (use --skip-unit to override)"
      return code
  if options.unitOnly then
    return 0
  if selected.isEmpty then
    IO.println "no suites selected"
    return 0
  buildSuites root selected
  let scratch ← IO.FS.createTempDir
  let keep ← IO.mkRef false
  try
    let (ordinary, exclusive) := selected.partition (·.lane != .exclusive)
    let ordinaryOutcomes ← runLanes root ordinary options.jobs
    let exclusiveOutcomes ← exclusive.mapM fun suite => do
      let outcome ← runSuite root suite
      report outcome
      return outcome
    let outcomes := ordinaryOutcomes ++ exclusiveOutcomes
    let failures := outcomes.filter (!·.passed)
    IO.println "\n--- slowest suites ---"
    let sorted := outcomes.qsort (·.elapsedSec > ·.elapsedSec)
    for outcome in sorted.toList.take 8 do
      IO.println s!"{pad (toString outcome.elapsedSec) 7}s  {outcome.suite.name}"
    if failures.isEmpty then
      IO.println s!"all {outcomes.size} suite(s) passed"
      return 0
    else
      -- The scratch directory is the failure report; keeping it is the point of printing its path.
      keep.set true
      for failure in failures do
        IO.FS.writeFile (scratch / s!"{failure.suite.name}.log") failure.output
      IO.eprintln s!"logs kept at {scratch}"
      IO.eprintln s!"{failures.size} suite(s) failed: \
        {", ".intercalate (failures.map (·.suite.name)).toList}"
      return 1
  finally
    unless ← keep.get do
      IO.FS.removeDirAll scratch
