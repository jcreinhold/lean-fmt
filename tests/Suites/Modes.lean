module

public import Test

/-!
# The modes suite

Port of `tests/modes/run.sh` — the largest single suite: every product mode (`check`, `format`,
`diff`, `fix`, `rules`, `compiler setup/status`, `clean`, `config show`) over the committed
`tests/fixtures/check` fixtures and a family of scratch fixtures under `tests/modes/`. The scratch files
carry trailing whitespace or no final newline, so they are generated at runtime, never committed
(`git diff --check` rejects a checked-in file with trailing spaces, and editors strip them on
save), and removed when the suite ends. `tests/fixtures/check/Findings.lean` and `tests/fixtures/check/Layout.lean`
are tracked files the suite edits in place, so restoring them is not cleanup — it is the
difference between a failing test and a dirty working tree the next run silently measures
instead. Both are restored through `cp -p` backups, from a `finally`, exactly like the old
script's trap.

Lane: exclusive — the suite clears the root `.lean-fmt-cache`, writes into `.lake/build`, and
builds a downstream project against this checkout.
-/

open LeanFmt.Test

namespace Modes

structure Ctx where
  root : System.FilePath
  app : String
  work : System.FilePath
  findings : System.FilePath
  layout : System.FilePath
  modesDir : System.FilePath
  cacheRoot : System.FilePath
  artifacts : System.FilePath
  backupFindings : System.FilePath
  backupLayout : System.FilePath

private def Ctx.mode (ctx : Ctx) (name : String) : System.FilePath :=
  ctx.modesDir / name

/-- `cp -p`: the byte- and metadata-preserving copy the old script's backups and restores used. -/
private def cpPreserve (source destination : System.FilePath) : IO Unit := do
  discard <|
      expectExit 0 s!"cp -p {source} {destination}" "cp"
        #["-p", source.toString, destination.toString]

private def run (ctx : Ctx) (expected : UInt32) (label : String) (args : Array String)
    (env : Array (String × Option String) := #[]) : IO ProcResult :=
  expectExit expected label ctx.app args (cwd? := some ctx.root) (env := env) (timeoutMs :=
    some 600000)

private def runJson (ctx : Ctx) (expected : UInt32) (label : String) (args : Array String)
    (env : Array (String × Option String) := #[]) : IO Lean.Json := do
  parseJson (← run ctx expected label args env).stdout label

private def checkArgs (file : String) : Array String :=
  #["check", "--root", ".", "--json", "--no-cache", file]

private def formatCheckArgs (file : String) : Array String :=
  #["format", "--check", "--root", ".", "--json", "--no-cache", file]

private def diffArgs (file : String) : Array String :=
  #["diff", "--root", ".", "--no-cache", file]

private def fixArgs (file : String) : Array String :=
  #["fix", "--root", ".", "--json", "--no-cache", file]

/-- The old script's `stat -f %Lp || stat -c %a`: permission bits, portably. -/
private def fileMode (path : System.FilePath) : IO String := do
  let result ←
    expectExit 0 "stat" "sh"
        #["-c", "stat -f %Lp \"$1\" 2>/dev/null || stat -c %a \"$1\"", "sh", path.toString]
  return result.stdout.trimAscii.toString

/-- One `metadata` line: path, sha256, mtime in nanoseconds, permission bits. -/
private def metadataLine (path : System.FilePath) : IO String := do
  let digest ← sha256 path
  let fileMeta ← path.metadata
  let nanos : Int := fileMeta.modified.sec * 1000000000 + fileMeta.modified.nsec.toNat
  return s!"{path} {digest} {nanos} {← fileMode path}"

/-- `tree_metadata`: the same line for every file under `root`, relpath-sorted. -/
private def treeMetadata (root : System.FilePath) : IO String := do
  if !(← root.pathExists) then
    return ""
  let entries ← root.walkDir
  let rootPrefix := root.toString ++ "/"
  let mut lines : Array String := #[]
  for path in entries.toList.mergeSort (toString · < toString ·)do
    -- Files only: namespaced modules nest their sidecars in subdirectories, and a directory
    -- has no digest to take.
    if (← path.metadata).type == .file then
      let line ← metadataLine path
      lines := lines.push ((line.drop rootPrefix.length).toString)
  return "\n".intercalate lines.toList

/-- Two sorted metadata snapshots must agree line for line; the failure names the first file on
which they differ and both of its lines, so a CI log shows which of content, mtime, or mode
moved instead of two whole trees. -/
private def ensureTreeUnchanged (label : String) (before after : String) : IO Unit := do
  let beforeLines := (before.splitOn "\n").toArray
  let afterLines := (after.splitOn "\n").toArray
  for i in [:max beforeLines.size afterLines.size]do
    let beforeLine := beforeLines[i]?.getD "<absent>"
    let afterLine := afterLines[i]?.getD "<absent>"
    -- The follower lines indent so the runner's failure digest keeps them.
    ensure (beforeLine == afterLine) s!"{label}:\n  before: {beforeLine}\n  after:  {afterLine}"

/-- Run `action` and restore `target` from `backup` even when it fails — the per-section
`cp -p` restores of the old script, made exception-safe. -/
private def withRestored (backup target : System.FilePath) (action : IO Unit) : IO Unit := do
  try
    action
  finally
    cpPreserve backup target

private def field (json : Lean.Json) (name : String) : Lean.Json :=
  (json.getObjVal? name).toOption.getD .null

private def firstFile (report : Lean.Json) : Lean.Json :=
  ((field report "files").getArr?.toOption.getD #[])[0]?.getD .null

private def findingCodes (report : Lean.Json) : List String :=
  (((field (firstFile report) "findings").getArr?.toOption.getD #[]).toList.map fun finding =>
    (finding.getObjValAs? String "code").toOption.getD "")

private def statuses (report : Lean.Json) : List String :=
  (((field report "files").getArr?.toOption.getD #[]).toList.map fun file =>
    (file.getObjValAs? String "status").toOption.getD "")

private def paths (report : Lean.Json) : List String :=
  (((field report "files").getArr?.toOption.getD #[]).toList.map fun file =>
    (file.getObjValAs? String "path").toOption.getD "")

/-- Temp files orphaned beside a target: the `.lean-fmt-tmp-*` family the crash tests count. -/
private def tmpOrphans (dir : System.FilePath) (stem : String) : IO (Array String) := do
  return ((← dir.readDir).map (·.fileName)).filter (·.startsWith stem)

-- -----------------------------------------------------------------------------------------------
-- The committed `tests/fixtures/check` fixtures

/-- Every non-writing preview consumes the same result and leaves source bytes, mtimes, and
permissions untouched. -/
private def testPreviews (ctx : Ctx) : IO Unit := do
  let before ← metadataLine ctx.findings
  let check ← runJson ctx 1 "check" (checkArgs "tests/fixtures/check/Findings.lean")
  let formatted ←
    runJson ctx 1 "format --check" (formatCheckArgs "tests/fixtures/check/Findings.lean")
  let diff ← run ctx 1 "diff" (diffArgs "tests/fixtures/check/Findings.lean")
  ensureEq "a preview touched the source" before (← metadataLine ctx.findings)
  -- `check` reports the finding and its safe fix; it changes nothing on disk.
  ensureJsonAt check [.field "mode"] (Lean.toJson "check") "previews"
  ensureJsonAt check [.field "changed"] (Lean.toJson (1 : Nat)) "previews"
  ensureJsonAt check [.field "written"] (Lean.toJson (0 : Nat)) "previews"
  ensureEq "check findings" ["FMT003"] (findingCodes check)
  -- `format` applies no rule fix but does reflow; the finding remains at original coordinates.
  ensureJsonAt formatted [.field "mode"] (Lean.toJson "format") "previews"
  ensureJsonAt formatted [.field "changed"] (Lean.toJson (1 : Nat)) "previews"
  ensureJsonAt formatted [.field "files", .index 0, .field "status"] (Lean.toJson "would-format")
      "previews"
  ensure (((jsonAt? formatted [.field "files", .index 0, .field "formatted"]).getD .null) != .null)
      "format --check carried no formatted text"
  ensureEq "format findings" ["FMT003"] (findingCodes formatted)
  -- `diff` shows only layout; the FMT003 dedup remains withheld from the patch.
  ensure (diff.stdout.contains "@@") "the diff has no hunk"
  ensure
      (diff.stdout.endsWith
        "mode=diff files=1 findings=1 changed=1 written=0 broken=0 unbuilt=0 rejected=0 \
     withheld_unsafe=0 suppressed=0 infrastructure_failures=0\n")
      "the diff trailer"

/-- `format` formats — the pin on the layout-only fixture, with the exact canonical
bytes. The body breaks after `:=` at every width: `declValSimple` is a hard newline unless the
body is one of the three `ppAllowUngrouped` parsers, and a literal is none of them. -/
private def testLayoutFormat (ctx : Ctx) : IO Unit := do
  let report ← runJson ctx 1 "layout format" (formatCheckArgs "tests/fixtures/check/Layout.lean")
  ensureJsonAt report [.field "mode"] (Lean.toJson "format") "layout"
  ensureJsonAt report [.field "findings"] (Lean.toJson (0 : Nat)) "layout"
  ensureJsonAt report [.field "changed"] (Lean.toJson (1 : Nat)) "layout"
  ensureJsonAt report [.field "written"] (Lean.toJson (0 : Nat)) "layout"
  ensureJsonAt report [.field "files", .index 0, .field "status"] (Lean.toJson "would-format")
      "layout"
  ensureJsonAt report [.field "files", .index 0, .field "formatted"]
      (Lean.toJson "module\n\nnamespace Alpha\n\ndef layoutValue : Nat :=\n  1\n\nend Alpha\n")
      "layout"
  ensure ((← IO.FS.readFile ctx.layout).contains "namespace     Alpha")
      "fixture lost its non-canonical spacing; the check above proves nothing"
  -- Formatting is a canonical transformation, not a selectable rule: the same file `format`
  -- calls would-format is `check`-clean.
  let check ← runJson ctx 0 "layout check" (checkArgs "tests/fixtures/check/Layout.lean")
  ensureJsonAt check [.field "mode"] (Lean.toJson "check") "layout check"
  ensureJsonAt check [.field "findings"] (Lean.toJson (0 : Nat)) "layout check"
  ensureJsonAt check [.field "changed"] (Lean.toJson (0 : Nat)) "layout check"
  ensureJsonAt check [.field "files", .index 0, .field "status"] (Lean.toJson "clean")
      "layout check"

/-- A layout-dirty file without a final newline: the diff retains the missing-terminator marker
while showing the namespace edit. -/
private def testLayoutNoNewline (ctx : Ctx) : IO Unit := do
  withRestored ctx.backupLayout ctx.layout do
      writeFile ctx.layout
          "module\n\nnamespace     Alpha\n\ndef layoutValue : Nat := 1\n\nend     Alpha"
      let diff ← run ctx 1 "no-newline diff" (diffArgs "tests/fixtures/check/Layout.lean")
      ensure
          (diff.stdout.startsWith
            "--- a/tests/fixtures/check/Layout.lean\n+++ b/tests/fixtures/check/Layout.lean\n@@")
          "the no-newline diff header"
      ensure (diff.stdout.contains "\\ No newline at end of file") "the terminator marker"
      ensure
          (diff.stdout.contains "-namespace     Alpha" && diff.stdout.contains "+namespace Alpha")
          "the namespace edit"
      ensure (diff.stdout.contains "-end     Alpha" && diff.stdout.contains "+end Alpha")
          "the end edit"
      ensure
          (diff.stdout.endsWith
            "mode=diff files=1 findings=0 changed=1 written=0 broken=0 unbuilt=0 rejected=0 \
       withheld_unsafe=0 suppressed=0 infrastructure_failures=0\n")
          "the no-newline trailer"

/-- Artifact, exact fallback, and semantic-cache hit project to identical formatted output. -/
private def testCachePaths (ctx : Ctx) : IO Unit := do
  let artifact ←
    run ctx 1 "format artifact"
        #["format", "--check", "--root", ".", "--json", "tests/fixtures/check/Layout.lean"]
  let hit ←
    run ctx 1 "format hit"
        #["format", "--check", "--root", ".", "--json", "tests/fixtures/check/Layout.lean"] (env :=
        #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"),
          ("LEAN_FMT_TEST_ANALYZER", some "/usr/bin/false")])
  ensureEq "the cache hit disagreed with the artifact path" artifact.stdout hit.stdout
  let fallback ←
    run ctx 1 "format fallback" (formatCheckArgs "tests/fixtures/check/Layout.lean") (env :=
        #[("LEAN_FMT_DISABLE_ARTIFACT", some "1")])
  ensureEq "the exact fallback disagreed with the artifact path" artifact.stdout fallback.stdout
  removeDirAll? ctx.cacheRoot

/-- A `check`-populated entry is a miss for a rendering mode, not an under-populated hit: `check`
stores no canonical text, so serving its entry to `format` would silently base the patch on the
file's own bytes. -/
private def testCheckPopulatedMiss (ctx : Ctx) : IO Unit := do
  removeDirAll? ctx.cacheRoot
  let seed ←
    runJson ctx 0 "seed check"
        #["check", "--root", ".", "--json", "tests/fixtures/check/Layout.lean"]
  ensureJsonAt seed [.field "files", .index 0, .field "status"] (Lean.toJson "clean") "seed"
  let after ←
    runJson ctx 1 "format after check"
        #["format", "--check", "--root", ".", "--json", "tests/fixtures/check/Layout.lean"]
  ensureJsonAt after [.field "changed"] (Lean.toJson (1 : Nat))
      "a check-populated hit suppressed layout"
  ensureJsonAt after [.field "files", .index 0, .field "status"] (Lean.toJson "would-format")
      "after"
  ensureJsonAt after [.field "files", .index 0, .field "formatted"]
      (Lean.toJson "module\n\nnamespace Alpha\n\ndef layoutValue : Nat :=\n  1\n\nend Alpha\n")
      "after"
  removeDirAll? ctx.cacheRoot

/-- A per-file-ignores projection is part of the cache identity: the projected run is a hit. -/
private def testProjectedHit (ctx : Ctx) : IO Unit := do
  let report ←
    runJson ctx 0 "projected hit"
        (#["check", "--root", ".", "--json", "--config", (ctx.work / "per-file.toml").toString,
          "tests/fixtures/check/Findings.lean"])
        (env :=
        #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"),
          ("LEAN_FMT_TEST_ANALYZER", some "/usr/bin/false")])
  ensureJsonAt report [.field "findings"] (Lean.toJson (0 : Nat)) "projected"
  ensureJsonAt report [.field "changed"] (Lean.toJson (0 : Nat)) "projected"
  ensureJsonAt report [.field "files", .index 0, .field "status"] (Lean.toJson "clean") "projected"

/-- Applicability travels on the finding's fix: the one FMT003 is safe and carries its edit. -/
private def testApplicability (ctx : Ctx) : IO Unit := do
  let report ← runJson ctx 1 "applicability" (checkArgs "tests/fixtures/check/Findings.lean")
  ensureJsonAt report
      [.field "files", .index 0, .field "findings", .index 0, .field "fix", .field "applicability"]
      (Lean.toJson "safe") "applicability"
  let edits :=
    (jsonAt? report
          [.field "files", .index 0, .field "findings", .index 0, .field "fix",
            .field "edits"]).getD
      (.arr #[])
  ensure ((edits.getArr?.toOption.getD #[]).size > 0) "the fix carries no edits"
  ensure
      ((jsonAt? report
          [.field "files", .index 0, .field "findings", .index 0, .field "fix", .field "edits",
            .index 0, .field "range"]).isSome)
      "the edit carries no range"
  ensureJsonAt report [.field "withheldUnsafe"] (Lean.toJson (0 : Nat)) "applicability"

/-- `extend-unsafe-fixes` demotes FMT003 as a plan projection: the finding says `unsafe`, default
`fix` withholds it with no write, and `--unsafe-fixes` opts in and applies it. -/
private def testUnsafeDemotion (ctx : Ctx) : IO Unit := do
  let demote := (ctx.work / "demote.toml").toString
  let check ←
    runJson ctx 1 "demote check"
        (#["check", "--root", ".", "--json", "--no-cache", "--config", demote,
          "tests/fixtures/check/Findings.lean"])
  ensureJsonAt check
      [.field "files", .index 0, .field "findings", .index 0, .field "fix", .field "applicability"]
      (Lean.toJson "unsafe") "demote"
  ensureJsonAt check [.field "withheldUnsafe"] (Lean.toJson (1 : Nat)) "demote"
  let before ← metadataLine ctx.findings
  let withheld ←
    runJson ctx 0 "demote withhold"
        (#["fix", "--root", ".", "--json", "--no-cache", "--config", demote,
          "tests/fixtures/check/Findings.lean"])
  ensureEq "a withheld fix touched the source" before (← metadataLine ctx.findings)
  ensureJsonAt withheld [.field "written"] (Lean.toJson (0 : Nat)) "withhold"
  ensureJsonAt withheld [.field "withheldUnsafe"] (Lean.toJson (1 : Nat)) "withhold"
  ensureJsonAt withheld [.field "files", .index 0, .field "status"] (Lean.toJson "clean") "withhold"
  withRestored ctx.backupFindings ctx.findings do
      let applied ←
        runJson ctx 0 "demote apply"
            (#["fix", "--root", ".", "--json", "--no-cache", "--unsafe-fixes", "--config", demote,
              "tests/fixtures/check/Findings.lean"])
      ensureJsonAt applied [.field "written"] (Lean.toJson (1 : Nat)) "apply"
      ensureJsonAt applied [.field "withheldUnsafe"] (Lean.toJson (0 : Nat)) "apply"
      ensureJsonAt applied [.field "files", .index 0, .field "status"] (Lean.toJson "fixed") "apply"

/-- A rule in both extend lists is a config contradiction, rejected before any file is read. -/
private def testConfigContradiction (ctx : Ctx) : IO Unit := do
  let result ←
    run ctx 2 "both lists"
        (#["check", "--root", ".", "--json", "--no-cache", "--config",
          (ctx.work / "both-lists.toml").toString, "tests/fixtures/check/Findings.lean"])
  ensure (result.stderr.contains "both extend-safe-fixes and extend-unsafe-fixes")
      "the contradiction is not named"

/-- `include` scopes no-arg selection to exactly the listed file. -/
private def testIncludeConfig (ctx : Ctx) : IO Unit := do
  let report ←
    runJson ctx 0 "include"
        #["check", "--root", ".", "--json", "--no-cache", "--config",
          (ctx.work / "include.toml").toString]
  ensureEq "include selection" ["tests/fixtures/check/Clean.lean"] (paths report)

/-- Config `ignore` drops the finding; a CLI `--select` overrides the config selector. -/
private def testIgnoreAndCliSelect (ctx : Ctx) : IO Unit := do
  let ignore := (ctx.work / "ignore.toml").toString
  discard <|
      run ctx 0 "config ignore"
        #["check", "--root", ".", "--json", "--no-cache", "--config", ignore,
          "tests/fixtures/check/Findings.lean"]
  discard <|
      run ctx 1 "cli select"
        #["check", "--root", ".", "--json", "--no-cache", "--config", ignore, "--select", "FMT003",
          "tests/fixtures/check/Findings.lean"]

private def testUnknownKey (ctx : Ctx) : IO Unit := do
  let result ←
    run ctx 2 "unknown key"
        (#["check", "--root", ".", "--json", "--no-cache", "--config",
          (ctx.work / "unknown.toml").toString, "tests/fixtures/check/Clean.lean"])
  ensure (result.stderr.contains "unknown configuration key") "the unknown key is not named"

/-- Statistics are stderr-only: stdout stays machine-readable. -/
private def testStatistics (ctx : Ctx) : IO Unit := do
  let result ←
    run ctx 1 "statistics"
        #["check", "--root", ".", "--json", "--no-cache", "--statistics",
          "tests/fixtures/check/Findings.lean"]
  discard <| parseJson result.stdout "statistics stdout"
  ensure ((result.stderr.splitOn "\n").any (·.startsWith "lean-fmt statistics:"))
      "no statistics block on stderr"

/-- A semantic validation rejection rejects the whole file without a formatter write. -/
private def testValidatorRejection (ctx : Ctx) : IO Unit := do
  let before ← metadataLine ctx.findings
  let report ←
    runJson ctx 1 "rejected" (fixArgs "tests/fixtures/check/Findings.lean") (env :=
        #[("LEAN_FMT_TEST_VALIDATOR", some (ctx.work / "reject-validator").toString)])
  ensureEq "a rejected fix touched the source" before (← metadataLine ctx.findings)
  ensureJsonAt report [.field "rejected"] (Lean.toJson (1 : Nat)) "rejected"
  ensureJsonAt report [.field "written"] (Lean.toJson (0 : Nat)) "rejected"
  let diagnostics :=
    ((field (firstFile report) "diagnostics").getArr?.toOption.getD #[]) |>.toList.map
      (·.getStr?.toOption.getD "")
  ensure (diagnostics.any (·.contains "forced validation rejection"))
      "the rejection reason is not reported"

/-- A stale-source race rejects the whole file: `publishAtomic` catches the concurrent change. -/
private def testStaleSourceRace (ctx : Ctx) : IO Unit := do
  withRestored ctx.backupFindings ctx.findings do
      let result ←
        run ctx 1 "stale" (fixArgs "tests/fixtures/check/Findings.lean") (env :=
            #[("LEAN_FMT_TEST_BEFORE_WRITE", some (ctx.work / "stale-hook").toString)])
      ensure (result.stdout.contains "source changed after analysis")
          "the stale race is not reported"

/-- A crash between validation and the rename that commits the write: the target keeps its exact
bytes/mtime/mode, the run is an infrastructure failure, and no temp file is orphaned. -/
private def testWriteCrash (ctx : Ctx) : IO Unit := do
  let before ← metadataLine ctx.findings
  discard <|
      run ctx 2 "crash" (fixArgs "tests/fixtures/check/Findings.lean") (env :=
        #[("LEAN_FMT_TEST_BEFORE_WRITE", some (ctx.work / "crash-hook").toString)])
  ensureEq "a crashed write touched the source" before (← metadataLine ctx.findings)
  ensureEq "a crash before rename orphaned a temp file at the target" 0
      (← tmpOrphans (ctx.root / "tests" / "fixtures" / "check") "Findings.lean.lean-fmt-tmp-").size

/-- Successful fix preserves permissions, and a second fix is an unchanged no-op. -/
private def testFixPermissions (ctx : Ctx) : IO Unit := do
  withRestored ctx.backupFindings ctx.findings do
      let modeBefore ← fileMode ctx.findings
      let fixed ← runJson ctx 0 "fix" (fixArgs "tests/fixtures/check/Findings.lean")
      ensureEq "fix changed the file's permissions" modeBefore (← fileMode ctx.findings)
      let unchanged ← runJson ctx 0 "fix again" (fixArgs "tests/fixtures/check/Findings.lean")
      ensureJsonAt fixed [.field "written"] (Lean.toJson (1 : Nat)) "fix"
      ensureJsonAt fixed [.field "files", .index 0, .field "status"] (Lean.toJson "fixed") "fix"
      ensureJsonAt unchanged [.field "written"] (Lean.toJson (0 : Nat)) "fix again"
      ensureJsonAt unchanged [.field "files", .index 0, .field "status"] (Lean.toJson "clean")
          "fix again"

/-- The rule registry: the exact code order, plus each rule's fixability, category, default, and
input tier. -/
private def testRulesRegistry (ctx : Ctx) : IO Unit := do
  let rules ← parseJson (← run ctx 0 "rules" #["rules", "--json"]).stdout "rules"
  let all := (rules.getArr?.toOption.getD #[]).toList
  let codes := all.map fun rule => (rule.getObjValAs? String "code").toOption.getD ""
  ensureEq "the registry order"
      ["FMT001", "FMT002", "FMT006", "FMT007", "FMT008", "FMT009", "FMT010", "FMT011", "FMT012",
        "FMT013", "FMT014", "FMT015", "FMT003", "FMT004", "FMT005"]
      codes
  let byCode (code : String) : Lean.Json :=
    (all.find? fun rule => (rule.getObjValAs? String "code").toOption == some code).getD .null
  let flag (code key : String) : Bool := ((field (byCode code) key).getBool?).toOption.getD false
  let text (code key : String) : String := (field (byCode code) key).getStr?.toOption.getD ""
  -- The source-security rules are report-only and their own category.
  for code in ["FMT001", "FMT002"]do
    ensure (!(flag code "fixable") && text code "category" == "security") s!"{code} security"
  ensure (flag "FMT003" "fixable" && text "FMT003" "category" == "imports") "FMT003"
  for code in ["FMT004", "FMT005"]do
    ensure (!(flag code "fixable") && text code "category" == "imports") s!"{code} imports"
  -- FMT001/002 and FMT003-005 are the default-enabled, source-tier rules.
  for code in ["FMT001", "FMT002", "FMT003", "FMT004", "FMT005"]do
    ensure (flag code "defaultEnabled" && text code "input" == "source") s!"{code} source tier"
  -- FMT006-011 ship as preview: off by default, syntax tier, explicit --select only.
  for code in ["FMT006", "FMT007", "FMT008", "FMT009", "FMT010", "FMT011"]do
    ensure (!(flag code "defaultEnabled") && text code "input" == "syntax") s!"{code} preview"
  ensure (text "FMT006" "category" == "docs" && !(flag "FMT006" "fixable")) "FMT006"
  ensure (text "FMT007" "category" == "structure" && !(flag "FMT007" "fixable")) "FMT007"
  ensure (text "FMT010" "category" == "debug" && !(flag "FMT010" "fixable")) "FMT010"
  for code in ["FMT008", "FMT009", "FMT011"]do
    ensure (flag code "fixable" && text code "category" == "redundancy") s!"{code} redundancy"
  -- FMT012-015 are semantic-tier preview rules; only FMT012 carries a fix (unsafe).
  for code in ["FMT012", "FMT013", "FMT014", "FMT015"]do
    ensure (!(flag code "defaultEnabled") && text code "input" == "semantic") s!"{code} semantic"
  ensure (flag "FMT012" "fixable") "FMT012 fixable"
  for code in ["FMT013", "FMT014", "FMT015"]do
    ensure (!(flag code "fixable")) s!"{code} report-only"
  ensure (text "FMT012" "category" == "deprecation") "FMT012"
  ensure (text "FMT013" "category" == "unused" && text "FMT014" "category" == "unused") "FMT013/14"
  ensure (text "FMT015" "category" == "naming") "FMT015"

/-- Compiler setup is deterministic guidance, not a lakefile mutation. -/
private def testCompilerSetup (ctx : Ctx) : IO Unit := do
  let first ← run ctx 0 "setup 1" #["compiler", "setup", "--json"]
  let second ← run ctx 0 "setup 2" #["compiler", "setup", "--json"]
  ensureEq "compiler setup is not deterministic" first.stdout second.stdout
  let report ← parseJson first.stdout "setup"
  ensureJsonAt report [.field "schema"] (Lean.toJson "lean-fmt.compiler-setup.v1") "setup"
  ensureJsonAt report [.field "plugin"] (Lean.toJson "LeanFmtCompilerPlugin:shared") "setup"
  ensureJsonAt report [.field "facet"] (Lean.toJson "leanFmtArtifact") "setup"

/-- A downstream project really is plugin-integrated: its artifact holds reconstructible syntax
and nothing else, and `compiler status` earns a `ready` there. -/
private def testDownstream (ctx : Ctx) : IO Unit := do
  let downstream := ctx.work / "downstream"
  IO.FS.createDirAll downstream
  writeFile (downstream / "lakefile.lean")
      s!"import Lake\n\nopen Lake DSL\n\npackage Downstream\n\nrequire lean_fmt from \"{ctx.root}\"\n\n\
       lean_lib Downstream where\n  roots := #[`Downstream]\n  \
       plugins := #[`@lean_fmt/LeanFmtCompilerPlugin:shared]\n"
  writeFile (downstream / "lean-toolchain") "leanprover/lean4:v4.32.0\n"
  writeFile (downstream / "Downstream.lean") "module\n\ndef downstreamValue : Nat := 1  \n"
  let lakeEnv : Array (String × Option String) := #[("LEAN_NUM_THREADS", some "1")]
  discard <|
      expectExit 0 "lake update" "lake" #["update"] (cwd? := some downstream) (env := lakeEnv)
        (timeoutMs := some 1800000)
  discard <|
      expectExit 0 "lake build artifact" "lake" #["build", "+Downstream:leanFmtArtifact"] (cwd? :=
        some downstream) (env := lakeEnv) (timeoutMs := some 1800000)
  let artifact ←
    parseJson
        (←
          IO.FS.readFile
              (downstream / ".lake" / "build" / "lean-fmt-artifacts" / "Downstream.json"))
        "downstream artifact"
  ensureJsonAt artifact [.field "mainModule"] (Lean.toJson "Downstream") "downstream artifact"
  ensure ((artifact.getObjVal? "findings").toOption.isNone)
      "the artifact carries findings -- verdicts leaked into the integrator's build graph"
  let entries :=
    (((jsonAt? artifact [.field "syntaxData", .field "entries"]).getD
            (.arr #[])) |>.getArr?.toOption).getD
      #[]
  ensure (entries.size > 0) "the downstream projection recorded no syntax entries"
  let status ←
    runJson ctx 0 "status downstream"
        #["compiler", "status", "--root", downstream.toString, "--json"]
  let ready := ((field status "ready").getNum?.toOption.getD 0).mantissa.toNat
  ensure (ready >= 1) "no module is ready in the integrated project"
  let moduleStatuses :=
    (((field status "modules").getArr?.toOption.getD #[]).toList.map fun m =>
      (m.getObjValAs? String "status").toOption.getD "")
  ensureEq "downstream statuses" ["ready"] moduleStatuses

/-- `compiler status` at the repository root is deterministic and read-only over current module
artifacts. -/
private def testCompilerStatus (ctx : Ctx) : IO Unit := do
  let before ← treeMetadata ctx.artifacts
  let first ← run ctx 0 "status 1" #["compiler", "status", "--root", ".", "--json"]
  let second ← run ctx 0 "status 2" #["compiler", "status", "--root", ".", "--json"]
  ensureEq "compiler status is not deterministic" first.stdout second.stdout
  ensureTreeUnchanged "compiler status touched the artifact tree" before
      (← treeMetadata ctx.artifacts)
  let report ← parseJson first.stdout "status"
  let modulePaths :=
    (((field report "modules").getArr?.toOption.getD #[]).toList.map fun m =>
      (m.getObjValAs? String "path").toOption.getD "")
  ensureEq "module paths are not sorted" (modulePaths.mergeSort (· < ·)) modulePaths
  let count (key : String) : Nat := ((field report key).getNum?.toOption.getD 0).mantissa.toNat
  -- Every module lands in exactly one bucket. Not `ready >= 2`: this repository's own modules
  -- are not built with the plugin, so the earned `ready` is asserted against the downstream
  -- project instead.
  ensureEq "buckets do not cover the modules" modulePaths.length
      (count "ready" + count "missing" + count "unbuilt")
  let moduleStatuses :=
    (((field report "modules").getArr?.toOption.getD #[]).toList.map fun m =>
      (m.getObjValAs? String "status").toOption.getD "")
  ensure (moduleStatuses.all (· ∈ ["ready", "missing", "unbuilt"])) "an unknown status bucket"

/-- The repository dogfoods the organizer: the committed tree is always `organize --check`
clean, so header drift — a misplaced `import all`, an unsorted row, a bucket on the wrong side
of a blank line — fails CI the day it lands rather than surfacing in someone's next `organize`. -/
private def testOrganizeSelf (ctx : Ctx) : IO Unit := do
  let report ←
    runJson ctx 0 "organize self" #["organize", "--check", "--root", ".", "--json", "--no-cache"]
  ensureJsonAt report [.field "changed"] (Lean.toJson (0 : Nat)) "the tree is not organize-clean"

/-- The repository dogfoods the formatter: the committed tree is always `format --check` clean,
so layout drift — and every formatter defect that would refuse one of this repository's own
files — fails CI the day it lands. The validator refusing a file is the loudest bug report the
formatter has: nine of these files were unformattable until the offside pins learned to yield. -/
private def testFormatSelf (ctx : Ctx) : IO Unit := do
  let report ←
    runJson ctx 0 "format self" #["format", "--check", "--root", ".", "--json", "--no-cache"]
  ensureJsonAt report [.field "changed"] (Lean.toJson (0 : Nat)) "the tree is not format-clean"
  let failures := ((field report "infrastructureFailures").getArr?.toOption.getD #[]).size
  ensureEq "the formatter refused one of this repository's own files" 0 failures

/-- Clean removes exactly the project result cache, is idempotent, and leaves source and build
artifacts. -/
private def testClean (ctx : Ctx) : IO Unit := do
  let before ← metadataLine ctx.findings
  IO.FS.createDirAll ctx.cacheRoot
  writeFile (ctx.cacheRoot / "sentinel") "cache\n"
  let sentinel := ctx.root / ".lake" / "build" / "lean-fmt-clean-sentinel"
  writeFile sentinel "build\n"
  let first ← runJson ctx 0 "clean 1" #["clean", "--root", ".", "--json"]
  ensure (!(← ctx.cacheRoot.pathExists)) "clean left the cache behind"
  ensure (← sentinel.pathExists) "clean removed a build artifact"
  let second ← runJson ctx 0 "clean 2" #["clean", "--root", ".", "--json"]
  ensureJsonAt first [.field "removed"] (Lean.toJson true) "clean 1"
  ensureJsonAt second [.field "removed"] (Lean.toJson false) "clean 2"
  discard <| (removeFile? sentinel : IO Unit)
  let after ← metadataLine ctx.findings
  ensure (before == after) s!"clean touched the source:\n  before: {before}\n  after:  {after}"

-- -----------------------------------------------------------------------------------------------
-- Layout and fix are decoupled

/-- On a fixture with both a layout defect and an admitted fix, `format` reflows and leaves the
finding while `fix` applies the finding at original coordinates and does not reflow. -/
private def testRdfImplMixed (ctx : Ctx) : IO Unit := do
  let fixture := ctx.mode ".rdf-impl-mixed.lean"
  writeFile fixture
      "module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n\nnamespace     Alpha\n\n\
     def mixedValue : Nat := 1\n\nend Alpha\n"
  let formatted ← runJson ctx 1 "mixed format" (formatCheckArgs "tests/modes/.rdf-impl-mixed.lean")
  ensureJsonAt formatted [.field "mode"] (Lean.toJson "format") "mixed format"
  ensureJsonAt formatted [.field "changed"] (Lean.toJson (1 : Nat)) "mixed format"
  ensureJsonAt formatted [.field "files", .index 0, .field "status"] (Lean.toJson "would-format")
      "mixed format"
  ensureEq "mixed format findings" ["FMT003"] (findingCodes formatted)
  ensureJsonAt formatted [.field "files", .index 0, .field "formatted"]
      (Lean.toJson
        "module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n\nnamespace Alpha\n\n\
      def mixedValue : Nat :=\n  1\n\nend Alpha\n")
      "mixed format"
  let diff ← run ctx 1 "mixed diff" (diffArgs "tests/modes/.rdf-impl-mixed.lean")
  ensure (diff.stdout.contains "-namespace     Alpha" && diff.stdout.contains "+namespace Alpha")
      "the mixed diff hunk"
  -- The only hunk collapses the namespace spacing; no import line is removed.
  ensure (!((diff.stdout.replace " import" "").contains "import LeanFmt.Basic"))
      "the mixed diff edits an import"
  ensure
      (((diff.stdout.trimAsciiEnd).toString.endsWith
        "findings=1 changed=1 written=0 broken=0 unbuilt=0 rejected=0 withheld_unsafe=0 suppressed=0 \
     infrastructure_failures=0"))
      "the mixed diff trailer"
  let fixed ← runJson ctx 0 "mixed fix" (fixArgs "tests/modes/.rdf-impl-mixed.lean")
  ensureJsonAt fixed [.field "written"] (Lean.toJson (1 : Nat)) "mixed fix"
  ensureJsonAt fixed [.field "files", .index 0, .field "status"] (Lean.toJson "fixed") "mixed fix"
  ensureEq "fix reflowed layout"
      "module\n\nimport LeanFmt.Basic\n\nnamespace     Alpha\n\ndef mixedValue : Nat := 1\n\nend Alpha\n"
      (String.fromUTF8! (← IO.FS.readBinFile fixture))
  let recheck ← runJson ctx 0 "mixed recheck" (checkArgs "tests/modes/.rdf-impl-mixed.lean")
  ensureJsonAt recheck [.field "files", .index 0, .field "status"] (Lean.toJson "clean") "recheck"
  ensureEq "recheck findings" ([] : List String) (findingCodes recheck)
  let afterFix ← runJson ctx 1 "postfix format" (formatCheckArgs "tests/modes/.rdf-impl-mixed.lean")
  ensureJsonAt afterFix [.field "files", .index 0, .field "status"] (Lean.toJson "would-format")
      "postfix"
  ensureEq "postfix findings" ([] : List String) (findingCodes afterFix)
  ensureJsonAt afterFix [.field "files", .index 0, .field "formatted"]
      (Lean.toJson
        "module\n\nimport LeanFmt.Basic\n\nnamespace Alpha\n\ndef mixedValue : Nat :=\n  1\n\n\
      end Alpha\n")
      "postfix"

/-- Canonical reflow owns inter-token trailing whitespace while preserving token content,
verbatim tails, and final-newline presence. Three persistent regressions pin that boundary. -/
private def testRdfLayout (ctx : Ctx) : IO Unit := do
  -- 1. No rule selected: pure layout, so `format` carries no findings and `check` is clean.
  let nosel := ctx.mode ".rdf-layout-nosel.lean"
  writeFile nosel "module\n\ndef alpha : Nat := 1   \n\ndef beta : Nat := 2   "
  let noselFormat ←
    runJson ctx 1 "nosel format" (formatCheckArgs "tests/modes/.rdf-layout-nosel.lean")
  ensureJsonAt noselFormat [.field "mode"] (Lean.toJson "format") "nosel"
  ensureJsonAt noselFormat [.field "changed"] (Lean.toJson (1 : Nat)) "nosel"
  ensureJsonAt noselFormat [.field "findings"] (Lean.toJson (0 : Nat)) "nosel"
  ensureJsonAt noselFormat [.field "files", .index 0, .field "status"] (Lean.toJson "would-format")
      "nosel"
  ensureEq "nosel findings" ([] : List String) (findingCodes noselFormat)
  ensureJsonAt noselFormat [.field "files", .index 0, .field "formatted"]
      (Lean.toJson "module\n\ndef alpha : Nat :=\n  1\n\ndef beta : Nat :=\n  2") "nosel"
  let noselCheck ← runJson ctx 0 "nosel check" (checkArgs "tests/modes/.rdf-layout-nosel.lean")
  ensureJsonAt noselCheck [.field "changed"] (Lean.toJson (0 : Nat)) "nosel check"
  ensureJsonAt noselCheck [.field "files", .index 0, .field "status"] (Lean.toJson "clean")
      "nosel check"
  -- 2. In-string trailing whitespace is token content, not inter-token trivia.
  let stringFixture := ctx.mode ".rdf-layout-string.lean"
  writeFile stringFixture "module\n\ndef stringWsValue : String := \"alpha   \n  beta\""
  let stringFormat ←
    runJson ctx 1 "string format" (formatCheckArgs "tests/modes/.rdf-layout-string.lean")
  ensureJsonAt stringFormat [.field "files", .index 0, .field "status"] (Lean.toJson "would-format")
      "string"
  ensureEq "string findings" ([] : List String) (findingCodes stringFormat)
  ensureJsonAt stringFormat [.field "files", .index 0, .field "formatted"]
      (Lean.toJson "module\n\ndef stringWsValue : String :=\n  \"alpha   \n  beta\"") "string"
  ensureJsonAt stringFormat [.field "infrastructureFailures"] (.arr #[]) "string"
  let stringFix ← runJson ctx 0 "string fix" (fixArgs "tests/modes/.rdf-layout-string.lean")
  ensureJsonAt stringFix [.field "written"] (Lean.toJson (0 : Nat)) "string fix"
  ensureJsonAt stringFix [.field "files", .index 0, .field "status"] (Lean.toJson "clean")
      "string fix"
  ensureEq "fix touched the string fixture"
      "module\n\ndef stringWsValue : String := \"alpha   \n  beta\""
      (String.fromUTF8! (← IO.FS.readBinFile stringFixture))
  -- 3. A verbatim tail after a terminal `#exit` is emitted byte-for-byte.
  let tail := ctx.mode ".rdf-layout-tail.lean"
  writeFile tail "module\n\ndef  x :Nat:=1\n#exit\ntrailing garbage   "
  let tailFormat ← runJson ctx 1 "tail format" (formatCheckArgs "tests/modes/.rdf-layout-tail.lean")
  ensureJsonAt tailFormat [.field "files", .index 0, .field "formatted"]
      (Lean.toJson "module\n\ndef x : Nat :=\n  1\n#exit\ntrailing garbage   ") "tail"

/-- Composition confluence: `fix` and `format` touch disjoint concerns, so composing them in
either order reaches the same fixed point on disk, and the converged file is a fixed point of
both. -/
private def testCompositionConfluence (ctx : Ctx) : IO Unit := do
  let canonical :=
    "module\n\nimport LeanFmt.Basic\n\nnamespace Alpha\n\ndef mixedValue : Nat :=\n  1\n\
    \nend Alpha\n"
  let source :=
    "module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n\nnamespace     Alpha\n\n\
    def mixedValue : Nat := 1\n\nend Alpha\n"
  let compA := ctx.mode ".rdf-final-comp-a.lean"
  let compB := ctx.mode ".rdf-final-comp-b.lean"
  -- Order A — `fix` then `format`.
  writeFile compA source
  discard <|
      run ctx 0 "comp A fix"
        #["fix", "--root", ".", "--no-cache", "tests/modes/.rdf-final-comp-a.lean"]
  let formatA ←
    runJson ctx 0 "comp A format"
        #["format", "--root", ".", "--json", "--no-cache", "tests/modes/.rdf-final-comp-a.lean"]
  ensureJsonAt formatA [.field "files", .index 0, .field "status"] (Lean.toJson "formatted")
      "order A format did not write"
  ensureJsonAt formatA [.field "files", .index 0, .field "written"] (Lean.toJson true)
      "order A format did not write"
  -- Order B — `format` then `fix`.
  writeFile compB source
  let formatB ←
    runJson ctx 0 "comp B format"
        #["format", "--root", ".", "--json", "--no-cache", "tests/modes/.rdf-final-comp-b.lean"]
  ensureJsonAt formatB [.field "files", .index 0, .field "status"] (Lean.toJson "formatted")
      "order B format did not write"
  ensureJsonAt formatB [.field "files", .index 0, .field "written"] (Lean.toJson true)
      "order B format did not write"
  discard <|
      run ctx 0 "comp B fix"
        #["fix", "--root", ".", "--no-cache", "tests/modes/.rdf-final-comp-b.lean"]
  -- Both orders converge to the identical canonical bytes on disk.
  ensureEq "order A (fix;format) diverged" canonical (← IO.FS.readFile compA)
  ensureEq "order B (format;fix) diverged" canonical (← IO.FS.readFile compB)
  let formatB2 ←
    runJson ctx 0 "comp B format again"
        #["format", "--root", ".", "--json", "--no-cache", "tests/modes/.rdf-final-comp-b.lean"]
  ensureJsonAt formatB2 [.field "files", .index 0, .field "status"] (Lean.toJson "clean")
      "order B not a format fixed point"
  ensureJsonAt formatB2 [.field "files", .index 0, .field "written"] (Lean.toJson false)
      "order B not a format fixed point"
  ensureJsonAt formatB2 [.field "files", .index 0, .field "formatted"] .null
      "order B not a format fixed point"
  for (file, label) in
    [("tests/modes/.rdf-final-comp-a.lean", "comp A check"),
      ("tests/modes/.rdf-final-comp-b.lean", "comp B check")]do
    let check ← runJson ctx 0 label (checkArgs file)
    ensureJsonAt check [.field "files", .index 0, .field "status"] (Lean.toJson "clean") label
    ensureEq label ([] : List String) (findingCodes check)

-- -----------------------------------------------------------------------------------------------
-- FIP-FINAL: adversarial acceptance of the in-place default

private def exactSource : String :=
  "module\n\nnamespace     Gamma\n\ndef exactValue : Nat := 1\n\nend Gamma\n"

private def exactCanonical : String :=
  "module\n\nnamespace Gamma\n\ndef exactValue : Nat :=\n  1\n\nend Gamma\n"

/-- `format` writes exactly the canonical bytes and only those, and it is idempotent. -/
private def testFipExactWrite (ctx : Ctx) : IO Unit := do
  let fixture := ctx.mode ".fip-final-exact.lean"
  writeFile fixture exactSource
  let first ←
    runJson ctx 0 "fin exact"
        #["format", "--root", ".", "--json", "--no-cache", "tests/modes/.fip-final-exact.lean"]
  ensureJsonAt first [.field "files", .index 0, .field "status"] (Lean.toJson "formatted")
      "fin exact"
  ensureJsonAt first [.field "files", .index 0, .field "written"] (Lean.toJson true) "fin exact"
  ensureJsonAt first [.field "written"] (Lean.toJson (1 : Nat)) "fin exact"
  ensureEq "a rule fix appeared on a format write" ([] : List String) (findingCodes first)
  ensureEq "format wrote non-canonical bytes" exactCanonical (← IO.FS.readFile fixture)
  let second ←
    runJson ctx 0 "fin exact again"
        #["format", "--root", ".", "--json", "--no-cache", "tests/modes/.fip-final-exact.lean"]
  ensureJsonAt second [.field "files", .index 0, .field "status"] (Lean.toJson "clean")
      "format is not idempotent"
  ensureJsonAt second [.field "files", .index 0, .field "written"] (Lean.toJson false)
      "format is not idempotent"
  ensureEq "a second format changed bytes" exactCanonical (← IO.FS.readFile fixture)

/-- `--check` never writes; a broken file is never written and orphans no temp; CRLF and
in-string bytes round-trip on write. -/
private def testFipWriteRefusals (ctx : Ctx) : IO Unit := do
  let fixture := ctx.mode ".fip-final-exact.lean"
  writeFile fixture exactSource
  let before ← metadataLine fixture
  let check ← runJson ctx 1 "fin check" (formatCheckArgs "tests/modes/.fip-final-exact.lean")
  ensureEq "--check wrote" before (← metadataLine fixture)
  ensureJsonAt check [.field "files", .index 0, .field "status"] (Lean.toJson "would-format")
      "fin check"
  ensureJsonAt check [.field "files", .index 0, .field "written"] (Lean.toJson false) "fin check"
  discard <|
      run ctx 0 "fin check write"
        #["format", "--root", ".", "--json", "--no-cache", "tests/modes/.fip-final-exact.lean"]
  let clean ← runJson ctx 0 "fin check clean" (formatCheckArgs "tests/modes/.fip-final-exact.lean")
  ensureJsonAt clean [.field "files", .index 0, .field "status"] (Lean.toJson "clean")
      "--check on a clean file must be clean/exit 0"
  -- A broken file is never written and orphans no temp.
  let broken := ctx.mode ".fip-final-broken.lean"
  writeFile broken "module\n\ndef bad : Nat := true\n"
  let brokenBefore ← metadataLine broken
  let brokenReport ←
    runJson ctx 1 "fin broken"
        #["format", "--root", ".", "--json", "--no-cache", "tests/modes/.fip-final-broken.lean"]
  ensureEq "a broken file was written" brokenBefore (← metadataLine broken)
  ensureJsonAt brokenReport [.field "files", .index 0, .field "status"] (Lean.toJson "broken")
      "fin broken"
  ensureJsonAt brokenReport [.field "broken"] (Lean.toJson (1 : Nat)) "fin broken"
  ensureJsonAt brokenReport [.field "written"] (Lean.toJson (0 : Nat)) "fin broken"
  ensureEq "a broken format orphaned a temp file at the target" 0
      (← tmpOrphans ctx.modesDir ".fip-final-broken.lean.lean-fmt-tmp-").size
  -- CRLF write round-trip: no bare LF appears, and the layout is canonical.
  let crlf := ctx.mode ".fip-final-crlf.lean"
  writeFile crlf
      "module\r\n\r\nnamespace     Delta\r\n\r\ndef crlfValue : Nat := 1\r\n\r\nend Delta\r\n"
  discard <|
      run ctx 0 "fin crlf"
        #["format", "--root", ".", "--json", "--no-cache", "tests/modes/.fip-final-crlf.lean"]
  let data ← IO.FS.readFile crlf
  ensure (data.contains "\r\n") "format stripped CRLF line endings on write"
  ensure (!((data.replace "\r\n" "").contains "\n")) "format left a bare LF in a CRLF file"
  ensure (data.contains "namespace Delta\r\n" && !data.contains "namespace     Delta")
      "layout not canonicalized on a CRLF write"
  -- In-string trailing whitespace safety: the literal token bytes are preserved exactly.
  let stringFixture := ctx.mode ".fip-final-string.lean"
  writeFile stringFixture "module\n\ndef stringVal : String := \"alpha   \n  beta\""
  let stringReport ←
    runJson ctx 0 "fin string"
        #["format", "--root", ".", "--json", "--no-cache", "tests/modes/.fip-final-string.lean"]
  ensureJsonAt stringReport [.field "files", .index 0, .field "status"] (Lean.toJson "formatted")
      "fin string"
  ensureJsonAt stringReport [.field "files", .index 0, .field "written"] (Lean.toJson true)
      "fin string"
  ensureEq "the string interior moved" "module\n\ndef stringVal : String :=\n  \"alpha   \n  beta\""
      (String.fromUTF8! (← IO.FS.readBinFile stringFixture))

/-- The stale-source guard holds for format's write as for fix's, and no-arg selection writes
exactly the included set. -/
private def testFipStaleAndSelection (ctx : Ctx) : IO Unit := do
  let stale := ctx.mode ".fip-final-stale.lean"
  writeFile stale "module\n\nnamespace     Epsilon\n\ndef staleValue : Nat := 1\n\nend Epsilon\n"
  let staleResult ←
    run ctx 1 "fin stale"
        #["format", "--root", ".", "--json", "--no-cache", "tests/modes/.fip-final-stale.lean"]
        (env := #[("LEAN_FMT_TEST_BEFORE_WRITE", some (ctx.work / "fin-stale-hook").toString)])
  ensure (staleResult.stdout.contains "source changed after analysis")
      "the format stale race is not reported"
  let staleReport ← parseJson staleResult.stdout "fin stale"
  ensureJsonAt staleReport [.field "rejected"] (Lean.toJson (1 : Nat)) "fin stale"
  ensureJsonAt staleReport [.field "written"] (Lean.toJson (0 : Nat)) "fin stale"
  -- No-arg project-wide write over the included set only.
  let incl := ctx.mode ".fip-final-incl.lean"
  let excl := ctx.mode ".fip-final-excl.lean"
  writeFile incl "module\n\nnamespace     Incl\n\ndef inclValue : Nat := 1\n\nend Incl\n"
  writeFile excl "module\n\nnamespace     Excl\n\ndef exclValue : Nat := 1\n\nend Excl\n"
  let exclBefore ← metadataLine excl
  let report ←
    runJson ctx 0 "fin noarg"
        #["format", "--root", ".", "--json", "--no-cache", "--config",
          (ctx.work / "fin-noarg.toml").toString]
  ensureEq "no-arg selection is not the included set" ["tests/modes/.fip-final-incl.lean"]
      (paths report)
  ensureJsonAt report [.field "files", .index 0, .field "status"] (Lean.toJson "formatted")
      "fin noarg"
  ensureJsonAt report [.field "files", .index 0, .field "written"] (Lean.toJson true) "fin noarg"
  ensureEq "the included file's bytes"
      "module\n\nnamespace Incl\n\ndef inclValue : Nat :=\n  1\n\nend Incl\n"
      (← IO.FS.readFile incl)
  ensureEq "the excluded sibling was touched" exclBefore (← metadataLine excl)

/-- `check` and `diff` still never write. -/
private def testFipPreviewsNeverWrite (ctx : Ctx) : IO Unit := do
  let fixture := ctx.mode ".fip-final-exact.lean"
  writeFile fixture "module\n\nnamespace     Zeta\n\ndef neverValue : Nat := 1\n\nend Zeta\n"
  let before ← metadataLine fixture
  discard <| run ctx 0 "fin nw check" (checkArgs "tests/modes/.fip-final-exact.lean")
  discard <| run ctx 1 "fin nw diff" (diffArgs "tests/modes/.fip-final-exact.lean")
  ensureEq "check or diff wrote" before (← metadataLine fixture)

-- -----------------------------------------------------------------------------------------------
-- The selection gates

/-- Gate 1: a path inside `.lake` is refused by every mode under every configuration. The floor
is absolute, so each setting is asserted separately rather than once with the default. -/
private def testRcdFloor (ctx : Ctx) : IO Unit := do
  let floor := ctx.root / ".lake" / "build" / ".rcd-impl-floor.lean"
  writeFile floor "module\n\nnamespace     Floor\n\ndef floorValue : Nat := 1\n\nend Floor\n"
  let before ← metadataLine floor
  for mode in ["format", "fix"]do
    let plain ←
      run ctx 2 s!"floor {mode}"
          #[mode, "--root", ".", "--no-cache", ".lake/build/.rcd-impl-floor.lean"]
    ensure (plain.stderr.contains "inside the Lake build directory") "the floor is not named"
    for setting in ["on", "off"]do
      let configured ←
        run ctx 2 s!"floor {mode} {setting}"
            #[mode, "--root", ".", "--no-cache", "--config",
              (ctx.work / s!"rcd-force-{setting}.toml").toString,
              ".lake/build/.rcd-impl-floor.lean"]
      ensure (configured.stderr.contains "inside the Lake build directory")
          "the floor is not named under configuration"
  ensureEq "something inside .lake was written" before (← metadataLine floor)
  let shown ←
    runJson ctx 0 "floor show"
        #["config", "show", ".lake/build/.rcd-impl-floor.lean", "--root", ".", "--json"]
  ensureJsonAt shown [.field "selected"] (Lean.toJson false) "floor show"
  ensureJsonAt shown [.field "gate"] (Lean.toJson (1 : Nat)) "floor show"

/-- Gates 2-4 and `force-exclude`: an explicit path bypasses configured exclusion by default,
and `force-exclude = true` makes exclusion apply to explicit paths too. -/
private def testRcdExplicitExclusion (ctx : Ctx) : IO Unit := do
  let fixture := ctx.mode ".rcd-impl-excluded.lean"
  writeFile fixture
      "module\n\nnamespace     Excluded\n\ndef excludedValue : Nat := 1\n\nend Excluded\n"
  let before ← metadataLine fixture
  let forced ←
    runJson ctx 0 "forced exclusion"
        #["format", "--root", ".", "--json", "--no-cache", "--config",
          (ctx.work / "rcd-excl-forced.toml").toString, "tests/modes/.rcd-impl-excluded.lean"]
  ensureJsonAt forced [.field "files"] (.arr #[])
      "force-exclude did not remove an explicitly named excluded path"
  ensureJsonAt forced [.field "written"] (Lean.toJson (0 : Nat)) "forced exclusion"
  ensureEq "force-exclude withheld the write" before (← metadataLine fixture)
  let plain ←
    runJson ctx 0 "plain exclusion"
        #["format", "--root", ".", "--json", "--no-cache", "--config",
          (ctx.work / "rcd-excl.toml").toString, "tests/modes/.rcd-impl-excluded.lean"]
  ensureJsonAt plain [.field "files", .index 0, .field "status"] (Lean.toJson "formatted")
      "an explicit path was not written without force-exclude"
  ensureJsonAt plain [.field "files", .index 0, .field "written"] (Lean.toJson true)
      "an explicit path was not written without force-exclude"
  ensureEq "the explicit path's bytes"
      "module\n\nnamespace Excluded\n\ndef excludedValue : Nat :=\n  1\n\nend Excluded\n"
      (← IO.FS.readFile fixture)

/-- `[format] line-width` participates in the result-cache identity and `[lint]` does not,
asserted behaviorally with the cache on: a width-100 entry served to a width-20 run would
return the wrong canonical bytes. -/
private def testWidthCacheIdentity (ctx : Ctx) : IO Unit := do
  removeDirAll? ctx.cacheRoot
  let fixture := ctx.mode ".rcd-impl-excluded.lean"
  writeFile fixture
      "module\n\nnamespace     Width\n\n\
     def widthValue : Nat := 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10\n\nend Width\n"
  let wide ←
    run ctx 1 "width 100"
        #["format", "--check", "--root", ".", "--json", "--config",
          (ctx.work / "rcd-w100.toml").toString, "tests/modes/.rcd-impl-excluded.lean"]
  let wideAgain ←
    run ctx 1 "width 100 again"
        #["format", "--check", "--root", ".", "--json", "--config",
          (ctx.work / "rcd-w100.toml").toString, "tests/modes/.rcd-impl-excluded.lean"]
  ensureEq "a warm identical run is not byte-identical" wide.stdout wideAgain.stdout
  let wideLint ←
    runJson ctx 1 "width 100 lint"
        #["format", "--check", "--root", ".", "--json", "--config",
          (ctx.work / "rcd-w100-lint.toml").toString, "tests/modes/.rcd-impl-excluded.lean"]
  let wideReport ← parseJson wide.stdout "width 100"
  ensureEq "[lint] changed the cache identity" (statuses wideReport) (statuses wideLint)
  let narrow ←
    runJson ctx 1 "width 20"
        #["format", "--check", "--root", ".", "--json", "--config",
          (ctx.work / "rcd-w20.toml").toString, "tests/modes/.rcd-impl-excluded.lean"]
  ensureEq "width 100 status" ["would-format"] (statuses wideReport)
  ensureEq "a width-100 cache entry was served to a width-20 run" ["would-format"] (statuses narrow)
  ensure
      (((jsonAt? wideReport [.field "files", .index 0, .field "formatted"]).getD .null) !=
        ((jsonAt? narrow [.field "files", .index 0, .field "formatted"]).getD .null))
      "line-width did not change admitted canonical bytes"
  removeDirAll? ctx.cacheRoot

/-- `config show` is read-only and deterministic, and the provenance names the file and line a
setting actually came from. -/
private def testConfigShow (ctx : Ctx) : IO Unit := do
  let fixture := ctx.mode ".rcd-impl-excluded.lean"
  let before ← metadataLine fixture
  let first ←
    run ctx 0 "show 1"
        #["config", "show", "tests/modes/.rcd-impl-excluded.lean", "--root", ".", "--json",
          "--config", (ctx.work / "rcd-w20.toml").toString]
  let second ←
    run ctx 0 "show 2"
        #["config", "show", "tests/modes/.rcd-impl-excluded.lean", "--root", ".", "--json",
          "--config", (ctx.work / "rcd-w20.toml").toString]
  ensureEq "config show is not deterministic" first.stdout second.stdout
  ensureEq "introspection wrote" before (← metadataLine fixture)
  let report ← parseJson first.stdout "show"
  let settings := (field report "settings").getArr?.toOption.getD #[]
  let setting (key : String) : Lean.Json :=
    (settings.toList.find? fun entry => (entry.getObjValAs? String "key").toOption == some key).getD
      .null
  ensureJsonAt (setting "format.line-width") [.field "value"] (Lean.toJson "20") "show width"
  let origin := (field (setting "format.line-width") "origin").getStr?.toOption.getD ""
  ensure (origin.endsWith "rcd-w20.toml:2") s!"the width provenance: {origin}"
  ensureJsonAt (setting "include") [.field "origin"] (Lean.toJson "default") "show include"
  ensureJsonAt report [.field "selected"] (Lean.toJson true) "show selected"
  ensureJsonAt report [.field "gate"] (Lean.toJson (0 : Nat)) "show gate"

end Modes

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  withTempDir fun work => do
      let ctx : Modes.Ctx :=
        { root
          app := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
          work
          findings := root / "tests" / "fixtures" / "check" / "Findings.lean"
          layout := root / "tests" / "fixtures" / "check" / "Layout.lean"
          modesDir := root / "tests" / "modes"
          cacheRoot := root / ".lean-fmt-cache"
          artifacts := root / ".lake" / "build" / "lean-fmt-artifacts"
          backupFindings := work / "backup" / "Findings.lean"
          backupLayout := work / "backup" / "Layout.lean" }
      IO.FS.createDirAll (work / "backup")
      -- Tracked-fixture backups before anything runs, like the old script's `cp -p` prologue.
      discard <|
          expectExit 0 "backup" "cp" #["-p", ctx.findings.toString, ctx.backupFindings.toString]
      discard <| expectExit 0 "backup" "cp" #["-p", ctx.layout.toString, ctx.backupLayout.toString]
      -- The shared configurations and hooks, written once; individual cases pick among them.
      writeFile (work / "per-file.toml")
          "select = [\"default\"]\n[per-file-ignores]\n\"tests/fixtures/check/Findings.lean\" = [\"FMT003\"]\n"
      writeFile (work / "demote.toml")
          "select = [\"default\"]\nextend-unsafe-fixes = [\"FMT003\"]\n"
      writeFile (work / "both-lists.toml")
          "extend-safe-fixes = [\"FMT003\"]\nextend-unsafe-fixes = [\"FMT003\"]\n"
      writeFile (work / "include.toml")
          "include = [\"tests/fixtures/check/Clean.lean\"]\nselect = [\"default\"]\n"
      writeFile (work / "ignore.toml") "select = [\"default\"]\nignore = [\"FMT003\"]\n"
      writeFile (work / "unknown.toml") "unknown = true\n"
      writeFile (work / "fin-noarg.toml")
          "select = [\"default\"]\ninclude = [\"tests/modes/.fip-final-incl.lean\"]\n"
      writeFile (work / "rcd-force-on.toml") "force-exclude = true\n"
      writeFile (work / "rcd-force-off.toml") "force-exclude = false\n"
      writeFile (work / "rcd-excl.toml") "exclude = [\"tests/modes/.rcd-impl-excluded.lean\"]\n"
      writeFile (work / "rcd-excl-forced.toml")
          "exclude = [\"tests/modes/.rcd-impl-excluded.lean\"]\nforce-exclude = true\n"
      writeFile (work / "rcd-w100.toml") "[format]\nline-width = 100\n"
      writeFile (work / "rcd-w20.toml") "[format]\nline-width = 20\n"
      writeFile (work / "rcd-w100-lint.toml")
          "[format]\nline-width = 100\n[lint]\nselect = [\"security\"]\n"
      writeFile (work / "reject-validator")
          -- The fake validator speaks the batch transport: given the trailing output paths it
          -- writes its envelope to the out file; without them it prints to stdout, as a direct
          -- invocation always has.
          "#!/bin/sh\njson='{\"artifact\":null,\"diagnostics\":[\"forced validation rejection\"]}'\n\
       if [ -n \"$6\" ]; then printf '%s\\n' \"$json\" >\"$6\"; else printf '%s\\n' \"$json\"; fi\n"
      writeFile (work / "stale-hook") "#!/bin/sh\nprintf '\\n-- concurrent change\\n' >>\"$1\"\n"
      writeFile (work / "crash-hook") "#!/bin/sh\nexit 1\n"
      writeFile (work / "fin-stale-hook")
          "#!/bin/sh\nprintf '\\n-- concurrent change\\n' >>\"$1\"\n"
      for hook in ["reject-validator", "stale-hook", "crash-hook", "fin-stale-hook"]do
        discard <| expectExit 0 "chmod" "chmod" #["+x", (work / hook).toString]
      removeDirAll? ctx.cacheRoot
      discard <|
          expectExit 0 "lake build fixtures" "lake"
            #["build", "lean-fmt", "lean-fmt-tests", "LocalSyntax:leanFmtArtifact",
              "Findings:leanFmtArtifact", "Clean:leanFmtArtifact", "Layout:leanFmtArtifact"]
            (cwd? := some root) (env := #[("LEAN_NUM_THREADS", some "1")]) (timeoutMs :=
            some 1800000)
      let cases : Array Case :=
        #[{ name := "previews", run := Modes.testPreviews ctx },
          { name := "layout-format", run := Modes.testLayoutFormat ctx },
          { name := "layout-no-newline", run := Modes.testLayoutNoNewline ctx },
          { name := "cache-paths", run := Modes.testCachePaths ctx },
          { name := "check-populated-miss", run := Modes.testCheckPopulatedMiss ctx },
          { name := "projected-hit", run := Modes.testProjectedHit ctx },
          { name := "applicability", run := Modes.testApplicability ctx },
          { name := "unsafe-demotion", run := Modes.testUnsafeDemotion ctx },
          { name := "config-contradiction", run := Modes.testConfigContradiction ctx },
          { name := "include-config", run := Modes.testIncludeConfig ctx },
          { name := "ignore-and-cli-select", run := Modes.testIgnoreAndCliSelect ctx },
          { name := "unknown-key", run := Modes.testUnknownKey ctx },
          { name := "statistics", run := Modes.testStatistics ctx },
          { name := "validator-rejection", run := Modes.testValidatorRejection ctx },
          { name := "stale-source-race", run := Modes.testStaleSourceRace ctx },
          { name := "write-crash", run := Modes.testWriteCrash ctx },
          { name := "fix-permissions", run := Modes.testFixPermissions ctx },
          { name := "rules-registry", run := Modes.testRulesRegistry ctx },
          { name := "compiler-setup", run := Modes.testCompilerSetup ctx },
          { name := "downstream-integration", run := Modes.testDownstream ctx },
          { name := "compiler-status", run := Modes.testCompilerStatus ctx },
          { name := "organize-self", run := Modes.testOrganizeSelf ctx },
          { name := "format-self", run := Modes.testFormatSelf ctx },
          { name := "clean", run := Modes.testClean ctx },
          { name := "rdf-impl-mixed", run := Modes.testRdfImplMixed ctx },
          { name := "rdf-layout", run := Modes.testRdfLayout ctx },
          { name := "composition-confluence", run := Modes.testCompositionConfluence ctx },
          { name := "fip-exact-write", run := Modes.testFipExactWrite ctx },
          { name := "fip-write-refusals", run := Modes.testFipWriteRefusals ctx },
          { name := "fip-stale-and-selection", run := Modes.testFipStaleAndSelection ctx },
          { name := "fip-previews-never-write", run := Modes.testFipPreviewsNeverWrite ctx },
          { name := "rcd-floor", run := Modes.testRcdFloor ctx },
          { name := "rcd-explicit-exclusion", run := Modes.testRcdExplicitExclusion ctx },
          { name := "width-cache-identity", run := Modes.testWidthCacheIdentity ctx },
          { name := "config-show", run := Modes.testConfigShow ctx }]
      -- The old script's trap: restore the tracked fixtures, clear the root cache, and remove
      -- every scratch fixture no matter how the suite ended.
      let code ←
        (try
            runCases "modes" cases args
          catch error =>
            do
              IO.eprintln (toString error)
              pure 1)
      Modes.cpPreserve ctx.backupFindings ctx.findings
      Modes.cpPreserve ctx.backupLayout ctx.layout
      removeDirAll? ctx.cacheRoot
      for name in
        [".rdf-layout-nosel.lean", ".rdf-layout-string.lean", ".rdf-layout-tail.lean",
          ".rdf-impl-mixed.lean", ".rdf-final-comp-a.lean", ".rdf-final-comp-b.lean",
          ".fip-final-exact.lean", ".fip-final-broken.lean", ".fip-final-crlf.lean",
          ".fip-final-string.lean", ".fip-final-stale.lean", ".fip-final-incl.lean",
          ".fip-final-excl.lean", ".rcd-impl-excluded.lean"]do
        removeFile? (ctx.modesDir / name)
      removeFile? (root / ".lake" / "build" / ".rcd-impl-floor.lean")
      removeFile? (root / ".lake" / "build" / "lean-fmt-clean-sentinel")
      for orphan in ← Modes.tmpOrphans ctx.modesDir ".fip-final-"do
        if orphan.contains "lean-fmt-tmp-" then
          removeFile? (ctx.modesDir / orphan)
      return code
