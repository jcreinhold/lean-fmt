module

public import LeanFmt.Analysis
public import Test

import all LeanFmt.Analysis

/-!
# The incremental-analyzer suite

Port of `tests/fixtures/incremental/run.sh`, absorbing the `incremental-analyzer` subcommand it used to call
in the unit executable. The contract is the persistent frontend session's: an edit table varying
one concern at a time, full JSON envelopes compared against a fresh one-shot frontend, retained-
snapshot and memory bounds, cancellation, and a lifecycle counter accounting at the end. The old
script grepped the summary line; the counter `ensure` at the end of the run is strictly stronger
than that grep, and the line is still printed for the record.
-/

open LeanFmt LeanFmt.Internal
open LeanFmt.Test

namespace Incremental

private def incrementalSource (middle : String := "def beta : Nat := alpha + 2")
    (tail : String := "#check gamma") : String :=
  s!"module\nimport Lean\n\nnamespace IncrementalFixture\n\nsyntax \"twice \" term : term\nmacro_rules\n  | `(twice $value) => `($value + $value)\n\ndef alpha : Nat := 1\n{middle}\ndef gamma : Nat := twice beta\n\n{tail}\n\nend IncrementalFixture\n"

private def sameEnvelope (left right : AnalysisEnvelope) : Bool :=
  (Lean.toJson left).compress == (Lean.toJson right).compress

private def residentKiB : IO Nat := do
  let pid ← IO.Process.getPID
  let output ← IO.Process.output { cmd := "ps", args := #["-o", "rss=", "-p", toString pid] }
  return output.stdout.trimAscii.toString.toNat?.getD 0

/-! A focused executable-level contract for the persistent frontend session. The edit table varies
one concern at a time and compares the full JSON envelope with a fresh one-shot frontend, not merely
the formatted text. Pointer-sharing counts are observations of Lean's actual snapshot DAG. -/

private unsafe def incrementalAnalyzerSpec (setupPath sourcePath : String) : IO UInt32 := do
  let .ok setupJson := Lean.Json.parse (← IO.FS.readFile setupPath) | return 2
  let .ok (setup : Lean.ModuleSetup) := Lean.fromJson? setupJson | return 2
  let path : System.FilePath := sourcePath
  let analyzer ← IncrementalAnalyzer.open
  let base := incrementalSource
  -- Phase markers: this suite is one case, and on Linux CI it dies mid-case with no other
  -- witness — the last marker before a death is the only thing that names the phase.
  IO.eprintln "phase: edit table"
  let opened ← analyzer.analyze setup base path
  let freshBase ← analyzeExact setup base path
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
        (incrementalSource "def beta : Nat := alpha * 5").replace "import Lean"
          "import Lean\nimport Lean.Data.Json",
        false, true)]
  for (label, source, expectReuse, expectInvalidation) in cases do
    let result ← analyzer.analyze setup source path
    let fresh ← analyzeExact setup source path (loadDynlibs := false)
    ensure (sameEnvelope result.envelope fresh) s!"{label} incremental envelope differs from fresh"
    ensure (result.retainedSnapshots == 1) s!"{label} retained snapshot bound changed"
    ensure (result.invalidated == expectInvalidation)
        s!"{label} invalidation classification changed"
    if expectReuse then
      ensure (result.reusedCommands > 0) s!"{label} edit reused no command prefix"
  let alternateSetup := { setup with name := `IncrementalFixtureAlternate }
  let setupChanged ←
    analyzer.analyze alternateSetup (incrementalSource "def beta : Nat := alpha * 5") path
  let setupFresh ←
    analyzeExact alternateSetup (incrementalSource "def beta : Nat := alpha * 5") path
        (loadDynlibs := false)
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
  let repairedFresh ← analyzeExact setup lastGood path (loadDynlibs := false)
  ensure (sameEnvelope repaired.envelope repairedFresh && repaired.reusedCommands > 0)
      "repair did not resume from the last-good snapshot"
  let formatted ← analyzer.format setup lastGood path { lineWidth := 72 }
  let formattedFresh ←
    analyzeExact setup lastGood path (validateFormatDraft := true) (format := { lineWidth := 72 })
        (loadDynlibs := false)
  ensure (sameEnvelope formatted.envelope formattedFresh)
      "incremental format differs from fresh validated formatting"
  -- An editor keystroke pays one frontend, not two: the candidate is reparsed under the contexts
  -- this run already holds. The escalation path is correct but reimports, which on a mathlib
  -- document is the whole latency budget.
  ensure (formatted.envelope.canonical?.any (·.validation.frontendRuns == 1))
      "an interactive format elaborated its candidate a second time"
  let mut rss : Array Nat := #[]
  IO.eprintln "phase: hundred-edit loop"
  for i in [0:100]do
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
  IO.eprintln "phase: cancellation (1200 declarations)"
  -- 1200 declarations, not more: the file only has to be large enough that the analysis is
  -- still in flight when the cancel lands, and every extra declaration is peak resident
  -- memory against the full `import Lean` environment — 4000 of them pushed the suite past
  -- what a 16 GB CI runner holds even with nothing else on it.
  let mut slow := incrementalSource
  for i in [0:1200]do
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
  let afterCancel ← analyzer.analyze setup lastGood path
  ensure afterCancel.envelope.artifact?.isSome "session did not recover after cancellation"
  let counters ← analyzer.counters
  ensure
      (counters.updates >= 110 && counters.reusedCommands > 0 && counters.failed == 1 &&
          counters.cancelled == 1 &&
        counters.invalidated >= 2)
      "incremental counters do not account for the exercised lifecycle"
  IO.eprintln "phase: close"
  analyzer.close
  let rejected ←
    try
      let _ ← analyzer.analyze setup base path
      pure false
    catch error =>
      pure (error.toString.contains "closed")
  ensure rejected "closed analyzer accepted an update or failed for an unrelated reason"
  IO.println
      s!"incremental updates={counters.updates} reused={counters.reusedCommands} \
invalidated={counters.invalidated} failed={counters.failed} cancelled={counters.cancelled} \
rss_kib={rss} retained=1"
  return 0

/-- Drive the contract against the real fixture setup, as the old script did: `lake setup-file`
for the exact module context, then the session lifecycle. -/
private unsafe def testSessionContract : IO Unit := do
  let root ← repoRoot
  withTempDir fun work => do
      let setup ←
        expectExit 0 "lake setup-file" "lake"
            #["setup-file", "tests/fixtures/incremental/Fixture.lean"] (cwd? := some root)
      writeFile (work / "setup.json") setup.stdout
      let code ←
        incrementalAnalyzerSpec (work / "setup.json").toString
            (root / "tests" / "fixtures" / "incremental" / "Fixture.lean").toString
      ensure (code == 0) "the incremental session contract rejected its fixture"

private unsafe def cases : Array Case :=
  #[{ name := "session-contract", run := testSessionContract }]

end Incremental

public unsafe def main (args : List String) : IO UInt32 := do
  runCases "incremental" Incremental.cases args
