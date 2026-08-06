module

public import Test

/-!
# The application-formatter suite

Port of `tests/application-formatter/run.sh`. Validated frontend-native layout through preview,
diff, cache, and per-file publication: `format --check` and `diff` admit the same candidates,
a cached canonical answer is served without a frontend rerun, a stale member is rejected while
its healthy sibling still publishes, the complete admitted batch publishes the previewed bytes,
one elaboration-broken member does not stop another member's publication, and an admission
refusal maps to infrastructure exit 2.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace ApplicationFormatter

/-- Everything a case needs. The fixture files live in `work` under the repo's scratch root —
they must be inside the repository for `--root` resolution. -/
structure Ctx where
  root : System.FilePath
  application : String
  work : System.FilePath

private def aLean (ctx : Ctx) : System.FilePath :=
  ctx.work / "A.lean"

private def bLean (ctx : Ctx) : System.FilePath :=
  ctx.work / "B.lean"

private def aSource : String :=
  "module\n\ndef  alpha :Nat:=1\n"

private def bSource : String :=
  "module\n\ndef  beta :Nat:=2\n"

/-- `format --check` and `diff` agree on the same admitted candidates, and the frontend ran
exactly once per file. The previewed bytes are saved for the publication case. -/
private def testPreviewDiffAgreement (ctx : Ctx) : IO Unit := do
  writeFile (aLean ctx) aSource
  writeFile (bLean ctx) bSource
  let preview ←
    runProc ctx.application
        #["format", "--check", "--root", ctx.root.toString, "--no-cache", "--json",
          (aLean ctx).toString, (bLean ctx).toString]
        (cwd? := some ctx.root) (env := #[("LEAN_FMT_PROFILE_PHASES", some "1")])
  let diffRun ←
    runProc ctx.application
        #["format", "--diff", "--root", ctx.root.toString, "--no-cache", "--output-format", "json",
          (aLean ctx).toString, (bLean ctx).toString]
        (cwd? := some ctx.root)
  ensure (preview.exitCode == 1 && diffRun.exitCode == 1)
      s!"preview/diff did not both report changes: {preview.exitCode}/{diffRun.exitCode}"
  ensure ((preview.stderr.splitOn "cache.path_exact_render=1").length == 3)
      s!"frontend did not run exactly once per file:\n{preview.stderr}"
  let previewJson ← parseJson preview.stdout "preview"
  let diffJson ← parseJson diffRun.stdout "diff"
  let some previewFiles :=
    (jsonAt? previewJson [.field "files"]).bind
      (·.getArr?.toOption) | throw <| IO.userError "preview has no files"
  let some diffFiles :=
    (jsonAt? diffJson [.field "files"]).bind
      (·.getArr?.toOption) | throw <| IO.userError "diff has no files"
  let pathsOf (files : Array Lean.Json) :=
    files.map fun file => (file.getObjValAs? String "path").toOption.getD ""
  ensureEq "preview and diff disagree on the selection" (pathsOf diffFiles).toList
      (pathsOf previewFiles).toList
  for file in previewFiles do
    ensure ((file.getObjValAs? String "status").toOption == some "would-format")
        s!"preview status changed: {file.compress}"
  for file in diffFiles do
    ensure ((file.getObjValAs? String "status").toOption == some "would-diff")
        s!"diff status changed: {file.compress}"
  match previewFiles.toList with
  | [fileA, fileB] =>
    writeFile (ctx.work / "A.expected") ((fileA.getObjValAs? String "formatted").toOption.getD "")
    writeFile (ctx.work / "B.expected") ((fileB.getObjValAs? String "formatted").toOption.getD "")
  | _ =>
    throw <| IO.userError "preview did not admit exactly two files"

/-- A cached canonical answer is still selection-independent and must not rerun the frontend —
the sabotaged analyzer would fail the run if it were invoked. -/
private def testCacheService (ctx : Ctx) : IO Unit := do
  discard <|
      runProc ctx.application
        #["format", "--check", "--root", ctx.root.toString, "--json", (aLean ctx).toString] (cwd? :=
        some ctx.root)
  let cached ←
    runProc ctx.application
        #["format", "--check", "--root", ctx.root.toString, "--json", (aLean ctx).toString] (cwd? :=
        some ctx.root) (env :=
        #[("LEAN_FMT_PROFILE_PHASES", some "1"), ("LEAN_FMT_TEST_ANALYZER", some "/usr/bin/false")])
  ensure (cached.exitCode == 1)
      s!"cached preview did not report changes: exit {cached.exitCode}\n{cached.stderr}"
  ensureContains cached.stderr "cache.path_cache_hit=1" "cache service"

/-- Path metrics distinguish the source shortcut: `tests/fixtures/check/Clean.lean` is checked from module
evidence without a frontend render. -/
private def testPathMetrics (ctx : Ctx) : IO Unit := do
  let result ←
    runProc ctx.application
        #["check", "--root", ctx.root.toString, "--no-cache", "tests/fixtures/check/Clean.lean"]
        (cwd? := some ctx.root) (env := #[("LEAN_FMT_PROFILE_PHASES", some "1")])
  ensureContains result.stderr "cache.path_source_shortcut=1" "source shortcut"

/-- A stale member is rejected while its healthy sibling still publishes: the hook appends to B
after its analysis, so B's own stale-source check refuses its write and A's goes through.
Publication is per file; one member's failure no longer decides another member's fate. -/
private def testStalePublication (ctx : Ctx) : IO Unit := do
  writeFile (aLean ctx) aSource
  writeFile (bLean ctx) bSource
  let hook := ctx.work / "stale-hook"
  writeFile hook
      "#!/usr/bin/env bash\nif [[ $1 == */B.lean ]]; then \
    printf '\\n-- concurrent edit\\n' >>\"$1\"; fi\n"
  discard <| expectExit 0 "chmod the stale hook" "chmod" #["+x", hook.toString]
  let stale ←
    runProc ctx.application
        #["format", "--root", ctx.root.toString, "--no-cache", "--json", (aLean ctx).toString,
          (bLean ctx).toString]
        (cwd? := some ctx.root) (env := #[("LEAN_FMT_TEST_BEFORE_WRITE", some hook.toString)])
  ensure (stale.exitCode == 1) s!"stale member did not exit 1: {stale.exitCode}\n{stale.stderr}"
  ensureEq "A was not published beside its stale sibling"
      (← IO.FS.readFile (ctx.work / "A.expected")) (← IO.FS.readFile (aLean ctx))
  let bAfter ← IO.FS.readFile (bLean ctx)
  ensure (bAfter.startsWith bSource) "B's original bytes were modified"
  ensureContains bAfter "concurrent edit" "stale hook"
  let staleJson ← parseJson stale.stdout "stale"
  ensureJsonAt staleJson [.field "written"] (Lean.toJson (1 : Nat)) "stale member"
  let some files :=
    (jsonAt? staleJson [.field "files"]).bind
      (·.getArr?.toOption) | throw <| IO.userError "stale report has no files"
  let some aFile :=
    files.find? fun file =>
      (((jsonAt? file [.field "path"]).bind (·.getStr?.toOption)).getD "").endsWith
        "A.lean" | throw <| IO.userError "stale report lost A"
  ensure ((aFile.getObjValAs? String "status").toOption == some "formatted")
      s!"healthy member was not formatted: {aFile.compress}"
  let some bFile :=
    files.find? fun file =>
      (((jsonAt? file [.field "path"]).bind (·.getStr?.toOption)).getD "").endsWith
        "B.lean" | throw <| IO.userError "stale report lost B"
  ensure ((bFile.getObjValAs? String "status").toOption == some "rejected")
      s!"stale member was not rejected: {bFile.compress}"
  let bDiagnostics := ((jsonAt? bFile [.field "diagnostics"]).bind (·.getArr?.toOption)).getD #[]
  ensure (bDiagnostics.any fun diag => diag.compress.contains "source changed after analysis")
      "no diagnostic names the stale source"
  -- The batch-publication case runs next and needs A formattable again.
  writeFile (aLean ctx) aSource

/-- The complete admitted batch publishes the previewed bytes. -/
private def testBatchPublication (ctx : Ctx) : IO Unit := do
  writeFile (bLean ctx) bSource
  let written ←
    expectExit 0 "batch publication" ctx.application
        #["format", "--root", ctx.root.toString, "--no-cache", "--json", (aLean ctx).toString,
          (bLean ctx).toString]
        (cwd? := some ctx.root)
  ensureEq "A did not publish the previewed bytes" (← IO.FS.readFile (ctx.work / "A.expected"))
      (← IO.FS.readFile (aLean ctx))
  ensureEq "B did not publish the previewed bytes" (← IO.FS.readFile (ctx.work / "B.expected"))
      (← IO.FS.readFile (bLean ctx))
  let report ← parseJson written.stdout "write"
  ensureJsonAt report [.field "written"] (Lean.toJson (2 : Nat)) "batch publication"
  let some files :=
    (jsonAt? report [.field "files"]).bind
      (·.getArr?.toOption) | throw <| IO.userError "write report has no files"
  for file in files do
    ensureJsonAt file [.field "written"] (Lean.toJson true) "batch publication"

/-- One elaboration-broken member no longer poisons the run: A publishes its admitted layout
while the broken member is the run's only failure. Publication used to be one all-or-nothing
batch, so a single broken target rejected every admitted file beside it — on a real 1400-file
project, one file with elaboration errors rejected 1269 formattable ones. -/
private def testBrokenMemberPublication (ctx : Ctx) : IO Unit := do
  writeFile (aLean ctx) aSource
  let broken := ctx.work / "Broken.lean"
  writeFile broken "module\n\ndef  broken :Nat:=\"not a nat\"\n"
  let result ←
    expectExit 1 "broken member" ctx.application
        #["format", "--root", ctx.root.toString, "--no-cache", "--json", (aLean ctx).toString,
          broken.toString]
        (cwd? := some ctx.root)
  ensureEq "healthy member was not published beside the broken one"
      (← IO.FS.readFile (ctx.work / "A.expected")) (← IO.FS.readFile (aLean ctx))
  writeFile (aLean ctx) aSource
  let report ← parseJson result.stdout "broken member"
  ensureJsonAt report [.field "written"] (Lean.toJson (1 : Nat)) "broken member"
  ensureJsonAt report [.field "broken"] (Lean.toJson (1 : Nat)) "broken member"
  let some files :=
    (jsonAt? report [.field "files"]).bind
      (·.getArr?.toOption) | throw <| IO.userError "broken-member report has no files"
  for file in files do
    let diagnostics := ((jsonAt? file [.field "diagnostics"]).bind (·.getArr?.toOption)).getD #[]
    ensure (!(diagnostics.any fun diag => diag.compress.contains "batch was not published"))
        s!"batch coupling survived per-file publication: {file.compress}"
  let some brokenFile :=
    files.find? fun file =>
      (((jsonAt? file [.field "path"]).bind (·.getStr?.toOption)).getD "").endsWith
        "Broken.lean" | throw <| IO.userError "broken-member report lost Broken"
  ensure ((brokenFile.getObjValAs? String "status").toOption == some "broken")
      s!"broken member was not reported broken: {brokenFile.compress}"

/-- Formatter admission refusal maps to infrastructure exit 2: the throwing custom command fails
validation, nothing is written, and the file is reported as an infrastructure failure. -/
private def testRefusal (ctx : Ctx) : IO Unit := do
  let throwing := ctx.work / "Throwing.lean"
  writeFile throwing "module\n\nimport AdapterSyntax\n\nopen AdapterSyntax\n\nthrowing_command\n"
  let refusal ←
    runProc ctx.application
        #["format", "--check", "--root", ctx.root.toString, "--no-cache", "--json",
          throwing.toString]
        (cwd? := some ctx.root) (env := #[("LEAN_FMT_PROFILE_PHASES", some "1")])
  ensure (refusal.exitCode == 2) s!"refusal did not exit 2: {refusal.exitCode}\n{refusal.stderr}"
  ensureContains refusal.stderr "cache.path_validation_failure=1" "refusal"
  let report ← parseJson refusal.stdout "refusal"
  ensureJsonAt report [.field "written"] (Lean.toJson (0 : Nat)) "refusal"
  let failures := (jsonAt? report [.field "infrastructureFailures"]).bind (·.getArr?.toOption)
  ensure ((failures.map (·.size)).getD 0 > 0) "refusal reported no infrastructure failures"
  match
    (jsonAt? report [.field "files", .index 0]).bind fun file =>
      (file.getObjValAs? String "status").toOption with
  | some "infrastructure-failure" =>
    pure ()
  | other =>
    throw <| IO.userError s!"refusal file status changed: {repr other}"

end ApplicationFormatter

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  -- `Clean` is built here because the `path_source_shortcut` case reads module evidence for
  -- `tests/fixtures/check/Clean.lean`, and this suite used to build neither the module nor its facet: it
  -- passed only because some other suite had left `Clean.olean` in `.lake` -- an order dependency
  -- that turned red the first time anyone edited that fixture, since a stale `.olean` is not
  -- evidence. The `.olean` alone restores the shortcut; the `leanFmtArtifact` facet is not
  -- involved.
  discard <|
      expectExit 0 "fixture library build" "lake"
        #["build", "lean-fmt", "FormatterAdapterFixtures", "Clean"] (cwd? := some root) (env :=
        #[("LEAN_NUM_THREADS", some "1")])
  withScratchDir "application-formatter" fun work => do
      let ctx : ApplicationFormatter.Ctx :=
        { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, work }
      let cases : Array Case :=
        #[{ name := "preview-diff-agreement",
            run := ApplicationFormatter.testPreviewDiffAgreement ctx },
          { name := "cache-service", run := ApplicationFormatter.testCacheService ctx },
          { name := "path-metrics", run := ApplicationFormatter.testPathMetrics ctx },
          { name := "stale-publication", run := ApplicationFormatter.testStalePublication ctx },
          { name := "batch-publication", run := ApplicationFormatter.testBatchPublication ctx },
          { name := "broken-member-publication",
            run := ApplicationFormatter.testBrokenMemberPublication ctx },
          { name := "refusal", run := ApplicationFormatter.testRefusal ctx }]
      runCases "application-formatter" cases args
