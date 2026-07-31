module

public import Test

/-!
# The downstream suite

Port of `tests/fixtures/downstream/run.sh`: downstream integration. Every other suite exercises the
formatter from inside its own workspace, where the plugin is reached as
`@/LeanFmtCompilerPlugin:shared` and the facet is declared in the lakefile that owns the modules.
A consuming project has neither; until this suite existed the downstream recipe was a string
printed by `compiler setup` and nothing ran it.

Lane: exclusive+slow — the fixture project builds this checkout as a dependency.
-/

open LeanFmt.Test

namespace Downstream

structure Ctx where
  root : System.FilePath
  project : System.FilePath

private def lake (ctx : Ctx) (args : Array String) (label : String) : IO ProcResult :=
  expectExit 0 label "lake" args (cwd? := some ctx.project) (timeoutMs := some 3600000)

private def lakeAny (ctx : Ctx) (args : Array String)
    (env : Array (String × Option String) := #[]) : IO ProcResult :=
  runProc "lake" args (cwd? := some ctx.project) (env := env) (timeoutMs := some 3600000)

/-- The package-level `plugins` entry reaches every module without naming a single `lean_lib`. -/
private def testPluginBuild (ctx : Ctx) : IO Unit := do
  let lakefile ← IO.FS.readFile (ctx.project / "lakefile.lean")
  ensure (lakefile.contains "plugins := #[`@«lean-fmt»/LeanFmtCompilerPlugin:shared]")
    "fixture no longer sets the package-level cross-package plugin"
  discard <| lake ctx #["build"] "downstream project failed to build with the plugin active"

/-- A module facet declared in the dependency's lakefile registers in the consumer's workspace:
Lake merges each dependency's facet declarations into one workspace-global map. -/
private def testFacetResolution (ctx : Ctx) : IO Unit := do
  let sidecar := ctx.project / ".lake" / "build" / "lean-fmt-artifacts" / "Consumer" / "Basic.json"
  removeFile? sidecar
  discard <| lake ctx #["build", "+Consumer.Basic:leanFmtArtifact"]
    "the leanFmtArtifact facet did not resolve in the consuming workspace"
  ensure (← sidecar.pathExists) "facet produced no sidecar for a downstream module"
  ensure ((← sidecar.metadata).byteSize > 0) "the sidecar is empty"

/-- The executable resolves across packages: a consumer needs `require` and nothing else. -/
private def testCrossPackageExe (ctx : Ctx) : IO Unit := do
  let result ← lakeAny ctx #["exe", "lean-fmt", "check", "--root", "."]
  ensureEq "cross-package check did not return 1 (the fixture has findings)" 1 result.exitCode
  ensure (result.stderr.contains "mode=check" || result.stdout.contains "mode=check")
    s!"cross-package check produced no report: {result.stdout}{result.stderr}"

/-- The plugin is an optimization, never an authority: a syntax-tier rule returns the same
finding whether the fact came from the embedded artifact or the fallback frontend. -/
private def testArtifactAuthority (ctx : Ctx) : IO Unit := do
  let served ← lakeAny ctx
    #["exe", "lean-fmt", "check", "--root", ".", "--preview", "--select", "FMT010",
      "Consumer/Syntax.lean"]
  let fallback ← lakeAny ctx
    #["exe", "lean-fmt", "check", "--root", ".", "--preview", "--select", "FMT010",
      "Consumer/Syntax.lean"] (env := #[("LEAN_FMT_DISABLE_ARTIFACT", some "1")])
  let firstLine (result : ProcResult) : String :=
    (((result.stdout ++ result.stderr).splitOn "\n").filter (· != "")).head?.getD ""
  ensureEq "artifact and frontend disagree downstream" (firstLine fallback) (firstLine served)
  ensure (firstLine served |>.contains "FMT010")
    s!"syntax-tier rule did not fire downstream: {firstLine served}"

/-- `lake lint` drives the formatter through Lake's own lint-driver protocol, which is what
`leanprover/lean-action` probes with `check-lint` before running it in CI. -/
private def testLintDriver (ctx : Ctx) : IO Unit := do
  let lakefile ← IO.FS.readFile (ctx.project / "lakefile.lean")
  ensure (lakefile.contains "lintDriver := \"«lean-fmt»/«lean-fmt»\"")
    "fixture no longer configures the lint driver"
  discard <| lake ctx #["check-lint"] "lake check-lint does not see a configured driver"
  let lint ← lakeAny ctx #["lint"]
  ensureEq "lake lint did not exit 1 (the fixture has a finding)" 1 lint.exitCode
  ensure ((lint.stdout ++ lint.stderr).contains "FMT003 duplicate import")
    "lake lint did not carry the driver output through"

/-- Regression: a silent message is a carrier, not a diagnostic. The plugin writes the artifact
into the persistent lint log, so before `Analysis.messageStrings` filtered `isSilent`, a broken
file printed the whole serialized projection as its diagnostic. -/
private def testSilentMessage (ctx : Ctx) : IO Unit := do
  let broken ← lakeAny ctx #["exe", "lean-fmt", "check", "--root", ".", "Standalone/Broken.lean"]
  let output := broken.stdout ++ broken.stderr
  ensure (!(output.contains "lean-fmt.module-artifact"))
    "the module artifact leaked into a broken-source diagnostic"
  ensure (output.contains "Unknown identifier")
    s!"the real error stopped being reported: {output}"

/-- The interface closure mode, end to end where it must work to matter: a consuming project
that builds the `leanFmtArtifact` facet.

A proof-only edit to a hub module moves its build artifacts but not its interface. Under the
default `artifacts` mode the cone pays: `Dup`'s closure folds `Basic`'s olean hash, so `Dup`
misses. Under `closure = "interface"` the cone survives: `Basic`'s interface hash excludes the
proof term, so `Dup` serves. The assertion is the A/B difference — exactly one more entry served
— with each probe byte-compared against `--no-cache`, so a stale serve reads as a stale hit, not
as a pass. The fixture's other targets (the root module, the syntax module, the deliberately
broken standalone, the lakefile) behave identically in both modes, so they cancel out of the
difference. -/
private def testInterfaceClosureMode (ctx : Ctx) : IO Unit := do
  let basic := ctx.project / "Consumer" / "Basic.lean"
  let pristine ← IO.FS.readFile basic
  let config := ctx.project / "lean-fmt.toml"
  -- The lib's glob is `Glob.submodules `Consumer`, so the root `Consumer` module is not one of
  -- its modules: no facet to fetch there, and as a non-module target it misses on any rebuild in
  -- both modes — it cancels out of the difference.
  let facets := #["+Consumer.Basic:leanFmtArtifact",
    "+Consumer.Dup:leanFmtArtifact", "+Consumer.Syntax:leanFmtArtifact"]
  let build (label : String) : IO Unit := do
    discard <| lake ctx #["build"] label
    -- The sidecar is fetched on demand and must not lag the `.olean`: the cache refuses one
    -- that does and falls back to the artifact hash, which would silently un-measure this case.
    discard <| lake ctx (#["build"] ++ facets) s!"{label} (facets)"
  let check (label : String) (args : Array String := #[]) : IO ProcResult := do
    let result ← lakeAny ctx (#["exe", "lean-fmt", "check", "--root", "."] ++ args)
      (env := #[("LEAN_FMT_PROFILE_PHASES", some "1")])
    ensure (result.exitCode ≤ 1) s!"{label}: check did not run: {result.stderr}"
    return result
  -- The stale-hit oracle, same as the cache suite's `probe`: a cached run must say exactly what
  -- an uncached run says against the same build state.
  let probe (label : String) : IO Nat := do
    let cached ← check label #["--json"]
    let uncached ← lakeAny ctx #["exe", "lean-fmt", "check", "--root", ".", "--json", "--no-cache"]
    ensure (cached.exitCode == uncached.exitCode)
      s!"{label}: cached exit {cached.exitCode}, --no-cache exit {uncached.exitCode}"
    ensure (cached.stdout == uncached.stdout)
      s!"{label}: STALE HIT -- cached report differs from --no-cache"
    statFrom cached.stderr "served"
  try
    writeFile basic (pristine ++ "\npublic theorem t : 1 + 1 = 2 := rfl\n")
    build "interface-mode baseline"
    discard <| check "artifacts warm"
    writeFile basic (pristine ++ "\npublic theorem t : 1 + 1 = 2 := by decide\n")
    build "proof-only edit"
    let artifactsServed ← probe "artifacts probe"
    -- The cold run in the new mode misses everywhere (the digest prefixes differ — a mode toggle
    -- cannot alias an entry) and writes interface-mode entries.
    writeFile config "[cache]\nclosure = \"interface\"\n"
    discard <| check "interface cold"
    writeFile basic (pristine ++ "\npublic theorem t : 1 + 1 = 2 := rfl\n")
    build "proof-only edit, interface mode"
    let interfaceServed ← probe "interface probe"
    ensureEq "interface mode saved exactly the cone (Dup)" (artifactsServed + 1) interfaceServed
  finally
    writeFile basic pristine
    removeFile? config
    try discard <| lake ctx #["build"] "post-case restore" catch _ => pure ()

end Downstream

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let project := root / "tests" / "fixtures" / "downstream" / "project"
  -- The fixture tracks no toolchain of its own: a stale pin would test the wrong compiler.
  copyFile (root / "lean-toolchain") (project / "lean-toolchain")
  let ctx : Downstream.Ctx := { root, project }
  runCases "downstream" #[
    { name := "plugin-build", run := Downstream.testPluginBuild ctx },
    { name := "facet-resolution", run := Downstream.testFacetResolution ctx },
    { name := "cross-package-exe", run := Downstream.testCrossPackageExe ctx },
    { name := "artifact-authority", run := Downstream.testArtifactAuthority ctx },
    { name := "lint-driver", run := Downstream.testLintDriver ctx },
    { name := "silent-message", run := Downstream.testSilentMessage ctx },
    { name := "interface-closure-mode", run := Downstream.testInterfaceClosureMode ctx }
  ] args
