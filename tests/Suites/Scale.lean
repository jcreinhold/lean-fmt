module

public import Test

/-!
# The scale suite

Port of `tests/scale/run.sh`: complete selection over a small Lake project — every source kind
(workspace module, nested Lake configuration, standalone script) is discovered, checked, and
cached, and a single-source edit invalidates exactly that source's entry. It also pins that a
project's own Lake arguments reach the exact frontend, which needs a second fixture project because
the argument belongs in its lakefile.

Two later cases gate the frontend child itself, on fixture projects of their own: what its
transport leaves open (`descriptor-closure`) and how large a task pool it gets
(`child-pool-starvation`).

Lane: parallel — the fixture project and its `.lean-fmt-cache` live under a temp dir.
-/

open LeanFmt.Test

namespace Scale

structure Ctx where
  root : System.FilePath
  application : String
  project : System.FilePath
  work : System.FilePath

private def checkJson (ctx : Ctx) (expected : UInt32) (label : String)
    (env : Array (String × Option String) := #[]) : IO Lean.Json := do
  let result ←
    expectExit expected label ctx.application #["check", "--root", ctx.project.toString, "--json"]
        (env := env)
  parseJson result.stdout label

private def pathsOf (report : Lean.Json) : List String :=
  (((jsonAt? report [.field "files"]).bind (·.getArr?.toOption)).getD #[]).toList.map fun file =>
    (file.getObjValAs? String "path").toOption.getD ""

/-- The whole selection, clean. -/
private def testCold (ctx : Ctx) : IO String := do
  let report ← checkJson ctx 0 "cold"
  let paths := pathsOf report
  ensureEq "cold: selection"
      ["Demo.lean", "Nested/lakefile.lean", "lakefile.lean", "scripts/Standalone.lean"] paths
  for file in ((jsonAt? report [.field "files"]).bind (·.getArr?.toOption)).getD #[]do
    ensureJsonAt file [.field "status"] (Lean.toJson "clean") "cold"
  ensureJsonAt report [.field "infrastructureFailures"] (.arr #[]) "cold"
  return report.compress

/-- Every semantic result, including standalone and Lake configuration sources, is cacheable: an
all-hit run needs neither ordinary module evidence nor an exact frontend child. -/
private def testWarm (ctx : Ctx) (cold : String) : IO Unit := do
  let report ←
    checkJson ctx 0 "warm" (env :=
        #[("LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE", some "1"),
          ("LEAN_FMT_DISABLE_ARTIFACT", some "1"),
          ("LEAN_FMT_TEST_ANALYZER", some "/usr/bin/false")])
  ensureEq "an all-hit run disagreed with the cold run" cold report.compress

/-- Editing one source invalidates that source's entry and nothing else. The standalone script is
keyed by the conservative whole-workspace artifact digest — and no rebuild has happened here, so
its grammar is provably unchanged and it correctly still hits. -/
private def testSingleSourceInvalidation (ctx : Ctx) : IO Unit := do
  let demo := ctx.project / "Demo.lean"
  let original ← IO.FS.readFile demo
  IO.FS.withFile demo .append fun handle => handle.putStr "\n-- stale\n"
  let report ←
    checkJson ctx 2 "stale" (env :=
        #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"),
          ("LEAN_FMT_TEST_ANALYZER", some "/usr/bin/false")])
  writeFile demo original
  let paths := pathsOf report
  ensureEq "stale: files lost" 4 paths.length
  ensureEq "stale: not sorted" (paths.mergeSort (· < ·)) paths
  let allFiles := ((jsonAt? report [.field "files"]).bind (·.getArr?.toOption)).getD #[]
  let failedFiles :=
    allFiles.toList.filter fun file =>
      (file.getObjValAs? String "status").toOption == some "infrastructure-failure"
  let failed := failedFiles.map fun file => (file.getObjValAs? String "path").toOption.getD ""
  ensureEq "stale: more than the edited source invalidated" ["Demo.lean"] failed

/-- A `-D` option in `moreLeanArgs` reaches the exact frontend, because `lake build` passes it.

Lake spawns `lean <weakLeanArgs ++ leanArgs> … --setup setup.json`, and `--setup` carries only
`options` — so a project silencing a linter through `moreLeanArgs` silenced it for the build and not
for us, and lean-fmt reported a finding the build did not. `Project.setupJob` folds those arguments
onto the setup's options now.

Both directions, on one fixture: the same source and the same rule, with and without the argument. A
case asserting only the silenced half would pass on a formatter that never ran the linter at all. -/
private def testLeanArgsReachTheFrontend (ctx : Ctx) : IO Unit := do
  let project := ctx.work / "leanargs"
  IO.FS.createDirAll (project / "Demo")
  copyFile (ctx.root / "lean-toolchain") (project / "lean-toolchain")
  writeFile (project / "Demo" / "Unused.lean")
      "module\n\n/-- An unused binder, which `linter.unusedVariables` reports. -/\n\
     public def ignoresIt (n : Nat) : Nat := 0\n"
  let lakefile (extra : String) : String :=
    "import Lake\n\nopen Lake DSL\n\npackage \"leanargs-fixture\"\n\nlean_lib Demo where\n  \
     globs := #[.submodules `Demo]\n" ++
      extra
  -- `check` exits 1 when it has a finding and 0 when it has none, so the expected exit *is* the
  -- expected outcome; taking it as a parameter keeps that assertion in the case rather than
  -- letting a wrong exit pass silently into the count below.
  let findings (label : String) (expected : UInt32) : IO Nat := do
    discard <|
        expectExit 0 s!"lake build Demo ({label})" "lake" #["-d", project.toString, "build", "Demo"]
          (cwd? := some ctx.root)
    let result ←
      expectExit expected s!"check ({label})" ctx.application
          #["check", "--root", project.toString, "--preview", "--select", "FMT013", "--no-cache",
            "--json"]
    let report ← parseJson result.stdout s!"check ({label})"
    return (((jsonAt? report [.field "findings"]).bind (·.getNat?.toOption)).getD 0)
  writeFile (project / "lakefile.lean") (lakefile "")
  ensureEq "the fixture's own linter finding is missing; the case cannot discriminate" 1
      (← findings "no leanArgs" 1)
  writeFile (project / "lakefile.lean")
      (lakefile "  moreLeanArgs := #[\"-Dlinter.unusedVariables=false\"]\n")
  ensureEq "a -D option in moreLeanArgs did not reach the exact frontend" 0
      (← findings "with leanArgs" 0)

end Scale

/-- A batch leaves no per-target descriptors behind. The frontend transport used to hold two pipe
handles per child, and under `--workers N > 1` they survived each reap — ~2 descriptors per
target, which is what exhausted a 1400-target run near target 1300 (`EMFILE` on the next
target's setup file). The transport is per-target files now, deleted when the target's envelope
is decoded, so a 120-target run ends with the descriptor count it started with, give or take the
run's own bookkeeping. The counts are the run's own (`LEAN_FMT_TEST_FD_REPORT`); parsing the
schema another process printed would couple this gate to `lsof`. -/
private def testDescriptorClosure (ctx : Scale.Ctx) : IO Unit := do
  let project := ctx.work / "fdgate"
  IO.FS.createDirAll (project / "scripts")
  copyFile (ctx.root / "lean-toolchain") (project / "lean-toolchain")
  writeFile (project / "lakefile.lean")
      "import Lake\n\nopen Lake DSL\n\npackage \"fdgate-fixture\"\n"
  for i in [0:120]do
    writeFile (project / "scripts" / s!"F{i}.lean") s!"module\n\ndef  value{i} :Nat:={i}\n"
  let result ←
    expectExit 1 "descriptor closure" ctx.application
        #["format", "--check", "--root", project.toString, "--no-cache", "--workers", "4"] (env :=
        #[("LEAN_FMT_TEST_FD_REPORT", some "1")]) (timeoutMs := some 600000)
  let fdsOf (marker : String) : IO Nat := do
    let some line :=
      (result.stderr.splitOn "\n").find?
        (·.startsWith
          marker) | throw <| IO.userError s!"descriptor closure: no {marker} record\n{result.stderr}"
    let some count :=
      (line.drop
          marker.length).toNat? | throw <| IO.userError s!"descriptor closure: unparsable {marker} line: {line}"
    return count
  let started ← fdsOf "test.fds_open_start="
  let finished ← fdsOf "test.fds_open_end="
  ensure (finished ≤ started + 8)
      s!"descriptor closure: {started} descriptors open at start, {finished} at end"

/-- The frontend child gets a task pool of its own, not the caller's `LEAN_NUM_THREADS`.

The child elaborates under `Elab.async := true`, so its own elaboration sits on a pool thread and
every pooled task that waits for another one holds a second. A nest two deep — `TacticM.parFirst`
whose jobs each call `TacticM.parFirst` — needs four threads to make progress, and measured here it
deadlocks at one, two, and three. The caller's `LEAN_NUM_THREADS` is not that number: for this
product it names the worker count (`resolveWorkers`), and CI sets it to 1. Sizing the child's pool
from it cost a whole-project mathlib run 45 silent minutes on one file.

So the case runs under `LEAN_NUM_THREADS=1`, which is exactly the configuration that hung, and
gives the child a one-minute bound so a regression reports a named file instead of sitting for the
default ten. -/
private def testChildPoolStarvation (ctx : Scale.Ctx) : IO Unit := do
  let project := ctx.work / "pool"
  IO.FS.createDirAll (project / "Probe")
  copyFile (ctx.root / "lean-toolchain") (project / "lean-toolchain")
  writeFile (project / "lakefile.lean")
      "import Lake\n\nopen Lake DSL\n\npackage \"pool-fixture\"\n\nlean_lib Probe where\n  \
     globs := #[.submodules `Probe]\n"
  writeFile (project / "Probe" / "Nested.lean")
      (String.intercalate "\n"
        ["import Lean", "", "open Lean Elab Tactic", "",
          "/-- Two levels of pooled waiting: each outer job blocks on an inner `parFirst`. -/",
          "elab \"nested_par\" : tactic => do", "  let inner : TacticM Unit := do",
          "    let jobs : List (TacticM Unit) := [pure (), pure ()]",
          "    let _ ← TacticM.parFirst jobs", "  let jobs : List (TacticM Unit) := [inner, inner]",
          "  let _ ← TacticM.parFirst jobs", "", "example : True := by", "  nested_par",
          "  trivial", ""])
  discard <|
      expectExit 0 "lake build Probe" "lake" #["-d", project.toString, "build", "Probe"] (cwd? :=
        some ctx.root)
  let check (label : String) (expected : UInt32) (threads : Array (String × Option String))
    (bound : String) : IO Lean.Json := do
    let result ←
      expectExit expected label ctx.application
          #["check", "--root", project.toString, "--no-cache", "--select", "FMT011", "--workers",
            "1", "--json"]
          (env :=
          #[("LEAN_NUM_THREADS", some "1"), ("LEAN_FMT_CHILD_TIMEOUT_MS", some bound)] ++ threads)
          (timeoutMs := some 300000)
    parseJson result.stdout label
  let report ← check "child pool starvation" 0 #[] "60000"
  ensureEq "the fixture lost its source" ["Probe/Nested.lean", "lakefile.lean"]
      (Scale.pathsOf report)
  ensureJsonAt report [.field "infrastructureFailures"] (.arr #[]) "child pool starvation"
  -- Without the second arm the case cannot fail: a run that never spawned a child would pass it.
  -- Two threads is what this product shipped, and it is what the nest starves.
  let starved ←
    check "child pool starvation (two threads)" 2 #[("LEAN_FMT_CHILD_THREADS", some "2")] "20000"
  let starvedCount :=
    (((jsonAt? starved [.field "infrastructureFailures"]).bind (·.getArr?.toOption)).getD #[]).size
  ensure (starvedCount == 1)
      s!"two threads did not starve the nest, so this case gates nothing: {starved.compress}"

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  withTempDir fun work => do
      let project := work / "project"
      IO.FS.createDirAll (project / "Nested")
      IO.FS.createDirAll (project / "scripts")
      copyFile (root / "lean-toolchain") (project / "lean-toolchain")
      writeFile (project / "lakefile.lean")
          "import Lake\n\nopen Lake DSL\n\npackage \"scale-fixture\"\n\nlean_lib Demo where\n  \
       roots := #[`Demo]\n  globs := #[Glob.one `Demo]\n"
      writeFile (project / "Demo.lean") "module\n\ndef demo : Nat := 1\n"
      writeFile (project / "scripts" / "Standalone.lean") "module\n\n#check Nat\n"
      writeFile (project / "Nested" / "lakefile.lean")
          "import Lake\n\nopen Lake DSL\n\npackage \"nested\"\n"
      discard <|
          expectExit 0 "lake build Demo" "lake" #["-d", project.toString, "build", "Demo"] (cwd? :=
            some root)
      let ctx : Scale.Ctx :=
        { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, project
          work }
      -- The warm run compares against the cold report, so cold hands its bytes along.
      let cold ← Scale.testCold ctx
      let cases : Array Case :=
        #[{ name := "cold-selects-all", run := discard <| Scale.testCold ctx },
          { name := "warm-all-hit", run := Scale.testWarm ctx cold },
          { name := "single-source-invalidation", run := Scale.testSingleSourceInvalidation ctx },
          { name := "lean-args-reach-the-frontend", run := Scale.testLeanArgsReachTheFrontend ctx },
          { name := "descriptor-closure", run := testDescriptorClosure ctx },
          { name := "child-pool-starvation", run := testChildPoolStarvation ctx }]
      runCases "scale" cases args
