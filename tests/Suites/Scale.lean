module

public import Test

/-!
# The scale suite

Port of `tests/scale/run.sh`: complete selection over a small Lake project — every source kind
(workspace module, nested Lake configuration, standalone script) is discovered, checked, and
cached, and a single-source edit invalidates exactly that source's entry. It also pins that a
project's own Lake arguments reach the exact frontend, which needs a second fixture project because
the argument belongs in its lakefile.

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
     globs := #[.submodules `Demo]\n" ++ extra
  -- `check` exits 1 when it has a finding and 0 when it has none, so the expected exit *is* the
  -- expected outcome; taking it as a parameter keeps that assertion in the case rather than
  -- letting a wrong exit pass silently into the count below.
  let findings (label : String) (expected : UInt32) : IO Nat := do
    discard <| expectExit 0 s!"lake build Demo ({label})" "lake"
      #["-d", project.toString, "build", "Demo"] (cwd? := some ctx.root)
    let result ← expectExit expected s!"check ({label})" ctx.application
      #["check", "--root", project.toString, "--preview", "--select", "FMT013", "--no-cache",
        "--json"]
    let report ← parseJson result.stdout s!"check ({label})"
    return (((jsonAt? report [.field "findings"]).bind (·.getNat?.toOption)).getD 0)
  writeFile (project / "lakefile.lean") (lakefile "")
  ensureEq "the fixture's own linter finding is missing; the case cannot discriminate"
    1 (← findings "no leanArgs" 1)
  writeFile (project / "lakefile.lean")
    (lakefile "  moreLeanArgs := #[\"-Dlinter.unusedVariables=false\"]\n")
  ensureEq "a -D option in moreLeanArgs did not reach the exact frontend"
    0 (← findings "with leanArgs" 0)

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
      { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, project
        work }
    -- The warm run compares against the cold report, so cold hands its bytes along.
    let cold ← Scale.testCold ctx
    let cases : Array Case := #[
      { name := "cold-selects-all", run := discard <| Scale.testCold ctx },
      { name := "warm-all-hit", run := Scale.testWarm ctx cold },
      { name := "single-source-invalidation", run := Scale.testSingleSourceInvalidation ctx },
      { name := "lean-args-reach-the-frontend", run := Scale.testLeanArgsReachTheFrontend ctx }
    ]
    runCases "scale" cases args
