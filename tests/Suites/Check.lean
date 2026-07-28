module

public import Test

/-!
# The check suite

Port of `tests/check/run.sh`: the core `check`/`format` pipeline end to end — the two producers
(artifact and exact frontend) agreeing, the check/format agreement invariant, broken and sabotaged
runs, `--workers` determinism, the result-cache strategy and invalidation matrix, and the
fix/render-path efficiency probes.

Lane: workspace — the suite clears and populates the root `.lean-fmt-cache`, edits
`tests/check/Findings.lean` and `LeanFmt/Cli.lean` in place (restored via `cp -p` backups), and
mutates the committed `Findings.trace` (restored byte-for-byte). Nothing else may touch this
workspace while it runs.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace Check

structure Ctx where
  root : System.FilePath
  application : String
  work : System.FilePath
  cacheRoot : System.FilePath

private def fallbackEnv : Array (String × Option String) :=
  #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"), ("LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE", some "1")]

private def sabotageEnv : Array (String × Option String) :=
  fallbackEnv ++ #[("LEAN_FMT_TEST_ANALYZER", some "/usr/bin/false")]

private def checkJson (ctx : Ctx) (expected : UInt32) (args : Array String) (label : String)
    (env : Array (String × Option String) := #[]) : IO Lean.Json := do
  let result ← expectExit expected label ctx.application args (cwd? := some ctx.root) (env := env)
  parseJson result.stdout label

/-- Run without parsing: the label, the raw result. -/
private def checkRaw (ctx : Ctx) (expected : UInt32) (args : Array String) (label : String)
    (env : Array (String × Option String) := #[]) : IO ProcResult :=
  expectExit expected label ctx.application args (cwd? := some ctx.root) (env := env)

/-- `cp -p` — bytes and mtime, for in-place edits of committed files. -/
private def cpPreserve (source destination : System.FilePath) : IO Unit := do
  discard <| expectExit 0 s!"cp -p {source.fileName.getD "?"}" "cp"
    #["-p", source.toString, destination.toString]

/-- Every `*.json` entry under the result cache, sorted. -/
private def cacheEntries (ctx : Ctx) : IO (Array System.FilePath) := do
  let resultsDir := ctx.cacheRoot / "results"
  if !(← resultsDir.pathExists) then return #[]
  let entries ← resultsDir.walkDir
  return (entries.filter (·.extension == some "json")).qsort (·.toString < ·.toString)

/-- The one cache entry a single-file run must have written. -/
private def theCacheEntry (ctx : Ctx) (label : String) : IO System.FilePath := do
  let entries ← cacheEntries ctx
  ensureEq s!"{label}: expected exactly one cache entry" 1 entries.size
  return entries[0]!

/-- The finding tuples a report carries, for cross-mode comparison. -/
private def findingsOf (report : Lean.Json) (label : String) : IO (List (String × Nat × Nat × String)) := do
  let files := ((jsonAt? report [.field "files"]).bind (·.getArr?.toOption)).getD #[]
  ensureEq s!"{label}: expected exactly one file" 1 files.size
  return (((jsonAt? files[0]! [.field "findings"]).bind (·.getArr?.toOption)).getD #[]).toList.map
    fun finding =>
      ((finding.getObjValAs? String "code").toOption.getD "",
        natAt? finding [.field "range", .field "start"] |>.getD 0,
        natAt? finding [.field "range", .field "stop"] |>.getD 0,
        (finding.getObjValAs? String "message").toOption.getD "")

/-- The committed sources this suite may never leave modified. -/
private def sources : Array String := #[
  "tests/compiler/LocalSyntax.lean", "tests/check/Clean.lean", "tests/check/Findings.lean",
  "tests/check/MalformedHeader.lean", "tests/check/UnresolvedImport.lean", "tests/check/Security.lean"
]

private def snapshot (root : System.FilePath) : IO (Array (String × String × Int × UInt32)) := do
  let mut rows := #[]
  for name in sources do
    let path := root / name
    let modified := (← path.metadata).modified
    rows := rows.push (name, ← sha256 path, modified.sec, modified.nsec)
  return rows

/-- The flag surface: `--check-elab` is gone from help and rejected on `fix`. -/
private def testFlagSurface (ctx : Ctx) : IO Unit := do
  let help ← checkRaw ctx 0 #["check", "--help"] "check --help"
  ensure (!(help.stdout.contains "--check-elab")) "--check-elab leaked into help"
  discard <| checkRaw ctx 2 #["fix", "--check-elab", "tests/check/Clean.lean"] "removed --check-elab"

/-- The two producers agree on Findings, and both reproduce the recorded golden byte for
byte. The golden was recorded *before* any renderer shipped, so it is evidence and not a
restatement of current behavior. -/
private def testProducerParity (ctx : Ctx) : IO Unit := do
  discard <| checkJson ctx 0 #["check", "--root", ".", "--json", "--no-cache",
    "tests/check/Clean.lean"] "clean"
  let artifact ← checkRaw ctx 1 #["check", "--root", ".", "--json", "--no-cache",
    "tests/check/Findings.lean"] "artifact findings"
  let fallback ← checkRaw ctx 1 #["check", "--root", ".", "--json", "--no-cache",
    "tests/check/Findings.lean"] "fallback findings" (env := fallbackEnv)
  ensureEq "artifact and fallback findings diverged" artifact.stdout fallback.stdout
  let golden ← IO.FS.readFile (ctx.root / "tests" / "reporting" / "golden" / "json-check.json")
  ensureEq "the JSON report changed shape against the golden" golden artifact.stdout

/-- `check` and `format` must never disagree about one unchanged file. `check` takes the
source-only shortcut; `format` takes the artifact path for the projection it must print. Only the
findings are comparable — mode, status, and rendered text are meant to differ. -/
private def testCheckFormatAgreement (ctx : Ctx) : IO Unit := do
  let checked ← checkJson ctx 1 #["check", "--root", ".", "--json", "--no-cache",
    "tests/check/Findings.lean"] "agreement check"
  let formatted ← checkJson ctx 1 #["format", "--check", "--root", ".", "--json", "--no-cache",
    "tests/check/Findings.lean"] "agreement format"
  let checkedFindings ← findingsOf checked "agreement check"
  ensure (!checkedFindings.isEmpty) "the agreement fixture produced no findings; vacuous"
  let formattedFindings ← findingsOf formatted "agreement format"
  ensureEq "check and format disagree" checkedFindings formattedFindings

/-- The custom-syntax parity: artifact and fallback agree on LocalSyntax, and the exact envelope's
projection agrees with the build frontend's integrated artifact **exactly** — the whole `syntaxData`
object, compared as written.

It used to be compared with the options table held out, because the two producers genuinely
disagreed there: the build frontend records `internal.cmdlineSnapshots` and the on-demand frontend
does not invent it. The artifact carries no options any more, so the exclusion is gone and the
comparison covers everything the two producers write.

File-local `syntax` reaches the kind table, which only an elaborated environment can parse. -/
private def testCustomSyntax (ctx : Ctx) : IO Unit := do
  let artifact ← checkRaw ctx 0 #["check", "--root", ".", "--json", "--no-cache",
    "tests/compiler/LocalSyntax.lean"] "artifact custom"
  let fallback ← checkRaw ctx 0 #["check", "--root", ".", "--json", "--no-cache",
    "tests/compiler/LocalSyntax.lean"] "fallback custom" (env := fallbackEnv)
  ensureEq "artifact and fallback custom-syntax reports diverged" artifact.stdout fallback.stdout
  let setup ← setupFile ctx.root ctx.work "tests/compiler/LocalSyntax.lean"
  let envelope ← project ctx setup
  let integratedText ← IO.FS.readFile
    (ctx.root / ".lake" / "build" / "lean-fmt-artifacts" / "LocalSyntax.json")
  let integrated ← parseJson integratedText "integrated artifact"
  let some fallbackArtifact := jsonAt? envelope [.field "artifact"]
    | throw <| IO.userError "exact envelope has no artifact"
  let some fallbackSyntax := jsonAt? fallbackArtifact [.field "syntaxData"]
    | throw <| IO.userError "exact envelope has no syntaxData"
  let some integratedSyntax := jsonAt? integrated [.field "syntaxData"]
    | throw <| IO.userError "integrated artifact has no syntaxData"
  ensureEq "the two frontends' syntax projections diverged"
    fallbackSyntax.compress integratedSyntax.compress
  let kindEntries := (jsonAt? fallbackSyntax [.field "kinds"]).bind (·.getArr?.toOption)
  let kinds := (kindEntries.getD #[]).filterMap (·.getStr?.toOption)
  ensure (kinds.contains "commandEmit_local_command")
    "file-local syntax did not reach the kind table"
  let commandEntries := (jsonAt? fallbackSyntax [.field "commands"]).bind (·.getArr?.toOption)
  ensure (!(commandEntries.getD #[]).isEmpty) "the projection recorded no commands"
  let terminal := natAt? fallbackSyntax [.field "terminal"] |>.getD 0
  let entryArray := (jsonAt? fallbackSyntax [.field "entries"]).bind (·.getArr?.toOption)
  ensure (terminal < (entryArray.getD #[]).size) "terminal is past the entry array"
where
  project (ctx : Ctx) (setup : System.FilePath) : IO Lean.Json := do
    let result ← expectExit 0 "exact envelope" "lake"
      #["env", ctx.application, "__analyze-exact", setup.toString,
        "tests/compiler/LocalSyntax.lean", "tests/compiler/LocalSyntax.lean"]
      (cwd? := some ctx.root)
    parseJson result.stdout "exact envelope"

/-- Broken files: sorted paths, both diagnostics surfaced, `broken` counts them, and no
infrastructure failure is invented. -/
private def testBroken (ctx : Ctx) : IO Unit := do
  let report ← checkJson ctx 1 #["check", "--root", ".", "--json", "--no-cache",
    "tests/check/UnresolvedImport.lean", "tests/check/MalformedHeader.lean"] "broken"
    (env := fallbackEnv)
  let files := ((jsonAt? report [.field "files"]).bind (·.getArr?.toOption)).getD #[]
  let paths := files.toList.map fun file => (file.getObjValAs? String "path").toOption.getD ""
  ensureEq "broken: files not sorted"
    ["tests/check/MalformedHeader.lean", "tests/check/UnresolvedImport.lean"] paths
  let diagnostics := "\n".intercalate <| files.toList.flatMap fun file =>
    (((jsonAt? file [.field "diagnostics"]).bind (·.getArr?.toOption)).getD #[]).toList.map
      (·.compress)
  ensureContains diagnostics "unexpected end of input" "broken: malformed header not diagnosed"
  ensureContains diagnostics "DefinitelyMissing" "broken: unresolved import not diagnosed"
  ensureJsonAt report [.field "broken"] (Lean.toJson (2 : Nat)) "broken"
  ensureJsonAt report [.field "infrastructureFailures"] (.arr #[]) "broken"

/-- A sabotaged analyzer turns every file into an infrastructure failure and aborts with 2. -/
private def testAbort (ctx : Ctx) : IO Unit := do
  let report ← checkJson ctx 2 #["check", "--root", ".", "--json", "--no-cache",
    "tests/check/Findings.lean", "tests/check/Clean.lean"] "abort" (env := sabotageEnv)
  let files := ((jsonAt? report [.field "files"]).bind (·.getArr?.toOption)).getD #[]
  let paths := files.toList.map fun file => (file.getObjValAs? String "path").toOption.getD ""
  ensureEq "abort: files" ["tests/check/Clean.lean", "tests/check/Findings.lean"] paths
  let failures := ((jsonAt? report [.field "infrastructureFailures"]).bind
    (·.getArr?.toOption)).getD #[]
  ensureEq "abort: expected two infrastructure failures" 2 failures.size

/-- `--workers` changes scheduling, never output: the parallel run assembles results by target
index, so its report is byte-identical to the serial run's. Three fixtures with three different
outcomes exercise the fold over every report shape; the env vars force every fixture through a
real frontend child, so the comparison cannot pass vacuously. The serial arm names `--workers 1`
rather than relying on the default, which is the machine's core count.

The `--workers 4` arm and the failure count guard against a parent that refuses a file for the memory
it holds. The clause that once did this counted each child's shared `.olean` mapping in full and then
split it between workers, so the number of workers decided which files got analyzed at all. Four
workers over three fixtures also asks for more workers than there are targets. These fixtures import
little, so the count catches only a gross regression; the corpus that exposed the original defect —
187 of 200 mathlib files refused at `--workers 8` — is not a fixture here. -/
private def testWorkersDeterminism (ctx : Ctx) : IO Unit := do
  let files := #["tests/check/Clean.lean", "tests/check/Findings.lean", "tests/check/Layout.lean"]
  let serial ← checkRaw ctx 1
    (#["check", "--root", ".", "--json", "--no-cache", "--workers", "1"] ++ files) "serial"
    (env := fallbackEnv)
  let parallel ← checkRaw ctx 1
    (#["check", "--root", ".", "--json", "--no-cache", "--workers", "2"] ++ files) "parallel"
    (env := fallbackEnv)
  ensureEq "--workers changed the report" serial.stdout parallel.stdout
  let oversubscribed ← checkRaw ctx 1
    (#["check", "--root", ".", "--json", "--no-cache", "--workers", "4"] ++ files) "oversubscribed"
    (env := fallbackEnv)
  ensureEq "--workers 4 changed the report" serial.stdout oversubscribed.stdout
  let report ← parseJson oversubscribed.stdout "oversubscribed"
  ensureJsonAt report [.field "infrastructureFailures"] (.arr #[])
    "--workers 4 refused a file the serial run analyzed"
  -- A repeated run over the artifact path is byte-identical too.
  let repeated ← checkRaw ctx 1 #["check", "--root", ".", "--json", "--no-cache",
    "tests/check/Findings.lean"] "repeated"
  let golden ← IO.FS.readFile (ctx.root / "tests" / "reporting" / "golden" / "json-check.json")
  ensureEq "repeated artifact run changed shape" golden repeated.stdout

/-- The two cache strategies. The exact frontend runs the whole registry and writes a syntax-tier
entry; the source-only shortcut writes a narrower source-tier entry. The entries deliberately
differ; what stays strategy-independent is the *report*, and the fact that a real hit bypasses the
analyzer child. -/
private def testCacheStrategies (ctx : Ctx) : IO Unit := do
  removeDirAll? ctx.cacheRoot
  let artifact ← checkRaw ctx 1 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "cache artifact"
  let moduleEntry ← theCacheEntry ctx "cache artifact"
  let moduleEntryText ← IO.FS.readFile moduleEntry
  let hit ← checkRaw ctx 1 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "cache hit" (env := sabotageEnv)
  ensureEq "a real cache hit changed the report" artifact.stdout hit.stdout
  removeDirAll? ctx.cacheRoot
  let fallback ← checkRaw ctx 1 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "cache fallback" (env := fallbackEnv)
  let fallbackEntry ← theCacheEntry ctx "cache fallback"
  -- The shortcut wrote the source-tier subset; the exact frontend wrote the syntax-tier superset.
  -- The superset adds the preview syntax finding (FMT006) that the default report projects back
  -- out.
  let moduleResult ← cachedResult moduleEntryText "module"
  let fallbackResult ← cachedResult (← IO.FS.readFile fallbackEntry) "fallback"
  ensureJsonAt moduleResult [.field "tier"] (Lean.toJson "source") "cache tiers"
  ensureJsonAt fallbackResult [.field "tier"] (Lean.toJson "syntax") "cache tiers"
  let shortCodes := codesOf moduleResult
  let fullCodes := codesOf fallbackResult
  ensure (shortCodes.all (fullCodes.contains ·) && shortCodes.length < fullCodes.length)
    s!"cache tiers: {shortCodes} is not a strict subset of {fullCodes}"
  ensure (!shortCodes.contains "FMT006" && fullCodes.contains "FMT006")
    "cache tiers: FMT006 is not the superset's extra finding"
  ensureEq "the two strategies' reports diverged" artifact.stdout fallback.stdout
where
  cachedResult (entryText : String) (label : String) : IO Lean.Json := do
    let entry ← parseJson entryText label
    let some result := jsonAt? entry [.field "entries", .index 0, .field "analysis",
        .field "result"]
      | throw <| IO.userError s!"{label}: cache entry has no result"
    return result
  codesOf (result : Lean.Json) : List String :=
    (((jsonAt? result [.field "findings"]).bind (·.getArr?.toOption)).getD #[]).toList.map
      fun finding => (finding.getObjValAs? String "code").toOption.getD ""

/-- A syntax-tier answer read from the module artifact and the same answer elaborated from source
are cache-interchangeable: one identity, one entry, byte for byte. How the answer was obtained must
not be observable in the cache at all, or a warm lookup could serve an entry the current route
would not have written. The compiler fixture carries file-local syntax and FMT011 is syntax tier,
so neither run can take the source-only shortcut.

This case used to drive `format --check`, because rendering had two routes and their entries
differed by a frontend run each recorded. The artifact renderer was deleted — it measured slower
and rejected files the exact route accepted — so rendering has one route, and the surviving
two-route surface is this one, where the assertion is stricter than it could be before. -/
private def testCacheCanonical (ctx : Ctx) : IO Unit := do
  discard <| expectExit 0 "lake build +ArtifactLayout:leanFmtArtifact" "lake"
    #["build", "+ArtifactLayout:leanFmtArtifact"] (cwd? := some ctx.root)
  let select := #["check", "--root", ".", "--json", "--select", "FMT011",
    "tests/compiler/ArtifactLayout.lean"]
  removeDirAll? ctx.cacheRoot
  let artifact ← checkRaw ctx 0 select "canonical artifact"
  let artifactText ← IO.FS.readFile (← theCacheEntry ctx "canonical artifact")
  removeDirAll? ctx.cacheRoot
  let exact ← checkRaw ctx 0 select "canonical exact"
    (env := #[("LEAN_FMT_DISABLE_ARTIFACT", some "1")])
  let exactText ← IO.FS.readFile (← theCacheEntry ctx "canonical exact")
  -- Named before the byte comparison so a diff reports the field, not two blobs.
  let artifactJson ← parseJson artifactText "canonical artifact entry"
  let exactJson ← parseJson exactText "canonical exact entry"
  let entry : List JsonStep := [.field "entries", .index 0]
  let result := entry ++ [JsonStep.field "analysis", .field "result"]
  let agreed : List (String × List JsonStep) := [
    ("the cache schema", [.field "schema"]),
    ("the workspace base", [.field "base"]),
    ("entry identity", entry ++ [.field "identity"]),
    ("the closure digest", entry ++ [.field "closureDigest"]),
    ("the source digest", entry ++ [.field "sourceDigest"]),
    ("the findings", result ++ [.field "findings"]),
    ("the tier", result ++ [.field "tier"]),
    ("the suppression facts", result ++ [.field "suppression"]),
    ("the semantic caps", result ++ [.field "caps"])]
  for (what, path) in agreed do
    ensure (jsonAt? artifactJson path == jsonAt? exactJson path)
      s!"artifact-served and exact entries disagree on {what}"
  ensureEq "artifact-served and exact cache entries are not byte-identical" exactText artifactText
  ensureEq "artifact-served and exact reports are not byte-identical" artifact.stdout exact.stdout

/-- Selection is a projection over one cached result, not a component of its identity. Two runs
that differ only in `--select` must collide onto the same entry — an entry collision, not a
report collision (the reports differ, and are meant to). All three env vars are load-bearing: a
plain `check` on a current module takes the source-only shortcut and never consults the analyzer
or the cache, so a disabled analyzer alone would prove nothing. -/
private def testSelectCollision (ctx : Ctx) : IO Unit := do
  removeDirAll? ctx.cacheRoot
  let every ← checkJson ctx 1 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "select all"
  let selected ← checkJson ctx 0 #["check", "--root", ".", "--json", "--select", "FMT002",
    "tests/check/Findings.lean"] "select FMT002"
    (env := #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"),
      ("LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE", some "1"),
      ("LEAN_FMT_TEST_ANALYZER", some "/usr/bin/false")])
  ensureEq "selection became a component of cache identity" 1 (← cacheEntries ctx).size
  let everyCodes := (← findingsOf every "select all").map (·.1)
  -- FMT002 is a source-tier rule that does not fire on this fixture (no bidi mark), so it forces
  -- a cache read yet projects nothing -- the collision the test needs.
  ensure (everyCodes.contains "FMT003") "the selection fixture lost its unselected rule"
  ensureEq "--select FMT002 reported something else" ([] : List String)
    ((← findingsOf selected "select FMT002").map (·.1))

/-- Corrupt committed entries are misses; a stray partial temporary cannot shadow a valid
entry. -/
private def testCacheCorruption (ctx : Ctx) : IO Unit := do
  let fallbackEntry ← theCacheEntry ctx "corruption base"
  writeFile fallbackEntry "{\"partial\":"
  discard <| checkRaw ctx 2 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "cache corrupt" (env := sabotageEnv)
  let repaired ← checkRaw ctx 1 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "cache repaired" (env := fallbackEnv)
  writeFile (ctx.cacheRoot / "results" / (fallbackEntry.fileName.getD "entry" ++ ".tmp-interrupted"))
    "{\"partial\":"
  -- The stray temporary sits next to the entry, not at it: the run below must still hit.
  let stray ← checkRaw ctx 1 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "cache partial" (env := sabotageEnv)
  ensureEq "a stray temporary shadowed a valid entry" repaired.stdout stray.stdout

/-- Exact source bytes and the trusted build-trace epoch independently invalidate a result. -/
private def testCacheInvalidation (ctx : Ctx) : IO System.FilePath := do
  let findingsPath := ctx.root / "tests" / "check" / "Findings.lean"
  let backup := ctx.work / "Findings.lean.backup"
  cpPreserve findingsPath backup
  IO.FS.withFile findingsPath .append fun handle =>
    handle.putStr "\n-- cache-source-invalidation\n"
  discard <| checkRaw ctx 2 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "cache source miss" (env := sabotageEnv)
  cpPreserve backup findingsPath
  let trace := ctx.root / ".lake" / "build" / "lib" / "lean" / "Findings.trace"
  let traceBackup := ctx.work / "Findings.trace.backup"
  cpPreserve trace traceBackup
  -- The key is what the trace *records* -- the content-addressed output names -- not the trace
  -- file's bytes. Whitespace that leaves the recorded outputs identical leaves the grammar
  -- identical, so it must still hit.
  IO.FS.withFile trace .append fun handle => handle.putStr "\n"
  let reference ← checkRaw ctx 1 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "cache reference" (env := fallbackEnv)
  let whitespace ← checkRaw ctx 1 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "cache trace whitespace" (env := sabotageEnv)
  ensureEq "trace whitespace forced a miss" reference.stdout whitespace.stdout
  cpPreserve traceBackup trace
  -- A recorded output name that no longer matches must force a miss. This tests the key that is
  -- actually consulted.
  let traceJson ← parseJson (← IO.FS.readFile trace) "trace"
  let some outputs := jsonAt? traceJson [.field "outputs"]
    | throw <| IO.userError "trace has no outputs"
  let some firstOutput := (jsonAt? outputs [.field "o", .index 0]).bind (·.getStr?.toOption)
    | throw <| IO.userError "trace has no recorded output"
  ensure (firstOutput.endsWith ".olean") s!"trace output is not an olean: {firstOutput}"
  let mutated := "0000000000000000" ++ (firstOutput.drop 16).toString
  let mutatedTrace := traceJson.setObjVal! "outputs"
    (outputs.setObjVal! "o" (.arr #[Lean.toJson mutated]))
  ensure (mutated != firstOutput) "trace mutation was vacuous"
  writeFile trace mutatedTrace.compress
  discard <| checkRaw ctx 2 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "cache trace miss" (env := sabotageEnv)
  cpPreserve traceBackup trace
  IO.FS.rename trace (ctx.work / "Findings.trace.missing")
  discard <| checkRaw ctx 2 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "cache untrusted epoch" (env := sabotageEnv)
  IO.FS.rename (ctx.work / "Findings.trace.missing") trace
  let restored ← checkRaw ctx 1 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "cache restored identity" (env := sabotageEnv)
  ensureEq "restored identity did not hit" reference.stdout restored.stdout
  return reference.stdout

/-- Editing an unrelated project source, without rebuilding, does **not** invalidate another
file's entry — the reversal of the old per-source epoch is the point of that
stack. `lean-fmt` fetches its Lake graph with `noBuild := true`, so the grammar available to an
uncached run is the one in the artifacts on disk, which this edit does not touch. -/
private def testDependencySourceEdit (ctx : Ctx) (reference : System.FilePath) : IO Unit := do
  let projectSource := ctx.root / "LeanFmt" / "Cli.lean"
  let backup := ctx.work / "Cli.lean.backup"
  cpPreserve projectSource backup
  IO.FS.withFile projectSource .append fun handle =>
    handle.putStr "\n-- cache-project-source-invalidation\n"
  let hit ← checkRaw ctx 1 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "dependency source hit" (env := sabotageEnv)
  ensureEq "an unrelated source edit invalidated the entry" reference hit.stdout
  -- The served entry is the one a cacheless run under this same build state produces.
  let uncached ← checkRaw ctx 1 #["check", "--root", ".", "--json", "--no-cache",
    "tests/check/Findings.lean"] "dependency source uncached"
    (env := #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"),
      ("LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE", some "1")])
  ensureEq "the cache disagrees with the same run without a cache" reference uncached.stdout
  cpPreserve backup projectSource
  let restored ← checkRaw ctx 1 #["check", "--root", ".", "--json",
    "tests/check/Findings.lean"] "dependency source restored" (env := sabotageEnv)
  ensureEq "the restored source did not hit" reference restored.stdout

/-- A disabled cache performs neither reads nor writes. -/
private def testCacheDisabled (ctx : Ctx) : IO Unit := do
  discard <| checkRaw ctx 2 #["check", "--root", ".", "--json", "--no-cache",
    "tests/check/Findings.lean"] "cache disabled read" (env := sabotageEnv)
  removeDirAll? ctx.cacheRoot
  discard <| checkRaw ctx 0 #["check", "--root", ".", "--json", "--no-cache",
    "tests/check/Clean.lean"] "cache disabled write"
  ensure (!(← ctx.cacheRoot.pathExists)) "--no-cache still wrote the cache"

/-- A mismatched toolchain refuses with the build's own wording. -/
private def testToolchainMismatch (ctx : Ctx) : IO Unit := do
  let mismatch := ctx.work / "mismatch"
  IO.FS.createDirAll mismatch
  writeFile (mismatch / "lean-toolchain") "leanprover/lean4:v0.0.0\n"
  let result ← checkRaw ctx 2 #["check", "--root", mismatch.toString, "--json"] "mismatch"
  ensureContains result.stderr "does not match this lean-fmt build" "mismatch"

/-- A requested file that does not exist is named in the caller's own terms — including a whole
space-joined list arriving as one argument, quoted verbatim. -/
private def testMissingFiles (ctx : Ctx) : IO Unit := do
  let missing ← checkRaw ctx 2 #["check", "--root", ".", "--json",
    "tests/check/DoesNotExist.lean"] "missing"
  ensureContains missing.stderr "selected file does not exist: tests/check/DoesNotExist.lean"
    "missing"
  let listMissing ← checkRaw ctx 2 #["check", "--root", ".", "--json",
    "tests/check/Clean.lean tests/check/Findings.lean"] "missing list"
  ensureContains listMissing.stderr
    "selected file does not exist: tests/check/Clean.lean tests/check/Findings.lean" "missing list"

/-- The source-security family end to end, on committed bytes: a bidi mark inside a line comment
and a NUL inside a string literal, surfaced byte-exact in normalized coordinates. -/
private def testSecurity (ctx : Ctx) : IO Unit := do
  let report ← checkJson ctx 1 #["check", "--root", ".", "--json", "--no-cache",
    "tests/check/Security.lean"] "security"
  let files := ((jsonAt? report [.field "files"]).bind (·.getArr?.toOption)).getD #[]
  ensureEq "security: one file" 1 files.size
  ensureJsonAt files[0]! [.field "status"] (Lean.toJson "findings") "security"
  let findings ← findingsOf report "security"
  ensureEq "security: findings"
    [("FMT002", 17, 20, "suspicious bidirectional control U+202E"),
     ("FMT001", 45, 46, "forbidden control byte U+0000")] findings
  -- Report-only: neither security finding carries a fix, and nothing is withheld as unsafe.
  let rawFindings := ((jsonAt? files[0]! [.field "findings"]).bind (·.getArr?.toOption)).getD #[]
  for finding in rawFindings do
    ensure ((jsonAt? finding [.field "fix"]).isNone) "security finding carried a fix"
  ensureJsonAt report [.field "withheldUnsafe"] (Lean.toJson (0 : Nat)) "security"
  ensureJsonAt report [.field "written"] (Lean.toJson (0 : Nat)) "security"

/-- `fix` on a source-only selection takes the source shortcut — with both the
analyzer and the artifact disabled the fix still succeeds, proof it consulted neither. -/
private def testFixShortcut (ctx : Ctx) : IO Unit := do
  let findingsPath := ctx.root / "tests" / "check" / "Findings.lean"
  let backup := ctx.work / "Findings.effbak"
  cpPreserve findingsPath backup
  let report ← checkJson ctx 0 #["fix", "--root", ".", "--json", "--no-cache",
    "--select", "FMT003", "tests/check/Findings.lean"] "fix shortcut"
    (env := #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"),
      ("LEAN_FMT_TEST_ANALYZER", some "/usr/bin/false")])
  cpPreserve backup findingsPath
  ensureJsonAt report [.field "infrastructureFailures"] (.arr #[]) "fix shortcut"
  ensureJsonAt report [.field "written"] (Lean.toJson (1 : Nat)) "fix shortcut"

/-- A syntax `--select` does not choose execution strategy. Plain `format --check` and the
syntax-rule selection both take exactly one renderer path, and it is the same one.

The assertion is the mirror image of what it was. There were two renderers, and this case pinned
that both spellings reached the artifact-fed one and neither reached the exact one; the artifact
renderer was deleted after it measured slower and wrong, so now neither spelling may reach anything
but the exact one. The constraint being gated never moved: rule selection is a projection over
canonical results and must not pick a strategy. -/
private def testRenderPath (ctx : Ctx) : IO Unit := do
  let profileEnv := #[("LEAN_FMT_PROFILE_PHASES", some "1")]
  for (label, extra) in [("plain", #[]), ("fmt011", #["--preview", "--select", "FMT011"])] do
    let result ← checkRaw ctx 1
      (#["format", "--check", "--root", ".", "--json", "--no-cache"] ++ extra ++
        #["tests/check/Findings.lean"]) s!"render path {label}" (env := profileEnv)
    ensureContains result.stderr "cache.path_exact_render=1" s!"render path {label}"
    -- A rendering run may not fetch the module artifact: nothing left can read it.
    ensure (!(result.stderr.splitOn "\n").any (·.startsWith "cache.official_artifact_"))
      s!"render path {label}: fetched an artifact it cannot use"

/-- The metadata snapshot: every committed source the suite touched came back byte- and
mtime-identical. -/
private def testSourcesUnchanged (ctx : Ctx) (before : Array (String × String × Int × UInt32)) :
    IO Unit := do
  ensureEq "the suite left a committed source modified" before.toList (← snapshot ctx.root).toList

end Check

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  removeDirAll? (root / ".lean-fmt-cache")
  discard <| expectExit 0 "lake build artifact facets" "lake"
    #["build", "lean-fmt", "LocalSyntax:leanFmtArtifact", "Findings:leanFmtArtifact"]
    (cwd? := some root)
  withScratchDir "check" fun work => do
    let ctx : Check.Ctx :=
      { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, work
        cacheRoot := root / ".lean-fmt-cache" }
    let before ← Check.snapshot root
    -- These two cases share state (the reference report the invalidation cases compare against
    -- is produced mid-sequence), so they compose as one case each around a returned value.
    let invalidation : IO Unit := do
      let reference ← Check.testCacheInvalidation ctx
      Check.testDependencySourceEdit ctx reference
    let cases : Array Case := #[
      { name := "flag-surface", run := Check.testFlagSurface ctx },
      { name := "producer-parity", run := Check.testProducerParity ctx },
      { name := "check-format-agreement", run := Check.testCheckFormatAgreement ctx },
      { name := "custom-syntax", run := Check.testCustomSyntax ctx },
      { name := "broken", run := Check.testBroken ctx },
      { name := "abort", run := Check.testAbort ctx },
      { name := "workers-determinism", run := Check.testWorkersDeterminism ctx },
      { name := "cache-strategies", run := Check.testCacheStrategies ctx },
      { name := "cache-canonical", run := Check.testCacheCanonical ctx },
      { name := "select-collision", run := Check.testSelectCollision ctx },
      { name := "cache-corruption", run := Check.testCacheCorruption ctx },
      { name := "cache-invalidation", run := invalidation },
      { name := "cache-disabled", run := Check.testCacheDisabled ctx },
      { name := "toolchain-mismatch", run := Check.testToolchainMismatch ctx },
      { name := "missing-files", run := Check.testMissingFiles ctx },
      { name := "security", run := Check.testSecurity ctx },
      { name := "fix-shortcut", run := Check.testFixShortcut ctx },
      { name := "render-path", run := Check.testRenderPath ctx },
      { name := "sources-unchanged", run := Check.testSourcesUnchanged ctx before }
    ]
    runCases "check" cases args
