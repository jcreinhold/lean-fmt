module

public import Test

/-!
# The scale suite

Port of `tests/scale/run.sh`: complete selection over a small Lake project — every source kind
(workspace module, nested Lake configuration, standalone script) is discovered, checked, and
cached, and a single-source edit invalidates exactly that source's entry (`ruff-16b` RCI-IMPL).

Lane: parallel — the fixture project and its `.lean-fmt-cache` live under a temp dir.
-/

open LeanFmt.Test

namespace Scale

structure Ctx where
  root : System.FilePath
  application : String
  project : System.FilePath

private def checkJson (ctx : Ctx) (expected : UInt32) (label : String)
    (env : Array (String × Option String) := #[]) : IO Lean.Json := do
  let result ← expectExit expected label ctx.application
    #["check", "--root", ctx.project.toString, "--json"] (env := env)
  parseJson result.stdout label

private def pathsOf (report : Lean.Json) : List String :=
  (((jsonAt? report [.field "files"]).bind (·.getArr?.toOption)).getD #[]).toList.map
    fun file => (file.getObjValAs? String "path").toOption.getD ""

/-- The whole selection, clean. -/
private def testCold (ctx : Ctx) : IO String := do
  let report ← checkJson ctx 0 "cold"
  let paths := pathsOf report
  ensureEq "cold: selection"
    ["Demo.lean", "Nested/lakefile.lean", "lakefile.lean", "scripts/Standalone.lean"] paths
  for file in ((jsonAt? report [.field "files"]).bind (·.getArr?.toOption)).getD #[] do
    ensureJsonAt file [.field "status"] (Lean.toJson "clean") "cold"
  ensureJsonAt report [.field "infrastructureFailures"] (.arr #[]) "cold"
  return report.compress

/-- Every semantic result, including standalone and Lake configuration sources, is cacheable: an
all-hit run needs neither ordinary module evidence nor an exact frontend child. -/
private def testWarm (ctx : Ctx) (cold : String) : IO Unit := do
  let report ← checkJson ctx 0 "warm"
    (env := #[("LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE", some "1"),
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
  let report ← checkJson ctx 2 "stale"
    (env := #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"),
      ("LEAN_FMT_TEST_ANALYZER", some "/usr/bin/false")])
  writeFile demo original
  let paths := pathsOf report
  ensureEq "stale: files lost" 4 paths.length
  ensureEq "stale: not sorted" (paths.mergeSort (· < ·)) paths
  let allFiles := ((jsonAt? report [.field "files"]).bind (·.getArr?.toOption)).getD #[]
  let failedFiles := allFiles.toList.filter fun file =>
    (file.getObjValAs? String "status").toOption == some "infrastructure-failure"
  let failed := failedFiles.map fun file => (file.getObjValAs? String "path").toOption.getD ""
  ensureEq "stale: more than the edited source invalidated" ["Demo.lean"] failed

end Scale

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
    writeFile (project / "Nested" / "lakefile.lean") "import Lake\n\nopen Lake DSL\n\npackage \"nested\"\n"
    discard <| expectExit 0 "lake build Demo" "lake" #["-d", project.toString, "build", "Demo"]
      (cwd? := some root)
    let ctx : Scale.Ctx :=
      { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, project }
    -- The warm run compares against the cold report, so cold hands its bytes along.
    let cold ← Scale.testCold ctx
    let cases : Array Case := #[
      { name := "cold-selects-all", run := discard <| Scale.testCold ctx },
      { name := "warm-all-hit", run := Scale.testWarm ctx cold },
      { name := "single-source-invalidation", run := Scale.testSingleSourceInvalidation ctx }
    ]
    runCases "scale" cases args
