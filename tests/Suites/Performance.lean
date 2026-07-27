module

public import Test

/-!
# The performance suite

Port of `tests/performance/run.sh`: durable per-commit performance gates.

It does not assert a wall time. The same unchanged binary was measured
over the same warm corpus at 3,977 ms and at 19,968 ms depending on nothing but what else the machine was doing, so
every gate is a **count, a ratio, or a digest** — quantities that do not move when the machine
gets slower. What they catch is a change in the work performed, which is what a performance
regression actually is.

The gate predicates are pure functions over the profile channel, defined once in this module and
used twice: the `gates-discriminate` case is the native form of `negative.sh`, feeding every
predicate both input it must accept and input it must reject — a gate that cannot fail would
report a healthy tree exactly as convincingly as `true` does. The remaining cases are `run.sh`'s
real runs. Lane: workspace+slow — the suite primes the root result cache and builds one artifact
fixture.
-/

open LeanFmt.Test

namespace Performance

-- -----------------------------------------------------------------------------------------------
-- The gate predicates (`gates.sh`). Reporting belongs to the caller; these are pure.

/-- The top-level phase names. Sub-phases nest inside a top-level bracket, so counting both
double-counts the same milliseconds; this list is the complement of the bold rows in
`LeanFmt/Profile.lean`'s phase table. -/
private def topLevelPhases : List String :=
  ["discovery", "workspace_load", "selection_snapshot", "cache_epoch", "cache_lookup",
   "module_evidence", "official_artifacts", "import_findings", "exact_setup", "setup_prime",
   "exact_child", "artifact_setup", "artifact_child", "envelope_decode", "layout", "rules",
   "cache_write", "positions", "render_report"]

/-- The last value of a `cache.*` counter, or none if the run never emitted it. -/
private def counter (name : String) (capture : String) : Option Int :=
  ((capture.splitOn "\n").filterMap fun line =>
    if line.startsWith s!"{name}=" then (line.drop (name.length + 1)).toString.toInt? else none)
  |>.reverse |>.head?

/-- The summed milliseconds of one phase across every site that emitted it. -/
private def phaseSum (name : String) (capture : String) : Nat :=
  (((capture.splitOn "\n").filterMap fun line =>
    if line.startsWith s!"phase.{name}_ms=" then
      ((line.drop ("phase.".length + name.length + 4)).toString.toNat?)
    else none).foldl (· + ·) 0)

/-- How many times one phase was emitted. A count, so it is machine-speed independent. -/
private def phaseCount (name : String) (capture : String) : Nat :=
  ((capture.splitOn "\n").filter (·.startsWith s!"phase.{name}_ms=")).length

/-- Milliseconds attributed to top-level phases — the numerator of gate G3. -/
private def accounted (capture : String) : Nat :=
  topLevelPhases.foldl (fun total name => total + phaseSum name capture) 0

/-- §0b. Every custom document node is visited once and every mark adds one close sentinel, over
all eight adversarial rows. -/
private def gateDocStepsLinear (report : String) : Bool :=
  let rows := (report.splitOn "\n").filter (·.startsWith "doc-steps ")
  rows.length == 8 && rows.all fun row =>
    let value (key : String) : Option Nat :=
      ((row.splitOn " ").filterMap fun field =>
        if field.startsWith s!"{key}=" then
          ((field.drop (key.length + 1)).toString.toNat?)
        else none).head?
    match value "nodes", value "steps", value "marks", value "native" with
    | some nodes, some steps, some marks, some native => steps == nodes + marks && native == 0
    | _, _, _, _ => false

/-- §1a. The run saw exactly the workload it was handed. -/
private def gateTargetsMatch (capture : String) (expected : Nat) : Bool :=
  counter "cache.targets" capture == some expected

/-- §1b. Every target was an index hit and was served from it — the cache-identity gate. -/
private def gateFullyServed (capture : String) : Bool :=
  match counter "cache.targets" capture, counter "cache.index_hits" capture,
      counter "cache.served" capture with
  | some targets, some hits, some served => hits == targets && served == targets
  | _, _, _ => false

/-- §1c. A fully served run never reaches the exact frontend or resolves a per-target setup. -/
private def gateNoFrontendWork (capture : String) : Bool :=
  phaseCount "exact_child" capture == 0 && phaseCount "exact_setup" capture == 0

/-- The observed child admissions, in order. -/
private def activeChildren (capture : String) : List Nat :=
  (capture.splitOn "\n").filterMap fun line =>
    if line.startsWith "cache.active_children=" then
      (line.drop "cache.active_children=".length).toString.toNat?
    else none

/-- §1d. Every admission is the sole active child, and the capture holds the expected count — the
second clause prevents an empty profile from proving seriality. -/
private def gateSerialChildren (capture : String) (expected : Nat) : Bool :=
  let admissions := activeChildren capture
  admissions.length == expected && admissions.all (· < 2)

/-- §1f. With `--workers N` every admission observes no more than N active children, at least one
observes exactly N (a serial regression must not pass as parallel), and the count matches. -/
private def gateParallelChildren (capture : String) (jobs expected : Nat) : Bool :=
  let admissions := activeChildren capture
  admissions.length == expected && admissions.any (· == jobs) && admissions.all (· ≤ jobs)

/-- §1g. The run resolved the worker count it was asked for. `--workers` decides it when given;
otherwise the run takes `LEAN_NUM_THREADS`, else the machine's core count — the rule Lake uses to
size its own build. A capture with no `cache.workers` at all fails, so a run that stopped recording
its intent cannot pass as one that chose correctly. -/
private def gateWorkers (capture : String) (expected : Nat) : Bool :=
  counter "cache.workers" capture == some expected

/-- §1e. Artifact formatting avoids the exact-source child; the forced exact run really exercises
it. Both still validate canonical output. -/
private def gateArtifactAvoidsExact (artifactCapture exactCapture : String) : Bool :=
  phaseCount "artifact_child" artifactCapture == 1
    && phaseCount "exact_child" artifactCapture == 0
    && counter "cache.path_artifact_render" artifactCapture == some 1
    && phaseCount "artifact_child" exactCapture == 0
    && phaseCount "exact_child" exactCapture == 1
    && counter "cache.path_exact_render" exactCapture == some 1

/-- §2. Gate G3, recalibrated onto the remainder: the unaccounted time is a ~51 ms startup
constant, so a percentage threshold is workload-length-dependent and a remainder threshold is
not. -/
private def gateRemainderWithin (capture : String) (wall bound : Nat) : Bool :=
  wall - accounted capture ≤ bound

/-- §3. One named phase both exists and measured something — the `withPhase <| pure e` defect
class, which reads 0 ms forever and looks like speed. -/
private def gatePhaseMeasures (capture : String) (name : String) : Bool :=
  phaseCount name capture > 0 && phaseSum name capture > 0

/-- §4. The report did not change — the one gate not satisfiable by doing less work and getting
the answer wrong. -/
private def gateReportsIdentical (a b : String) : Bool := a == b

-- -----------------------------------------------------------------------------------------------
-- §0 the gates themselves discriminate (`negative.sh`, native). Each predicate sees input it must
-- accept and input it must reject; only the pair pins the behavior.

/-- A healthy warm capture: 45 targets, all hit and served, no frontend work, phases that
measure. -/
private def healthy : String :=
  "cache.targets=45\ncache.index_hits=45\ncache.served=45\nphase.discovery_ms=7\n\
   phase.workspace_load_ms=515\nphase.selection_snapshot_ms=5\nphase.cache_epoch_ms=5\n\
   phase.cache_lookup_ms=139\nphase.import_findings_ms=27\nphase.positions_ms=17\n\
   phase.render_report_ms=0\n"

private def docHealthy : String :=
  "doc-steps label=zero-width-siblings n=1000 nodes=4001 steps=4001 marks=0 native=0\n\
   doc-steps label=zero-width-nesting n=1000 nodes=2001 steps=2001 marks=0 native=0\n\
   doc-steps label=call-args n=1000 nodes=6005 steps=6005 marks=0 native=0\n\
   doc-steps label=marked-call-args n=1000 nodes=7005 steps=8005 marks=1000 native=0\n\
   doc-steps label=zero-width-siblings n=8000 nodes=32001 steps=32001 marks=0 native=0\n\
   doc-steps label=zero-width-nesting n=8000 nodes=16001 steps=16001 marks=0 native=0\n\
   doc-steps label=call-args n=8000 nodes=48005 steps=48005 marks=0 native=0\n\
   doc-steps label=marked-call-args n=8000 nodes=56005 steps=64005 marks=8000 native=0\n"

private def testGatesDiscriminate : IO Unit := do
  let expect (holds : Bool) (description : String) : IO Unit :=
    ensure holds description
  -- §0b renderer work is linear in nodes plus marks.
  expect (gateDocStepsLinear docHealthy) "accepts eight renderer rows with steps = nodes + marks"
  expect (!(gateDocStepsLinear (docHealthy.replace "nodes=32001 steps=32001"
    "nodes=32001 steps=64001"))) "rejects a zero-width suffix rescan doubling renderer work"
  expect (!(gateDocStepsLinear ("\n".intercalate (docHealthy.splitOn "\n" |>.take 7))))
    "rejects a truncated renderer report that omits one adversarial row"
  -- §1a the workload is the one that was handed over.
  expect (gateTargetsMatch healthy 45) "accepts a run over all 45 targets"
  expect (!(gateTargetsMatch (healthy.replace "cache.targets=45" "cache.targets=44") 45))
    "rejects a run that quietly processed 44 of 45 files"
  -- §1b every target served from the index.
  expect (gateFullyServed healthy) "accepts 45 targets, 45 hits, 45 served"
  expect (!(gateFullyServed ((healthy.replace "cache.index_hits=45" "cache.index_hits=41")
    |>.replace "cache.served=45" "cache.served=41")))
    "rejects 4 cache misses on a warm run (the cache-identity regression)"
  let noCounters := "\n".intercalate ((healthy.splitOn "\n").filter (!·.startsWith "cache."))
  expect (!(gateFullyServed noCounters)) "rejects a capture with no cache counters at all"
  -- §1c no frontend work on a served run.
  expect (gateNoFrontendWork healthy) "accepts a capture with neither exact_child nor exact_setup"
  expect (!(gateNoFrontendWork (healthy ++ "phase.exact_child_ms=2058\n")))
    "rejects a served run that still spawned a frontend child"
  expect (!(gateNoFrontendWork (healthy ++ "phase.exact_setup_ms=0\n")))
    "rejects a per-target setup resolution, even one costing 0 ms"
  -- §1d child admission stays serial.
  let serial := "cache.active_children=1\ncache.active_children=1\n"
  expect (gateSerialChildren serial 2) "accepts two sequential child admissions"
  expect (!(gateSerialChildren "cache.active_children=1\ncache.active_children=2\n" 2))
    "rejects a second concurrently active child"
  expect (!(gateSerialChildren healthy 2)) "rejects an empty child profile"
  -- §1f parallel admission stays within --workers.
  let bounded := "cache.active_children=1\ncache.active_children=2\n"
  expect (gateParallelChildren bounded 2 2) "accepts two bounded concurrent admissions"
  expect (!(gateParallelChildren "cache.active_children=1\ncache.active_children=3\n" 2 2))
    "rejects a third child under --workers 2"
  expect (!(gateParallelChildren serial 2 2)) "rejects no observed concurrency under --workers 2"
  expect (!(gateParallelChildren bounded 2 3)) "rejects a missing admission under --workers 2"
  -- §1g the run resolved the worker count it was asked for.
  expect (gateWorkers "cache.workers=6\n" 6) "accepts six resolved workers when six were asked for"
  expect (!(gateWorkers "cache.workers=1\n" 6))
    "rejects a run that fell back to one worker (the pre-uncapped default)"
  expect (!(gateWorkers healthy 6)) "rejects a capture that recorded no worker count"
  -- §1e artifact formatting avoids exact-source analysis.
  let artifactCapture := "phase.artifact_child_ms=900\ncache.path_artifact_render=1\n"
  let exactCapture := "phase.exact_child_ms=1500\ncache.path_exact_render=1\n"
  expect (gateArtifactAvoidsExact artifactCapture exactCapture)
    "accepts one artifact child versus one forced exact child"
  expect (!(gateArtifactAvoidsExact (artifactCapture ++ "phase.exact_child_ms=1500\n")
    exactCapture)) "rejects an artifact route that also launches the exact-source child"
  -- §2 gate G3, on the remainder. The healthy capture accounts for 715 ms.
  expect (gateRemainderWithin healthy 760 250)
    "accepts a 45 ms remainder (the measured ~51 ms startup constant)"
  expect (!(gateRemainderWithin healthy 1500 250))
    "rejects 785 ms of work happening outside every top-level phase"
  expect (!(gateRemainderWithin healthy 966 250))
    "rejects a remainder one millisecond over the bound"
  -- §3 no phase silently measures nothing.
  expect (gatePhaseMeasures healthy "positions") "accepts positions at 17 ms"
  expect (!(gatePhaseMeasures (healthy.replace "phase.positions_ms=17" "phase.positions_ms=0")
    "positions")) "rejects positions reading 0 ms over 2 MB (the withPhase <| pure e defect)"
  let noPositions := "\n".intercalate ((healthy.splitOn "\n").filter
    (!·.startsWith "phase.positions_ms="))
  expect (!(gatePhaseMeasures noPositions "positions")) "rejects positions never emitted at all"
  -- §4 the report did not change.
  let reportA := "LeanFmt/Cli.lean:1:1: FMT001 example\n"
  expect (gateReportsIdentical reportA reportA) "accepts two identical reports"
  expect (!(gateReportsIdentical reportA "LeanFmt/Cli.lean:1:2: FMT001 example\n"))
    "rejects reports differing by one column"

-- -----------------------------------------------------------------------------------------------
-- The real runs (`run.sh`).

structure Ctx where
  root : System.FilePath
  app : String
  tests : String
  work : System.FilePath
  files : Array String

/-- Run the workload, capturing the report on stdout and the profile channel on stderr. Exit codes
are the caller's business here — a findings-carrying preview exits 1 by design. -/
private def profileRun (ctx : Ctx) : IO ProcResult :=
  runProc ctx.app
    (#["check", "--output-format", "concise", "--root", ctx.root.toString] ++ ctx.files)
    (cwd? := some ctx.root) (env := #[("LEAN_FMT_PROFILE_PHASES", some "1")])
    (timeoutMs := some 1800000)

/-- §0b renderer work is linear in document nodes. -/
private def testDocSteps (ctx : Ctx) : IO Unit := do
  let result ← expectExit 0 "doc-step-counts" ctx.tests #["doc-step-counts"] (cwd? := some ctx.root)
  ensure (gateDocStepsLinear result.stdout)
    s!"renderer work is no longer steps = nodes + marks, or the step report is incomplete:\n\
      {result.stdout}"

/-- §0c validation performs exactly two frontend renders. -/
private def testValidationCounts (ctx : Ctx) : IO Unit := do
  let fixture := ctx.root / "tests" / "performance" / "validator-gate" / "Accepted.lean"
  let setup ← expectExit 0 "lake setup-file" "lake" #["setup-file", fixture.toString]
    (cwd? := some ctx.root)
  let setupPath := ctx.work / "validator-setup.json"
  writeFile setupPath setup.stdout
  let result ← expectExit 0 "analyze-exact" ctx.app
    #["__analyze-exact", setupPath.toString, fixture.toString, fixture.toString, "4:80"]
    (cwd? := some ctx.root) (timeoutMs := some 600000)
  let json ← parseJson result.stdout "validator"
  ensureJsonAt json [.field "canonical", .field "validation"] (Lean.Json.mkObj [
    ("frontendRuns", Lean.toJson (2 : Nat)), ("renders", Lean.toJson (2 : Nat)),
    ("structuralComparisons", Lean.toJson (1 : Nat)), ("idempotencePasses", Lean.toJson (1 : Nat))])
    "validation work counts changed from frontend/renders/comparisons/idempotence = 2/2/1/1"
  ensureJsonAt json [.field "canonical", .field "metrics", .field "frontendRuns"]
    (Lean.toJson (2 : Nat)) "validation metrics"
  ensure ((jsonAt? json [.field "validationFailure"]).getD .null == .null)
    "validation failed the accepted fixture"

/-- §1 a warm run is fully cache-served, and §4 the served report is byte-identical to the one
that populated the cache. The prime run may be cold for any reason — a rebuilt binary, a fresh
checkout — and that is not what this section measures. -/
private def testWarmFullyServed (ctx : Ctx) : IO Unit := do
  let prime ← profileRun ctx
  let warm ← profileRun ctx
  ensureEq "the manifest's files are not the targets" (some ctx.files.size)
    ((counter "cache.targets" warm.stderr).map Int.toNat)
  ensure (gateFullyServed warm.stderr)
    s!"warm run not fully served: hits={counter "cache.index_hits" warm.stderr} \
      served={counter "cache.served" warm.stderr}"
  ensure (gateNoFrontendWork warm.stderr)
    s!"warm run did frontend work: {phaseCount "exact_child" warm.stderr} children, \
      {phaseCount "exact_setup" warm.stderr} setup resolutions; expected 0 and 0"
  ensure (gateReportsIdentical prime.stdout warm.stdout)
    "cold and warm reports differ; the cache is not serving what it stored"

/-- §1d/§1e bounded child lifetime and artifact acceleration. -/
private def testArtifactAcceleration (ctx : Ctx) : IO Unit := do
  let fixture := ctx.root / "tests" / "compiler" / "ArtifactLayout.lean"
  discard <| expectExit 0 "artifact build" "lake"
    #["build", "+ArtifactLayout:leanFmtArtifact"] (cwd? := some ctx.root)
    (env := #[("LEAN_NUM_THREADS", some "1")]) (timeoutMs := some 1800000)
  let artifact ← runProc ctx.app #["diff", "--no-cache", fixture.toString] (cwd? := some ctx.root)
    (env := #[("LEAN_FMT_PROFILE_PHASES", some "1"), ("LEAN_NUM_THREADS", some "1")])
    (timeoutMs := some 600000)
  let exact ← runProc ctx.app #["diff", "--no-cache", fixture.toString] (cwd? := some ctx.root)
    (env := #[("LEAN_FMT_PROFILE_PHASES", some "1"), ("LEAN_NUM_THREADS", some "1"),
      ("LEAN_FMT_DISABLE_ARTIFACT", some "1")]) (timeoutMs := some 600000)
  ensure (gateSerialChildren artifact.stderr 1 && gateSerialChildren exact.stderr 1)
    "child admission was absent or exceeded one active child"
  ensure (gateArtifactAvoidsExact artifact.stderr exact.stderr)
    "artifact/exact strategy counts no longer distinguish their frontend work"
  ensure (gateReportsIdentical artifact.stdout exact.stdout)
    "artifact-built and exact-source reports differ"

/-- §1f parallel child admission stays within --workers. A sleeping fake analyzer holds both
children alive long enough for the second admission to observe the first: concurrency is certain,
not timed. -/
private def testParallelAdmission (ctx : Ctx) : IO Unit := do
  let sleeper := ctx.work / "sleeping-analyzer.sh"
  writeFile sleeper "#!/usr/bin/env bash\nsleep 1\nexit 1\n"
  discard <| expectExit 0 "chmod" "chmod" #["+x", sleeper.toString]
  let result ← runProc ctx.app
    #["check", "--no-cache", "--workers", "2",
      (ctx.root / "tests" / "check" / "Clean.lean").toString,
      (ctx.root / "tests" / "check" / "Layout.lean").toString]
    (cwd? := some ctx.root)
    (env := #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"),
      ("LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE", some "1"),
      ("LEAN_FMT_TEST_ANALYZER", some sleeper.toString),
      ("LEAN_FMT_PROFILE_PHASES", some "1")]) (timeoutMs := some 600000)
  ensure (gateParallelChildren result.stderr 2 2) "parallel child admission breached the bound"

/-- §1g the worker count comes from the environment, not from a hard-coded one. A run with no
`--workers` takes `LEAN_NUM_THREADS`; `--workers` overrides it. Both arms are cache hits over one
clean file, so this measures the resolution and nothing else — the point is that the default is
*not* 1, which is what made every cold run on a mathlib project serial. -/
private def testWorkerResolution (ctx : Ctx) : IO Unit := do
  let profile (args : Array String) (threads : String) : IO String := do
    let result ← runProc ctx.app (#["check", "--no-cache"] ++ args ++
      #[(ctx.root / "tests" / "check" / "Clean.lean").toString]) (cwd? := some ctx.root)
      (env := #[("LEAN_FMT_PROFILE_PHASES", some "1"), ("LEAN_NUM_THREADS", some threads)])
      (timeoutMs := some 600000)
    return result.stderr
  ensure (gateWorkers (← profile #[] "6") 6) "an unasked run ignored LEAN_NUM_THREADS"
  ensure (gateWorkers (← profile #["--workers", "3"] "6") 3) "--workers did not override"

/-- §2 gate G3. The wall clock covers the formatter process and nothing else — one parent times
the child directly, because two interpreter timestamps around the run would put both startups in
the denominator. The bound scales with a `rules --json` startup control measured on this machine:
250 ms quiet, more when the machine is not. -/
private def testG3Remainder (ctx : Ctx) : IO Unit := do
  let started ← IO.monoMsNow
  let run ← profileRun ctx
  let wall := (← IO.monoMsNow) - started
  let controlStarted ← IO.monoMsNow
  discard <| expectExit 0 "rules control" ctx.app #["rules", "--json"] (cwd? := some ctx.root)
  let control := (← IO.monoMsNow) - controlStarted
  let bound := max 250 (control * 10)
  let percent := (accounted run.stderr) * 100 / (max wall 1)
  ensure (gateRemainderWithin run.stderr wall bound)
    s!"unaccounted remainder {wall - accounted run.stderr} ms of {wall} ms exceeds the {bound} ms \
      startup bound ({percent}% accounted): work is happening outside every top-level phase"

/-- §3 no top-level phase silently measures nothing. The fixture is large enough that the phase
*must* be non-zero if it is measuring at all: a 2 MB body with one finding at the very end costs
tens of milliseconds to index and single-digit microseconds to not-measure. -/
private def testPhaseMeasures (ctx : Ctx) : IO Unit := do
  let fixtureDir := ctx.root / "tests" / "reporting" / "performance-gate"
  IO.FS.createDirAll fixtureDir
  try
    -- A control byte (FMT001) inside a comment: it fires anywhere, needs no frontend, and leaves
    -- the file parseable. Placed at the end, so `positionsOf` must walk the whole source.
    let body := "
".intercalate (List.replicate (2000000 / 80) (String.ofList (List.replicate 79 'x')))
    writeFile (fixtureDir / "Late.lean")
      ("/-\nCopyright (c) 2026 Jacob Reinhold. All rights reserved.\n-/\n\nmodule\n\n/-\n"
        ++ body ++ "\x01" ++ "\n-/\n")
    let result ← runProc ctx.app
      #["check", "--output-format", "concise", "--root", ctx.root.toString,
        (fixtureDir / "Late.lean").toString]
      (cwd? := some ctx.root) (env := #[("LEAN_FMT_PROFILE_PHASES", some "1")])
      (timeoutMs := some 600000)
    if gatePhaseMeasures result.stderr "positions" then
      pure ()
    else if phaseCount "positions" result.stderr == 0 then
      throw <| IO.userError
        "phase.positions_ms was never emitted; the bracket is gone or the finding did not fire"
    else
      throw <| IO.userError
        "phase.positions_ms read 0 ms over 2 MB: the bracket is timing an already-evaluated value"
  finally
    removeDirAll? fixtureDir

end Performance

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  withTempDir fun work => do
    let manifest ← IO.FS.readFile (root / "tests" / "performance" / "lean-fmt-self.txt")
    let files := ((manifest.splitOn "\n").filter (· != "")).map
      fun relative => root.toString ++ "/" ++ relative
    let ctx : Performance.Ctx := {
      root
      app := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
      tests := (root / ".lake" / "build" / "bin" / "lean-fmt-tests").toString
      work
      files := files.toArray
    }
    runCases "performance" #[
      { name := "gates-discriminate", run := Performance.testGatesDiscriminate },
      { name := "doc-steps", run := Performance.testDocSteps ctx },
      { name := "validation-counts", run := Performance.testValidationCounts ctx },
      { name := "warm-fully-served", run := Performance.testWarmFullyServed ctx },
      { name := "artifact-acceleration", run := Performance.testArtifactAcceleration ctx },
      { name := "parallel-admission", run := Performance.testParallelAdmission ctx },
      { name := "worker-resolution", run := Performance.testWorkerResolution ctx },
      { name := "g3-remainder", run := Performance.testG3Remainder ctx },
      { name := "phase-measures", run := Performance.testPhaseMeasures ctx }
    ] args
