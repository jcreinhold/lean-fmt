module

public import Test

import all Test.Unit.Tools

import Lake

/-!
# The compiler facet suite

Port of `tests/fixtures/compiler/run.sh`. The `leanFmtArtifact` facet's contract, end to end against the
main workspace: the declared JSON artifact is verified against the module-owned payload in the
exact `.olean`; a syntax-tier selection answered from the artifact matches the frontend's answer
without spawning one, and a semantic selection declines it rather than reporting a false clean;
corruption is a counted exact fallback; a rule's prose edit invalidates nothing while a
plugin-binary edit invalidates through Lake's plugin dependency; and a failed elaboration publishes
nothing.

The four `lean-fmt-tests` subcommands this suite used to spawn (`verify-plugin-artifact`,
`verify-facet-artifact`, `verify-official-facet`, `print-lake-hash`) are called in-process here —
their implementations stay in `Test.Unit.Tools` until the artifact suite's port moves them and
`checkProjection` to a shared facet module, at which point the legacy dispatch branches die.

Lane: exclusive. The suite builds main-workspace targets, edits `LeanFmt/` sources in place, and
corrupts and rebuilds `.lake` outputs — nothing else may run against this workspace meanwhile.
-/

open LeanFmt LeanFmt.Internal
open LeanFmt.Test

namespace CompilerSuite

/-- Everything a case needs, resolved once in the preamble. The three source backups ride in
memory: the suite edits them and cleanup must restore exact bytes, not a copy of a copy. -/
structure Ctx where
  root : System.FilePath
  application : String
  sourceFile : System.FilePath
  pluginSource : System.FilePath
  rulesSource : System.FilePath
  olean : System.FilePath
  trace : System.FilePath
  artifact : System.FilePath
  sourceBackup : String
  pluginBackup : String
  rulesBackup : String
  /-- The fixture after the preamble's trailing-whitespace edit: the state most restores target. -/
  fixtureBackup : String

private def lakeEnv : Array (String × Option String) :=
  #[("LEAN_NUM_THREADS", some "1")]

private def lakeBuild (ctx : Ctx) (args : Array String) (label : String)
    (env : Array (String × Option String) := #[]) : IO Unit := do
  discard <|
      expectExit 0 label "lake" (#["build"] ++ args) (cwd? := some ctx.root) (env := lakeEnv ++ env)

private def lakeFacetBuild (ctx : Ctx) (label : String := "facet build")
    (env : Array (String × Option String) := #[]) : IO Unit :=
  lakeBuild ctx #["+LocalSyntax:leanFmtArtifact"] label env

private def lakeFacetBuildMayFail (ctx : Ctx) : IO UInt32 := do
  let result ←
    runProc "lake" #["build", "+Broken:leanFmtArtifact"] (cwd? := some ctx.root) (env := lakeEnv)
  return result.exitCode

/-- The `depHash` one Lake trace records, as raw JSON — compared across edits, never interpreted. -/
private def traceHash (ctx : Ctx) : IO Lean.Json := do
  let parsed ← parseJson (← IO.FS.readFile ctx.trace) "LocalSyntax.trace"
  let some hash :=
    jsonAt? parsed [.field "depHash"] | throw <| IO.userError "LocalSyntax.trace carries no depHash"
  return hash

private def removeFacetOutputs (ctx : Ctx) : IO Unit := do
  removeFile? ctx.olean
  removeFile? ctx.trace
  removeFile? (ctx.root / ".lake" / "build" / "lib" / "lean" / "Broken.olean")
  removeFile? ctx.artifact
  removeFile? (ctx.artifact.toString ++ ".trace")
  removeFile? (ctx.artifact.toString ++ ".hash")

/-- Lake's content hash of one file, so the facet's identity is pinned without re-deriving the
hash algorithm. -/
private def lakeHash (path : System.FilePath) : IO Lake.Hash :=
  Lake.computeFileHash path.toString (text := true)

/-- The old script's `verify_artifacts`: the facet's JSON against the module-owned payload in the
exact `.olean`, plus the projection walk both perform. -/
private unsafe def verifyArtifacts (ctx : Ctx) : IO Unit := do
  let expectedHash ← lakeHash ctx.artifact
  Unit.Tools.verifyPluginArtifact `LocalSyntax ctx.sourceFile
      [ctx.root / ".lake" / "build" / "lib" / "lean"]
  Unit.Tools.verifyFacetArtifact ctx.artifact ctx.sourceFile expectedHash

/-- Assert that an action fails — a corrupt artifact must be *rejected*, and a swallowed exception
would read as acceptance. -/
private def ensureFails (label : String) (action : IO Unit) : IO Unit := do
  let failed ←
    try
      action
      pure false
    catch _ =>
      pure true
  ensure failed label

private def profileStat (stderr needle : String) (label : String) : IO Unit := do
  ensure ((stderr.splitOn "\n").contains needle) s!"{label}: profile lost {needle}\n{stderr}"

private unsafe def testFacetBuildAndVerify (ctx : Ctx) : IO Unit := do
  removeFacetOutputs ctx
  discard <|
      expectExit 0 "cold facet build" "lake" #["-R", "build", "+LocalSyntax:leanFmtArtifact"]
        (cwd? := some ctx.root) (env := lakeEnv)
  verifyArtifacts ctx
  Unit.Tools.verifyOfficialFacet "." ctx.sourceFile

/-- A syntax-tier selection served from the artifact answers exactly what the frontend answers.
The artifact carries the projection the rules read, so the two must agree finding for finding, and
the artifact arm must reach that answer without spawning a child.

There used to be a second case here comparing the two *rendering* routes, because the artifact also
fed a canonical renderer. That renderer is gone — it rendered every command under one post-import
environment rather than the live per-command one, which made it both slower and wrong — so
rendering has one route and there is nothing left to compare. -/
private unsafe def testArtifactSyntaxRules (ctx : Ctx) : IO Unit := do
  lakeBuild ctx #["+ArtifactLayout:leanFmtArtifact", "lean-fmt"] "artifact-layout build"
  let profiled := lakeEnv ++ #[("LEAN_FMT_PROFILE_PHASES", some "1")]
  let select :=
    #["check", "--no-cache", "--select", "FMT011", "tests/fixtures/compiler/ArtifactLayout.lean"]
  let artifactRun ← runProc ctx.application select (cwd? := some ctx.root) (env := profiled)
  let exactRun ←
    runProc ctx.application select (cwd? := some ctx.root) (env :=
        profiled ++ #[("LEAN_FMT_DISABLE_ARTIFACT", some "1")])
  ensureEq "artifact and exact syntax-rule exit codes differ" exactRun.exitCode artifactRun.exitCode
  ensureEq "artifact and exact syntax-rule reports differ" exactRun.stdout artifactRun.stdout
  profileStat artifactRun.stderr "cache.official_artifact_hit=1" "artifact selection"
  ensure (!(artifactRun.stderr.splitOn "\n").any (·.startsWith "phase.exact_child_ms="))
      s!"the artifact selection spawned a frontend child\n{artifactRun.stderr}"
  ensure ((exactRun.stderr.splitOn "\n").any (·.startsWith "phase.exact_child_ms="))
      s!"the forced-exact selection had no frontend work to avoid\n{exactRun.stderr}"

/-- A semantic selection must not be answered from a build artifact. The plugin records syntax and
never the compiler's diagnostics, so the projection reaches `.syntax` facts, and `runRules` drops
every semantic rule when the facts are `.syntax` — silently, with nothing downstream able to notice.
Unchecked, this reported **clean**: measured, `check --preview --select FMT012` on a module with a
current facet found nothing while the same selection under `LEAN_FMT_DISABLE_ARTIFACT=1` found the
deprecation. The projection now answers the same demand predicate a cache hit does, so a `.syntax`
artifact misses a `.semantic` selection and the frontend runs.

The probe declarations are appended and removed here rather than committed to the fixture: every
other case reads `ArtifactLayout` for its layout, and a deprecation warning is not layout. -/
private unsafe def testArtifactTierMiss (ctx : Ctx) : IO Unit := do
  let fixture := ctx.root / "tests" / "fixtures" / "compiler" / "ArtifactLayout.lean"
  let backup ← IO.FS.readFile fixture
  let select :=
    #["check", "--no-cache", "--preview", "--select", "FMT012",
      "tests/fixtures/compiler/ArtifactLayout.lean"]
  let profiled := lakeEnv ++ #[("LEAN_FMT_PROFILE_PHASES", some "1")]
  try
    writeFile fixture
        (backup ++
          "\npublic def tierProbeNew : Nat := 1\n\
      @[deprecated tierProbeNew (since := \"2024-01-01\")]\npublic def tierProbeOld : Nat := 0\n\
      public def tierProbeUse : Nat := tierProbeOld\n")
    lakeBuild ctx #["+ArtifactLayout:leanFmtArtifact"] "tier-probe facet build"
    let served ← runProc ctx.application select (cwd? := some ctx.root) (env := profiled)
    let forced ←
      runProc ctx.application select (cwd? := some ctx.root) (env :=
          profiled ++ #[("LEAN_FMT_DISABLE_ARTIFACT", some "1")])
    ensureEq "the semantic selection reported nothing with the artifact present" 1 forced.exitCode
    ensureEq "an artifact-served semantic selection disagreed with the frontend" forced.stdout
        served.stdout
    -- The artifact was found and then declined: a run that never looked would also agree here.
    profileStat served.stderr "cache.official_artifact_hit=1" "tier miss"
    profileStat served.stderr "cache.artifact_tier_miss=1" "tier miss"
    ensure ((served.stderr.splitOn "\n").any (·.startsWith "phase.exact_child_ms="))
        s!"the declined artifact did not fall through to the frontend\n{served.stderr}"
  finally
    writeFile fixture backup
    lakeBuild ctx #["+ArtifactLayout:leanFmtArtifact"] "tier-probe facet restore"

/-- Corruption is a counted exact fallback, not a rebuild, partial result, or hard failure. -/
private unsafe def testCorruptArtifactFallback (ctx : Ctx) : IO Unit := do
  let layoutArtifact := ctx.root / ".lake" / "build" / "lean-fmt-artifacts" / "ArtifactLayout.json"
  let backup ← IO.FS.readFile layoutArtifact
  writeFile layoutArtifact "{\"partial\":"
  let profiled := lakeEnv ++ #[("LEAN_FMT_PROFILE_PHASES", some "1")]
  let fallback ←
    runProc ctx.application
        #["check", "--no-cache", "--select", "FMT011",
          "tests/fixtures/compiler/ArtifactLayout.lean"]
        (cwd? := some ctx.root) (env := profiled)
  writeFile layoutArtifact backup
  ensure (fallback.exitCode == 0 || fallback.exitCode == 1)
      s!"corrupt syntax artifact did not fall through to a successful exact check\n{fallback.stderr}"
  profileStat fallback.stderr "cache.official_artifact_miss=1" "corrupt fallback"
  ensure ((fallback.stderr.splitOn "\n").any (·.startsWith "phase.exact_child_ms="))
      s!"corrupt artifact did not fall through to the frontend\n{fallback.stderr}"

/-- A module whose facet was never built must miss alone, not zero the batch. Before the
sidecar-existence pre-filter in `officialArtifacts`, one never-built module in a mixed selection
failed the whole no-build traversal: `ArtifactLayout` + `Main` measured `official_artifact_miss=2`
and both files paid exact children — the artifact acceleration silently disabled in exactly the
mixed project it was built for. -/
private unsafe def testMixedSelection (ctx : Ctx) : IO Unit := do
  let main := ctx.root / ".lake" / "build" / "lean-fmt-artifacts" / "Main.json"
  removeFile? main
  removeFile? (main.toString ++ ".hash")
  removeFile? (main.toString ++ ".trace")
  let profiled := lakeEnv ++ #[("LEAN_FMT_PROFILE_PHASES", some "1")]
  let mixed ←
    runProc ctx.application
        #["check", "--no-cache", "--select", "FMT011",
          "tests/fixtures/compiler/ArtifactLayout.lean", "Main.lean"]
        (cwd? := some ctx.root) (env := profiled)
  ensure (mixed.exitCode == 0 || mixed.exitCode == 1)
      s!"mixed artifact/exact selection failed (status {mixed.exitCode})\n{mixed.stderr}"
  for needle in ["cache.official_artifact_hit=1", "cache.official_artifact_miss=1"]do
    profileStat mixed.stderr needle "mixed selection"

/-- `lake -q query <target> --text`, trimmed. -/
private def lakeQuery (ctx : Ctx) (target : String) : IO String := do
  let result ←
    expectExit 0 s!"lake query {target}" "lake" #["-q", "query", target, "--text"] (cwd? :=
        some ctx.root)
  return result.stdout.trimAscii.toString

/-- The extractor must use the exact `.olean` returned by the facet even when ambient `LEAN_PATH`
contains a different module with the same name first. -/
private unsafe def testExtractorExactOlean (ctx : Ctx) : IO Unit := do
  let plugin ← lakeQuery ctx "LeanFmtCompilerPlugin:shared"
  let extractor ← lakeQuery ctx "artifactExtractor"
  let leanBinResult ←
    expectExit 0 "lake env which lean" "lake" #["env", "which", "lean"] (cwd? := some ctx.root)
  let leanBin := leanBinResult.stdout.trimAscii.toString
  let repoLib := (ctx.root / ".lake" / "build" / "lib" / "lean").toString
  withScratchDir "compiler-shadow" fun shadow => do
      writeFile (shadow / "LocalSyntax.lean") "module\n\ndef shadow : Nat := 1\n"
      discard <|
          expectExit 0 "shadow compile" leanBin
            #[s!"--plugin={plugin}", "-o", "LocalSyntax.olean", "LocalSyntax.lean"] (cwd? :=
            some shadow) (env := #[("LEAN_PATH", some repoLib)])
      let exactJson := shadow / "exact.json"
      discard <|
          expectExit 0 "extractor" extractor
            #["LocalSyntax", ctx.olean.toString, exactJson.toString] (env :=
            #[("LEAN_PATH", some s!"{shadow}:{repoLib}")])
      Unit.Tools.verifyFacetArtifact exactJson ctx.sourceFile (← lakeHash exactJson)

/-- An up-to-date facet must continue to expose the payload embedded in the exact `.olean`. -/
private unsafe def testUpToDateFacet (ctx : Ctx) : IO Unit := do
  lakeFacetBuild ctx
  verifyArtifacts ctx

/-- The matched pair from the old script: editing one rule's message text must change *nothing*
here, because a rule's prose has no business in an `.olean` — before the boundary moved, this edit
invalidated every integrated module's Lake trace. The captured trace
feeds the plugin control below, and neither probe means anything alone: a harness that rebuilt no
module at all would pass the first, and the second proves the harness still notices real changes.
Returns the pre-edit trace for the control. -/
private unsafe def testRuleEditNoInvalidation (ctx : Ctx) : IO Lean.Json := do
  discard <|
      expectExit 0 "facet rebuild" "lake" #["-R", "build", "+LocalSyntax:leanFmtArtifact"] (cwd? :=
        some ctx.root) (env := lakeEnv)
  let enabledTrace ← traceHash ctx
  let enabledOlean ← sha256 ctx.olean
  let rules ← IO.FS.readFile ctx.rulesSource
  ensure ((rules.splitOn "message := \"redundant nested parentheses\"").length == 2)
      "rule invalidation probe could not find its unique source marker"
  writeFile ctx.rulesSource
      (rules.replace "message := \"redundant nested parentheses\""
        "message := \"probe: redundant nested parentheses\"")
  lakeFacetBuild ctx
  let rulesTrace ← traceHash ctx
  ensure (enabledTrace == rulesTrace)
      s!"editing a rule invalidated the owning Lake module trace:\n  before: {enabledTrace.compress}\n  after:  {rulesTrace.compress}"
  ensureEq "editing a rule changed the compiled bytes of an unrelated module" enabledOlean
      (← sha256 ctx.olean)
  verifyArtifacts ctx
  writeFile ctx.rulesSource ctx.rulesBackup
  lakeFacetBuild ctx
  return enabledTrace

/-- The control: a real plugin binary change must invalidate the module job through Lake's plugin
dependency, rather than through a formatter-maintained identity field. -/
private unsafe def testPluginEditInvalidation (ctx : Ctx) (enabledTrace : Lean.Json) : IO Unit := do
  let plugin ← IO.FS.readFile ctx.pluginSource
  ensure ((plugin.splitOn "private def produceCommandRecord").length == 2)
      "plugin invalidation probe could not find its unique source marker"
  writeFile ctx.pluginSource
      (plugin.replace "private def produceCommandRecord"
        "private def invalidationProbe : String := \"probe\"\n\nprivate def produceCommandRecord")
  lakeFacetBuild ctx
  ensure (enabledTrace != (← traceHash ctx))
      "plugin change did not invalidate the owning Lake module trace"
  verifyArtifacts ctx
  writeFile ctx.pluginSource ctx.pluginBackup
  lakeFacetBuild ctx

/-- Source changes cannot survive the module boundary as apparent hits. -/
private unsafe def testSourceEditInvalidation (ctx : Ctx) : IO Unit := do
  writeFile ctx.sourceFile ((← IO.FS.readFile ctx.sourceFile) ++ "\n-- source-invalidation-probe\n")
  lakeFacetBuild ctx
  verifyArtifacts ctx
  writeFile ctx.sourceFile ctx.fixtureBackup
  lakeFacetBuild ctx

/-- A corrupt declared facet output is an ordinary consumer miss. Removing its output and trace
lets Lake reproduce it from the exact module-owned payload. -/
private unsafe def testCorruptFacetArtifact (ctx : Ctx) : IO Unit := do
  let trustedHash ← lakeHash ctx.artifact
  removeFile? ctx.artifact
  writeFile ctx.artifact "{\"partial\":"
  ensureFails "corrupt facet artifact was accepted" do
      Unit.Tools.verifyFacetArtifact ctx.artifact ctx.sourceFile trustedHash
  -- The production consumer runs the registered job in no-build mode rather than trusting presence
  -- or launching an extractor. Corruption is a miss until the explicit facet prerequisite is rebuilt.
  ensureFails "corrupt official facet was consumed without an explicit rebuild" do
      Unit.Tools.verifyOfficialFacet "." ctx.sourceFile
  removeFile? ctx.artifact
  removeFile? (ctx.artifact.toString ++ ".trace")
  removeFile? (ctx.artifact.toString ++ ".hash")
  lakeFacetBuild ctx
  Unit.Tools.verifyOfficialFacet "." ctx.sourceFile
  verifyArtifacts ctx

/-- A corrupt `.olean` cannot publish a payload either. -/
private unsafe def testCorruptOlean (ctx : Ctx) : IO Unit := do
  removeFile? ctx.olean
  writeFile ctx.olean "corrupt"
  ensureFails "corrupt module artifact was accepted" do
      Unit.Tools.verifyPluginArtifact `LocalSyntax ctx.sourceFile
          [ctx.root / ".lake" / "build" / "lib" / "lean"]
  removeFile? ctx.olean
  removeFile? ctx.trace
  lakeFacetBuild ctx
  verifyArtifacts ctx

/-- The facet is genuinely cacheable: with an isolated writable Lake cache, deleting only the
local output restores the declared JSON artifact without rerunning the extractor. -/
private unsafe def testLakeCacheRestore (ctx : Ctx) : IO Unit := do
  let cacheEnv := #[("LAKE_ARTIFACT_CACHE", some "true")]
  removeFile? ctx.artifact
  removeFile? (ctx.artifact.toString ++ ".trace")
  removeFile? (ctx.artifact.toString ++ ".hash")
  withScratchDir "compiler-lake-cache" fun cacheDir => do
      let env := cacheEnv ++ #[("LAKE_CACHE_DIR", some cacheDir.toString)]
      lakeFacetBuild ctx "cached facet build" env
      removeFile? ctx.artifact
      removeFile? (ctx.artifact.toString ++ ".hash")
      let restored ←
        expectExit 0 "cache-restored facet build" "lake"
            #["-v", "build", "+LocalSyntax:leanFmtArtifact"] (cwd? := some ctx.root) (env :=
            lakeEnv ++ env)
      let log := restored.stdout ++ restored.stderr
      let lines := log.splitOn "\n"
      let about (needle : String) (line : String) :=
        line.contains needle && line.contains "LocalSyntax:leanFmtArtifact"
      ensureContains log "found artifact in cache:" "lake cache restore"
      ensureContains log "restored artifact from cache to:" "lake cache restore"
      ensure (lines.any (about "Replayed")) s!"Lake did not replay the facet from cache:\n{log}"
      ensure (!(lines.any (about "Built")))
          s!"Lake rebuilt the facet instead of restoring it from cache:\n{log}"
  verifyArtifacts ctx

/-- Failed elaboration cannot create an `.olean`, so it cannot publish a formatter payload. -/
private unsafe def testBrokenModuleNoPublish (ctx : Ctx) : IO Unit := do
  let brokenOlean := ctx.root / ".lake" / "build" / "lib" / "lean" / "Broken.olean"
  let brokenArtifact := ctx.root / ".lake" / "build" / "lean-fmt-artifacts" / "Broken.json"
  removeFile? brokenOlean
  removeFile? (ctx.root / ".lake" / "build" / "lib" / "lean" / "Broken.trace")
  ensure ((← lakeFacetBuildMayFail ctx) != 0)
      "broken module unexpectedly published a lean-fmt module artifact"
  ensure (!(← brokenOlean.pathExists)) "failed compiler published a lean-fmt module artifact"
  ensure (!(← brokenArtifact.pathExists)) "failed compiler published a lean-fmt facet artifact"

/-- The cases, minus the rule/plugin pair whose trace must be threaded between them — that pair is
`runAll` below so the second case sees the first's captured trace. -/
private unsafe def earlyCases (ctx : Ctx) : Array Case :=
  #[{ name := "facet-build-and-verify", run := testFacetBuildAndVerify ctx },
    { name := "artifact-syntax-rules", run := testArtifactSyntaxRules ctx },
    { name := "artifact-tier-miss", run := testArtifactTierMiss ctx },
    { name := "corrupt-artifact-fallback", run := testCorruptArtifactFallback ctx },
    { name := "mixed-selection", run := testMixedSelection ctx },
    { name := "extractor-exact-olean", run := testExtractorExactOlean ctx },
    { name := "up-to-date-facet", run := testUpToDateFacet ctx }]

private unsafe def lateCases (ctx : Ctx) : Array Case :=
  #[{ name := "source-edit-invalidation", run := testSourceEditInvalidation ctx },
    { name := "corrupt-facet-artifact", run := testCorruptFacetArtifact ctx },
    { name := "corrupt-olean", run := testCorruptOlean ctx },
    { name := "lake-cache-restore", run := testLakeCacheRestore ctx },
    { name := "broken-module-no-publish", run := testBrokenModuleNoPublish ctx }]

/-- All eleven cases in old-script order. The rule/plugin matched pair is one case: the trace the
rule probe captures feeds the plugin control directly, and neither probe means anything alone. -/
private unsafe def cases (ctx : Ctx) : Array Case :=
  Id.run do
    let mut all := earlyCases ctx
    all :=
      all.push
        { name := "rule-edit-boundary",
          run := do
            let enabledTrace ← testRuleEditNoInvalidation ctx
            testPluginEditInvalidation ctx enabledTrace }
    return all ++ lateCases ctx

end CompilerSuite

public unsafe def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let sourceFile := root / "tests" / "fixtures" / "compiler" / "LocalSyntax.lean"
  let pluginSource := root / "LeanFmt" / "CompilerPlugin.lean"
  let rulesSource := root / "LeanFmt" / "Rules.lean"
  let sourceBackup ← IO.FS.readFile sourceFile
  let pluginBackup ← IO.FS.readFile pluginSource
  let rulesBackup ← IO.FS.readFile rulesSource
  -- The fixture carries one deliberately misformatted line; the trailing whitespace is added by
  -- the suite rather than committed, so the tree stays lint-clean at rest.
  ensure ((sourceBackup.splitOn "emit_local_command\n").length == 2)
      "trailing-whitespace fixture could not find its unique command"
  let fixtureBackup := sourceBackup.replace "emit_local_command\n" "emit_local_command  \n"
  writeFile sourceFile fixtureBackup
  let ctx : CompilerSuite.Ctx :=
    { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
      sourceFile, pluginSource, rulesSource
      olean := root / ".lake" / "build" / "lib" / "lean" / "LocalSyntax.olean"
      trace := root / ".lake" / "build" / "lib" / "lean" / "LocalSyntax.trace"
      artifact := root / ".lake" / "build" / "lean-fmt-artifacts" / "LocalSyntax.json"
      sourceBackup, pluginBackup, rulesBackup, fixtureBackup }
  let cleanup : IO Unit := do
    writeFile ctx.sourceFile ctx.sourceBackup
    writeFile ctx.pluginSource ctx.pluginBackup
    writeFile ctx.rulesSource ctx.rulesBackup
    -- Leave the workspace built rather than merely restored: the suite corrupted `.lake` outputs.
    try
      CompilerSuite.lakeFacetBuild ctx "post-suite facet restore"
    catch _ =>
      pure ()
  let code ←
    try
      runCases "compiler" (CompilerSuite.cases ctx) args
    catch error =>
      cleanup
      throw error
  cleanup
  return code
