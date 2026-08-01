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

def Suite.exeName (suite : Suite) : String :=
  s!"suite-{suite.name}"

/-- The suite registry. Adding a suite is a `lean_exe «suite-<name>»` in the lakefile plus one
line here; a name in either place but not the other fails loudly (the build step for the first,
this list for the second). -/
private def registered : Array Suite :=
  #[{ name := "block-formatter", lane := .«parallel» }, { name := "cache", lane := .workspace },
    { name := "catalog", lane := .workspace }, { name := "check", lane := .workspace },
    { name := "ci", lane := .exclusive, slow := true },
    { name := "collection-formatter", lane := .«parallel» },
    { name := "comments", lane := .«parallel» },
    { name := "command-formatter", lane := .«parallel» },
    { name := "declaration-formatter", lane := .«parallel» },
    { name := "discovery", lane := .«parallel» },
    { name := "downstream", lane := .exclusive, slow := true },
    { name := "editor", lane := .exclusive, slow := true },
    { name := "term-formatter", lane := .«parallel» },
    { name := "module-formatter", lane := .«parallel» },
    { name := "native-layout", lane := .workspace },
    { name := "performance", lane := .workspace, slow := true },
    { name := "stream", lane := .workspace, slow := true },
    { name := "style", lane := .«parallel» }, { name := "suppression", lane := .workspace },
    { name := "syntax", lane := .workspace }, { name := "validator", lane := .«parallel» },
    { name := "watch", lane := .exclusive }, { name := "compiler", lane := .exclusive },
    { name := "format-suppression", lane := .«parallel» },
    { name := "formatter", lane := .«parallel» },
    { name := "formatter-adapter", lane := .«parallel» },
    { name := "application-formatter", lane := .workspace },
    { name := "boundary", lane := .«parallel» },
    -- Exclusive, and out of the default set for memory rather than wall time — but not the way
    -- the CI legs first suggested: the suite is thread-starved, not platform-cursed. At
    -- LEAN_NUM_THREADS=2 its persistent session peaks at 4.9 GB even on macOS (2.6 GB
    -- uncapped); on 2–4 core machines elaboration outruns finalization of released
    -- environments and the OOM killer ends it. It runs alone at the end of `--all`, and
    -- returns to CI when the session bounds retention. docs/ci.md's ledger has the evidence.
    { name := "incremental", lane := .exclusive, slow := true },
    { name := "imports", lane := .workspace }, { name := "layout", lane := .«parallel» },
    { name := "lossless", lane := .«parallel» }, { name := "lsp", lane := .workspace },
    { name := "modes", lane := .exclusive }, { name := "reporting", lane := .workspace },
    { name := "scale", lane := .«parallel» },
    { name := "security-bench", lane := .«parallel», slow := true },
    { name := "semantic", lane := .«parallel» },
    { name := "lsp-acceptance", lane := .exclusive, slow := true }]

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
  /-- Partition the selected suites modulo the count and run partition INDEX (one-based — the
  same convention as the case harness's `--part`), so a CI matrix of `1/3 … 3/3` covers the
  registry exactly once and a suite added to the registry joins a part without a workflow
  edit. -/
  part : Option (Nat × Nat) := none

private def usage : String :=
  "usage: test-suites [--all] [--suites NAME...] [--list] [--jobs N] [--skip-unit] [--unit-only] \
    [--part INDEX/COUNT]"

private def parseArgs (args : List String) : Except String Options := do
  let arguments := args.toArray
  let mut options : Options := { }
  let mut index := 0
  while index < arguments.size do
    match arguments[index]! with
    | "--all" =>
      options := { options with all := true }
    | "--list" =>
      options := { options with list := true }
    | "--skip-unit" =>
      options := { options with skipUnit := true }
    | "--unit-only" =>
      options := { options with unitOnly := true }
    | "--jobs" =>
      index := index + 1
      match arguments[index]? with
      | some count =>
        match count.toNat? with
        | some jobs =>
          options := { options with jobs := max jobs 1 }
        | none =>
          throw s!"--jobs expects a number, got: {count}"
      | none =>
        throw "--jobs expects a number"
    | "--part" =>
      index := index + 1
      match arguments[index]? with
      | some spec =>
        match spec.splitOn "/" with
        | [indexText, countText] =>
          match indexText.toNat?, countText.toNat? with
          | some partIndex, some count =>
            if 1 ≤ partIndex && partIndex ≤ count then
              options := { options with part := some (partIndex, count) }
            else
              throw s!"--part expects 1 ≤ INDEX ≤ COUNT, got: {spec}"
          | _, _ =>
            throw s!"--part expects INDEX/COUNT, got: {spec}"
        | _ =>
          throw s!"--part expects INDEX/COUNT, got: {spec}"
      | none =>
        throw "--part expects INDEX/COUNT"
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
    | argument =>
      throw s!"unknown argument: {argument}"
    index := index + 1
  return options

/-- The suites `options` selects, in registry order. An unknown name is an error, not a silent skip
— a typo must not produce a green run of the wrong set. -/
private def select (options : Options) : Except String (Array Suite) := do
  let selected ←
    match options.suites with
    | some names =>
      let mut chosen : Array Suite := #[]
      for name in names do
        match registered.find? (·.name == name) with
        | some suite =>
          chosen := chosen.push suite
        | none =>
          throw
              s!"unknown suite: {name} (registry: \
            {", ".intercalate (registered.map (·.name)).toList})"
      pure chosen
    | none =>
      pure <| registered.filter fun suite => options.all || !suite.slow
  match options.part with
  | none =>
    return selected
  | some (index, count) =>
    -- Deal each lane separately. Workspace suites serialize inside a job and exclusive suites
    -- run alone, so one modulo over the mixed list clusters the expensive tails into one part —
    -- the first CI run put cache, layout, and modes together and let them set its wall time.
    let mut picked : Array Suite := #[]
    for lane in [Lane.«parallel», Lane.workspace, Lane.exclusive]do
      let inLane := selected.filter (·.lane == lane)
      for position in [:inLane.size]do
        if position % count == index - 1 then
          picked := picked.push inLane[position]!
    return picked

/-- The recorded outcome of one suite run. -/
private structure Outcome where
  suite : Suite
  passed : Bool
  elapsedSec : Nat
  peakRssKb : Nat
  output : String

/-- Resident KiB of `rootPid` and every descendant in one `ps -Ao rss=,pid=,ppid=` snapshot.
A suite's frontend grandchildren are where the envelope actually goes, so the suite process
alone would undercount by an order of magnitude. -/
private def treeRssKb (snapshot : String) (rootPid : Nat) : Nat :=
  Id.run do
    let mut entries : Array (Nat × Nat × Nat) := #[]
    for line in snapshot.splitOn "\n"do
      let words := (line.trimAscii.toString.splitOn " ").filter (!·.isEmpty)
      if let [rss, pid, ppid] := words then
        if let (some rssKb, some pid, some ppid) := (rss.toNat?, pid.toNat?, ppid.toNat?) then
          entries := entries.push (rssKb, pid, ppid)
    let mut included : Array Nat := #[rootPid]
    let mut changed := true
    while changed do
      changed := false
      for (_, pid, ppid) in entries do
        if !included.contains pid && included.contains ppid then
          included := included.push pid
          changed := true
    return entries.foldl (init := 0) fun acc (rssKb, pid, _) =>
        if included.contains pid then acc + rssKb else acc

/-- Poll a suite child to completion, sampling its process tree's resident memory once a
second into `peak`. Unbounded on purpose: a wedged suite must hang with its heartbeat as
evidence (and the CI step timeout as the bound), not be killed into a false failure by a fuel
count. -/
private partial def suitePoll (child : IO.Process.Child ⟨.null, .piped, .piped⟩)
    (peak : IO.Ref Nat) : IO UInt32 := do
  if let some code← child.tryWait then
    return code
  let snapshot ← IO.Process.output { cmd := "ps", args := #["-Ao", "rss=,pid=,ppid="] }
  peak.modify (max · (treeRssKb snapshot.stdout child.pid.toNat))
  IO.sleep 1000
  suitePoll child peak

/-- Run one suite's executable, capturing everything it says, and sample its process tree's
resident memory once a second: the number printed next to a suite's wall time is the envelope a
CI job must budget for it, discovered while the run is green instead of by a dead runner. The
sample is a floor, not a bound — a spike shorter than the interval is invisible to it. -/
private def runSuite (root : System.FilePath) (suite : Suite) : IO Outcome := do
  let started ← IO.monoNanosNow
  let child ←
    IO.Process.spawn
        { cmd := (root / ".lake" / "build" / "bin" / suite.exeName).toString, cwd := some root
          env := scrubbedSearchPaths, stdin := .null, stdout := .piped, stderr := .piped }
  let stdoutTask ← IO.asTask child.stdout.readToEnd Task.Priority.dedicated
  let stderrTask ← IO.asTask child.stderr.readToEnd Task.Priority.dedicated
  let peak ← IO.mkRef 0
  let exitCode ← suitePoll child peak
  let stdout ← IO.ofExcept stdoutTask.get
  let stderr ← IO.ofExcept stderrTask.get
  let elapsedSec := ((← IO.monoNanosNow) - started) / 1000000000
  return { suite, passed := exitCode == 0, elapsedSec, peakRssKb := ← peak.get,
           output := stdout ++ stderr }

private def pad (text : String) (width : Nat) : String :=
  text ++ String.ofList (List.replicate (width - text.length) ' ')

/-- Print the per-suite line the way `run-all.sh` did: name, verdict, seconds. -/
private def report (outcome : Outcome) : IO Unit := do
  IO.println
      s!"{pad outcome.suite.name 28} {if outcome.passed then "PASS" else "FAIL"}  \
    {pad (toString outcome.elapsedSec) 4}s"
  -- A pipe block-buffers stdout, and CI reads through one: flush per suite or a killed run
  -- shows nothing of what finished before the kill.
  (← IO.getStdout).flush

/-- The lines of a failure's captured output worth reading without opening the log: assertion
failures and compiler errors from any build the suite ran, each with its following (indented)
message line. The full output stays in the log; this is the difference between "six suites
failed" and "six suites failed for one reason, visible here". -/
private def digestLines (output : String) : Array String :=
  Id.run do
    let lines := output.splitOn "\n"
    let mut picked : Array String := #[]
    for i in [:lines.length]do
      let line := lines[i]!
      if line.startsWith "FAIL" || line.contains "error:" then
        picked := picked.push line
        -- Followers carry the assertion's evidence (`expected:`/`actual:` pairs indent under
        -- the label; the cache suite's epoch forensics trail them), capped only so one
        -- pathological failure cannot crowd out the others — evidence is the point here.
        let mut j := i + 1
        while j < lines.length && j ≤ i + 48 && lines[j]!.startsWith " " do
          picked := picked.push lines[j]!
          j := j + 1
    if picked.size > 64 then
      picked.extract 0 64 |>.push "  …"
    else
      picked

/-- Build every selected executable in one invocation, so the run itself contains no builds. -/
private def buildSuites (root : System.FilePath) (suites : Array Suite) : IO Unit := do
  -- The product binary is built alongside: every suite drives it, so a source edit that
  -- only rebuilds the suite would test a stale product.
  let result ←
    runProc "lake" (#["-q", "build", "lean-fmt"] ++ suites.map (·.exeName)) (cwd? := some root)
  -- Both streams: `lake -q` puts the failed job's log on stdout, and stderr alone showed
  -- "error: build failed" with the cause nowhere — the flake-hunt's slow step failed
  -- anonymous exactly once before this carried both.
  ensure (result.exitCode == 0)
      s!"suite executables failed to build:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"

/-- One worker of the lane pool: pull the next index, run it, record it, repeat. -/
private partial def worker (root : System.FilePath) (suites : Array Suite) (next : Std.Mutex Nat)
    (workspaceLock : Std.Mutex Unit) (collected : Std.Mutex (Array Outcome)) : IO Unit := do
  let index ←
    next.atomically fun state => do
        let index ← state.get
        state.set (index + 1)
        return index
  if index < suites.size then
    let suite := suites[index]!
    -- stderr is unbuffered even through a pipe: the last heartbeat before a wedge names the
    -- suite that hung, which the completion line — printed only after — never can.
    IO.eprintln s!"starting {suite.name}"
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
  let tasks ←
    (List.range workers).mapM fun _ =>
        IO.asTask (worker root suites next workspaceLock collected) Task.Priority.dedicated
  for task in tasks do
    IO.ofExcept (← IO.wait task)
  collected.atomically fun state => state.get

end LeanFmt.Test.Runner

open LeanFmt.Test.Runner

public def main (args : List String) : IO UInt32 := do
  let options ←
    match parseArgs args with
    | .ok options =>
      pure options
    | .error error =>
      do
        IO.eprintln s!"{error}\n{usage}"
        return 2
  if options.list then
    for suite in registered do
      let tags :=
        #[if suite.lane == .«parallel» then some "parallel" else none,
              if suite.lane == .workspace then some "workspace" else none,
              if suite.lane == .exclusive then some "exclusive" else none,
              if suite.slow then some "slow" else none].filterMap
          id
      IO.println s!"{pad suite.name 28} {", ".intercalate tags.toList}"
    return 0
  let root ← repoRoot
  let selected ←
    match select options with
    | .ok selected =>
      pure selected
    | .error error =>
      do
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
    let exclusiveOutcomes ←
      exclusive.mapM fun suite => do
          IO.eprintln s!"starting {suite.name}"
          let outcome ← runSuite root suite
          report outcome
          return outcome
    let outcomes := ordinaryOutcomes ++ exclusiveOutcomes
    let failures := outcomes.filter (!·.passed)
    IO.println "\n--- slowest suites ---"
    let sorted := outcomes.qsort (·.elapsedSec > ·.elapsedSec)
    for outcome in sorted.toList.take 8do
      IO.println s!"{pad (toString outcome.elapsedSec) 7}s  {outcome.suite.name}"
    -- Peak RSS is a count, not a wall time: the envelope a CI job budgets per suite, measured
    -- while the run is green. One-second sampling can miss shorter spikes; this is for
    -- envelope planning, and no assertion reads it yet.
    IO.println "\n--- heaviest suites (peak RSS, sampled) ---"
    let heaviest := outcomes.qsort (·.peakRssKb > ·.peakRssKb)
    for outcome in heaviest.toList.take 8do
      IO.println s!"{pad (toString (outcome.peakRssKb / 1024)) 7}MB  {outcome.suite.name}"
    if failures.isEmpty then
      IO.println s!"all {outcomes.size} suite(s) passed"
      return 0
    else
      -- The scratch directory is the failure report; keeping it is the point of printing its path.
      keep.set true
      for failure in failures do
        IO.FS.writeFile (scratch / s!"{failure.suite.name}.log") failure.output
        let digest := digestLines failure.output
        unless digest.isEmpty do
          IO.eprintln s!"--- {failure.suite.name} ---"
          for line in digest do
            IO.eprintln line
      IO.eprintln s!"logs kept at {scratch}"
      IO.eprintln
          s!"{failures.size} suite(s) failed: \
        {", ".intercalate (failures.map (·.suite.name)).toList}"
      return 1
  finally
    unless ← keep.get do
      IO.FS.removeDirAll scratch
