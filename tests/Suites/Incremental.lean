module

public import LeanFmt.Analysis
public import Test

import all LeanFmt.Analysis

/-!
# The incremental-analyzer suite

The persistent frontend session's contract: an edit table varying one concern at a time, full JSON
envelopes compared against a fresh one-shot frontend, retained-snapshot and memory bounds,
cancellation, and a lifecycle counter accounting at the end. The counters are asserted, not
grepped; the summary line is still printed for the record.
-/

open LeanFmt LeanFmt.Internal
open LeanFmt.Test

namespace Incremental

private def incrementalSource (middle : String := "def beta : Nat := alpha + 2")
    (tail : String := "#check gamma") : String :=
  s!"module\nimport Lean.Elab.Command\nimport Lean.Elab.MacroRules\nimport Lean.Elab.Syntax\n\nnamespace IncrementalFixture\n\nsyntax \"twice \" term : term\nmacro_rules\n  | `(twice $value) => `($value + $value)\n\ndef alpha : Nat := 1\n{middle}\ndef gamma : Nat := twice beta\n\n{tail}\n\nend IncrementalFixture\n"

/-- The session's envelope against the fresh oracle's compressed JSON — the only thing the
comparison ever reads, and therefore the only thing the child has to print. -/
private def sameEnvelope (left : AnalysisEnvelope) (freshJson : String) : Bool :=
  (Lean.toJson left).compress == freshJson

/-- The fresh-run oracle as a child process. A one-shot frontend's import environment (~1.6 GB
against `import Lean`) releases on process exit — immediately and totally — while the same load
in-process drains on the runtime's finalizer thread and stacks with the next one by an
unpredictable count; that stacking was the 2.5-11 GB peak that killed this suite on constrained
machines. The child is this same binary in `--fresh-once` mode, so the oracle is *more*
independent than before, not less: separate address space, separate runtime. -/
private unsafe def freshEnvelope (work setupPath : System.FilePath) (source : String)
    (sourcePath : System.FilePath) (validateFormat : Bool := false) : IO String := do
  let sourceFile := work / s!"fresh-{(← IO.monoMsNow)}.lean"
  writeFile sourceFile source
  let formatArgs := if validateFormat then #["--validate-format", "72"] else #[]
  let result ←
    expectExit 0 "fresh oracle" (← IO.appPath).toString
        (#["--fresh-once", setupPath.toString, sourceFile.toString, sourcePath.toString] ++
          formatArgs)
        (timeoutMs := some 600000)
  return result.stdout.trimAscii.toString

/-- `--fresh-once` mode: one fresh frontend run of a source file against a setup, printing the
envelope's compressed JSON. Suite-internal: the parent suite is the only caller. -/
private unsafe def freshOnce (args : List String) : IO UInt32 := do
  let (validateFormat, lineWidth, positional) ←
    match args with
    | [setupPath, sourceFile, sourcePath] =>
      pure (false, 100, (setupPath, sourceFile, sourcePath))
    | [setupPath, sourceFile, sourcePath, "--validate-format", width] =>
      match width.toNat? with
      | some lineWidth =>
        pure (true, lineWidth, (setupPath, sourceFile, sourcePath))
      | none =>
        return 2
    | _ =>
      return 2
  let (setupPath, sourceFile, sourcePath) := positional
  let .ok setupJson := Lean.Json.parse (← IO.FS.readFile setupPath) | return 2
  let .ok (setup : Lean.ModuleSetup) := Lean.fromJson? setupJson | return 2
  let source ← IO.FS.readFile sourceFile
  let envelope ←
    analyzeExact setup source sourcePath (loadDynlibs := false) (validateFormatDraft :=
        validateFormat) (format := if validateFormat then { lineWidth := lineWidth } else { })
  IO.println (Lean.toJson envelope).compress
  return 0

private def residentKiB : IO Nat := do
  let pid ← IO.Process.getPID
  let output ← IO.Process.output { cmd := "ps", args := #["-o", "rss=", "-p", toString pid] }
  return output.stdout.trimAscii.toString.toNat?.getD 0

/-- Resident memory at a phase boundary: the label, milliseconds since the session opened, and
the RSS sample. The hundred-edit loop proves the steady state shrinks; the boundaries are where
the peak actually lives — a header invalidation reloads the import environment, and
whether the superseded one is gone first is exactly the release-lag question. -/
private def phaseSample (samples : IO.Ref (Array (String × Nat × Nat))) (openedAt : Nat)
    (label : String) : IO Unit := do
  let now ← IO.monoMsNow
  let rss ← residentKiB
  samples.modify (·.push (label, now - openedAt, rss))

/-! A focused executable-level contract for the persistent frontend session. The edit table varies
one concern at a time and compares the full JSON envelope with a fresh one-shot frontend, not merely
the formatted text. Pointer-sharing counts are observations of Lean's actual snapshot DAG. -/

private unsafe def incrementalAnalyzerSpec (work setupPath sourcePath : String)
    (checkRatio : Bool := true) : IO UInt32 := do
  let .ok setupJson := Lean.Json.parse (← IO.FS.readFile setupPath) | return 2
  let .ok (setup : Lean.ModuleSetup) := Lean.fromJson? setupJson | return 2
  let work : System.FilePath := work
  let path : System.FilePath := sourcePath
  -- The thread-ratio baseline runs BEFORE the contract: this process ends the contract holding
  -- ~2.5 GB of deliberately persistent lineage environments, and a baseline child spawned then
  -- doubles the process tree's peak (5.4 GB, measured by the lane runner's tree sampler on the
  -- flake-hunt). Sequential runs peak at one contract's worth; the comparison still happens at
  -- the end, against this run's own peak. The gate guards the failure this suite used to die
  -- to — a 2.5-11 GB peak that flipped run to run at any thread count; the measured post-fix
  -- spread is ±7% around 2.5 GB at every count. `checkRatio` off is how `--peak-only` keeps
  -- this from recursing; the 8 GiB stop stays the last-resort kill, this is the regression gate.
  let childPeak? ←
    if checkRatio then
      do
        let baseline ←
          expectExit 0 "thread-ratio baseline" (← IO.appPath).toString
              #["--peak-only", work.toString, setupPath, sourcePath] (env :=
              #[("LEAN_NUM_THREADS", some "2")]) (timeoutMs := some 600000)
        match (baseline.stdout.splitOn "peak_kib=")[1]? with
        | some rest =>
          pure (rest.takeWhile Char.isDigit).toNat?
        | none =>
          pure none
    else
      pure none
  -- Phase markers: this suite is one case, and on Linux CI it dies mid-case with no other
  -- witness — the last marker before a death is the only thing that names the phase.
  let openedAt ← IO.monoMsNow
  let samples ← IO.mkRef (#[] : Array (String × Nat × Nat))
  IO.eprintln "phase: analyzer open"
  let analyzer ← IncrementalAnalyzer.open
  let base := incrementalSource
  IO.eprintln "phase: edit table"
  let opened ← analyzer.analyze setup base path
  let freshBase ← freshEnvelope work setupPath base path
  ensure (sameEnvelope opened.envelope freshBase) "initial incremental analysis differs from fresh"
  ensure (opened.retainedSnapshots == 1 && opened.invalidated)
      "open did not retain exactly one snapshot or establish a fresh lineage"
  let cases : Array (String × String × Bool × Bool) :=
    #[("tail", incrementalSource (tail := "#check gamma\n#check beta"), true, false),
      ("middle", incrementalSource "def beta : Nat := alpha + 3" "#check gamma\n#check beta", true,
        false),
      ("start",
        (incrementalSource "def beta : Nat := alpha + 3" "#check gamma\n#check beta").replace
          "def alpha : Nat := 1" "def alpha : Nat := 4",
        false, false),
      ("comment",
        (incrementalSource "def beta : Nat := alpha + 3" "#check gamma\n#check beta").replace
          "#check beta" "#check beta -- tail comment",
        true, false),
      ("declaration", incrementalSource "def beta : Nat := alpha * 5" "#check gamma", true, false),
      ("syntax",
        (incrementalSource "def beta : Nat := alpha * 5").replace "syntax \"twice \" term : term"
          "syntax \"twice \" term : term\nsyntax \"thrice \" term : term",
        false, false),
      ("header",
        (incrementalSource "def beta : Nat := alpha * 5").replace "import Lean.Elab.Syntax"
          "import Lean.Elab.Syntax\nimport Lean.Data.Json",
        false, true)]
  for (label, source, expectReuse, expectInvalidation) in cases do
    phaseSample samples openedAt s!"pre-{label}"
    let result ← analyzer.analyze setup source path
    phaseSample samples openedAt s!"{label}-session"
    let fresh ← freshEnvelope work setupPath source path
    phaseSample samples openedAt s!"{label}-fresh"
    ensure (sameEnvelope result.envelope fresh) s!"{label} incremental envelope differs from fresh"
    ensure (result.retainedSnapshots == 1) s!"{label} retained snapshot bound changed"
    ensure (result.invalidated == expectInvalidation)
        s!"{label} invalidation classification changed"
    if expectReuse then
      ensure (result.reusedCommands > 0) s!"{label} edit reused no command prefix"
  let alternateSetup := { setup with name := `IncrementalFixtureAlternate }
  let setupChanged ←
    analyzer.analyze alternateSetup (incrementalSource "def beta : Nat := alpha * 5") path
  writeFile (work / "alt-setup.json") (Lean.toJson alternateSetup).compress
  let setupFresh ←
    freshEnvelope work (work / "alt-setup.json") (incrementalSource "def beta : Nat := alpha * 5")
        path
  ensure
      (sameEnvelope setupChanged.envelope setupFresh && setupChanged.invalidated &&
        setupChanged.reusedCommands == 0)
      "module/setup identity crossed the snapshot reuse boundary"
  let lastGood := incrementalSource "def beta : Nat := alpha * 5"
  let restored ← analyzer.analyze setup lastGood path
  ensure restored.envelope.artifact?.isSome "last-good fixture did not elaborate"
  let malformed := lastGood.replace "def gamma : Nat := twice beta" "def gamma : Nat :="
  let failed ← analyzer.analyze setup malformed path
  ensure (failed.envelope.artifact?.isNone && failed.retainedSnapshots == 1)
      "malformed update replaced or discarded the last-good snapshot"
  let repaired ← analyzer.analyze setup lastGood path
  let repairedFresh ← freshEnvelope work setupPath lastGood path
  ensure (sameEnvelope repaired.envelope repairedFresh && repaired.reusedCommands > 0)
      "repair did not resume from the last-good snapshot"
  let formatted ← analyzer.format setup lastGood path { lineWidth := 72 }
  -- The format oracle runs at the session's 72-column contract (the child's `--validate-format`
  -- takes the width; both sides must agree on it).
  let formattedFresh ← freshEnvelope work setupPath lastGood path (validateFormat := true)
  ensure (sameEnvelope formatted.envelope formattedFresh)
      "incremental format differs from fresh validated formatting"
  -- An editor keystroke pays one frontend, not two: the candidate is reparsed under the contexts
  -- this run already holds. The escalation path is correct but reimports, which on a mathlib
  -- document is the whole latency budget.
  ensure (formatted.envelope.canonical?.any (·.validation.frontendRuns == 1))
      "an interactive format elaborated its candidate a second time"
  -- The editor shares the batch's exact candidate validation: unsaved bytes have no admitted
  -- frontier, so `--no-validate`'s bypass has nothing to stand on, and the policy field the
  -- batch threads never leaves it `.exact` here.
  ensure
      (formatted.envelope.canonical?.any fun canonical =>
        canonical.validation.idempotencePasses == 1 && !canonical.validation.bypassed)
      "an interactive format skipped exact candidate validation"
  let mut rss : Array Nat := #[]
  phaseSample samples openedAt "edit-table"
  IO.eprintln "phase: hundred-edit loop"
  for i in [0:100] do
    let value := if i % 2 == 0 then "6" else "7"
    let source := incrementalSource s!"def beta : Nat := alpha + {value}"
    let result ← analyzer.analyze setup source path
    ensure (result.retainedSnapshots == 1) "hundred-edit run retained snapshot history"
    if i == 24 || i == 49 || i == 74 || i == 99 then
      rss := rss.push (← residentKiB)
  ensure (rss.size == 4 && rss[3]! < 8 * 1024 * 1024)
      "hundred-edit process crossed the 8 GiB memory stop"
  ensure (rss[3]! <= rss[1]! + 256 * 1024)
      "resident memory did not stabilize over the final fifty updates"
  phaseSample samples openedAt "hundred-edit-loop"
  IO.eprintln "phase: cancellation (1200 declarations)"
  -- 1200 declarations, not more: the file only has to be large enough that the analysis is
  -- still in flight when the cancel lands, and every extra declaration is peak resident
  -- memory against the import environment — 4000 of them pushed the suite past what a
  -- 16 GB CI runner holds even with nothing else on it.
  let mut slow := incrementalSource
  for i in [0:1200] do
    slow := slow ++ s!"def cancellation_{i} : Nat := {i}\n"
  let task ← IO.asTask (analyzer.analyze setup slow path)
  let rec waitForFlight (fuel : Nat) : IO Unit := do
    if fuel == 0 then
      return
    if ← analyzer.isRunning then
      return
    IO.sleep 1
    waitForFlight (fuel - 1)
  waitForFlight 1000
  analyzer.cancel
  let .ok cancelled :=
    task.get | throw <| IO.userError "cancelled analyzer task raised an infrastructure error"
  ensure cancelled.cancelled "in-flight update did not observe cancellation"
  ensure (cancelled.retainedSnapshots == 1) "cancelled update poisoned last-good state"
  phaseSample samples openedAt "cancelled"
  let afterCancel ← analyzer.analyze setup lastGood path
  ensure afterCancel.envelope.artifact?.isSome "session did not recover after cancellation"
  phaseSample samples openedAt "recovered"
  let counters ← analyzer.counters
  ensure
      (counters.updates >= 110 && counters.reusedCommands > 0 && counters.failed == 1 &&
        counters.cancelled == 1 &&
        counters.invalidated >= 2)
      "incremental counters do not account for the exercised lifecycle"
  IO.eprintln "phase: close"
  analyzer.close
  phaseSample samples openedAt "closed"
  let rejected ←
    try
      let _ ← analyzer.analyze setup base path
      pure false
    catch error =>
      pure (error.toString.contains "closed")
  ensure rejected "closed analyzer accepted an update or failed for an unrelated reason"
  let peak := ((← samples.get).map (·.2.2)).foldl max (rss.foldl max 0)
  let curve := (← samples.get).toList.map fun (label, ms, kib) => s!"{label}@+{ms}ms={kib}KiB"
  IO.println
      s!"incremental updates={counters.updates} reused={counters.reusedCommands} \
invalidated={counters.invalidated} failed={counters.failed} cancelled={counters.cancelled} \
rss_kib={rss} retained=1 peak_kib={peak} phases={curve}"
  if checkRatio then
    let some childPeak := childPeak?
      | throw <| IO.userError "thread-ratio baseline did not report a peak"
    ensure (peak * 2 <= childPeak * 3 && childPeak * 2 <= peak * 3)
        s!"memory peak is not thread-count independent: {peak} KiB here vs {childPeak} KiB at \
LEAN_NUM_THREADS=2 (1.5× either way is the bound)"
  return 0

/-- Drive the contract against the real fixture setup: `lake setup-file` for the exact module
context, then the session lifecycle. -/
private unsafe def testSessionContract : IO Unit := do
  let root ← repoRoot
  withTempDir fun work => do
      let setup ←
        expectExit 0 "lake setup-file" "lake"
            #["setup-file", "tests/fixtures/incremental/Fixture.lean"] (cwd? := some root)
      writeFile (work / "setup.json") setup.stdout
      let code ←
        incrementalAnalyzerSpec work.toString (work / "setup.json").toString
            (root / "tests" / "fixtures" / "incremental" / "Fixture.lean").toString
      ensure (code == 0) "the incremental session contract rejected its fixture"

private unsafe def cases : Array Case :=
  #[{ name := "session-contract", run := testSessionContract }]

end Incremental

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | "--fresh-once" :: rest =>
    Incremental.freshOnce rest
  | ["--peak-only", work, setupPath, sourcePath] =>
    do
      -- The thread-ratio baseline run: the full contract with the ratio check itself off,
      -- or every baseline would spawn another baseline.
      Incremental.incrementalAnalyzerSpec work setupPath sourcePath (checkRatio := false)
  | _ =>
    runCases "incremental" Incremental.cases args
