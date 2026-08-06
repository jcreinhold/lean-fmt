module

public import Test

/-!
# The watch suite

Port of `tests/watch/run.sh`: the characterization suite for the platform behaviors
`LeanFmt/Watch.lean` is built on, plus the CLI rejection surface.

The first half deliberately tests **git and the filesystem**, not `lean-fmt`. Every assertion is a
premise the selection adapter is built on; if a future git changes one of them, the
adapter is silently wrong and this suite makes it fail loudly instead. The second half is all
rejections and error paths, checked before any project load, so it stays fast.

Lane: exclusive — one case edits the tracked `tests/fixtures/check/Clean.lean` in place (restored from a
`cp -p` byte copy, never `git checkout --`: checkout restores HEAD, not what the working tree
held, and a suite may read the repository but not decide what the working tree contains).
-/

open LeanFmt.Test

namespace Watch

structure Ctx where
  root : System.FilePath
  app : String
  work : System.FilePath
  fixture : System.FilePath

private def git (args : Array String) (cwd : System.FilePath) (label : String) : IO ProcResult :=
  expectExit 0 label "git" args (cwd? := some cwd)

private def gitAny (args : Array String) (cwd : System.FilePath) : IO ProcResult :=
  runProc "git" args (cwd? := some cwd)

/-- §2 mtime carries populated nanoseconds, and distinguishes a same-size rewrite. The whole poll
design rests on this; a binding that truncated to whole seconds would make `(size, mtime)` blind
to a fast edit. -/
private def testMtimeGranularity (ctx : Ctx) : IO Unit := do
  let probe := ctx.work / "mtime-probe.txt"
  let nanos (m : IO.FS.Metadata) : Int := m.modified.sec * 1000000000 + m.modified.nsec.toNat
  -- Real edits are seconds apart, so the adapter's assumption is that a same-size rewrite is
  -- distinguishable well inside a second — not that the filesystem timestamps every write.
  -- ubuntu-22.04 runners collide on back-to-back writes (the v0.2.1 release legs failed
  -- there while ubuntu-latest passed), so probe with backoff up to about two seconds before
  -- declaring the environment too coarse to watch.
  let mut sleepMs : UInt32 := 0
  let mut distinguished := false
  for _ in [0:9]do
    if distinguished then
      break
    if sleepMs != 0 then
      IO.sleep sleepMs
    writeFile probe "AAAA"
    let first ← probe.metadata
    writeFile probe "BBBB"
    let second ← probe.metadata
    ensureEq "same-size rewrite kept its size (that is the point)" 4 second.byteSize
    if nanos first != nanos second then
      distinguished := true
    sleepMs := max 1 (sleepMs * 4)
  ensure distinguished
      "same-size rewrites stayed indistinguishable for two seconds; the adapter assumes sub-second granularity"

/-- §9.4 `git diff` never reports untracked files — the assertion that protects users from the
worst failure mode of a `--changed` mode built on `diff` alone — and `--exclude-standard` honours
.gitignore. -/
private def testDiffNeverReportsUntracked (ctx : Ctx) : IO Unit := do
  let diff ← git #["diff", "--name-status", "HEAD"] ctx.fixture "git diff"
  ensure (!(diff.stdout.contains "New.lean"))
      "git diff reported an untracked file; §9.4 unions ls-files precisely because it does not"
  let others ← git #["ls-files", "--others", "--exclude-standard"] ctx.fixture "git ls-files"
  let names := others.stdout.splitOn "\n"
  ensure ((names.any (· == "New.lean")))
      "git ls-files --others did not report the untracked New.lean"
  ensure (!(names.any (· == "Ignored.lean")))
      "git ls-files --others --exclude-standard leaked an ignored file"

/-- §9.2/§9.3 the `-z` stream: rename records carry three fields, everything else two. A parser
that assumes pairs desynchronizes on the first rename. -/
private def testZStreamRecords (ctx : Ctx) : IO Unit := do
  let diff ← git #["diff", "--name-status", "-z", "HEAD"] ctx.fixture "git diff -z"
  let fields := (diff.stdout.splitOn "\x00").filter (· != "")
  ensure (fields.length > 0) "git diff -z produced no fields for the fixture"
  let renameIndex? := fields.findIdx? (·.startsWith "R")
  let deleteIndex? := fields.findIdx? (· == "D")
  let some renameIndex := renameIndex? | throw <| IO.userError "fixture produced no rename record"
  ensureEq "-z rename old path" "A.lean" (fields[renameIndex + 1]?.getD "<missing>")
  ensureEq "-z rename new path" "Renamed.lean" (fields[renameIndex + 2]?.getD "<missing>")
  let some deleteIndex := deleteIndex? | throw <| IO.userError "fixture produced no delete record"
  ensureEq "-z delete path" "C.lean" (fields[deleteIndex + 1]?.getD "<missing>")

/-- §9.2 only `-z` is byte-exact: default output C-quotes non-ASCII. -/
private def testZByteExact (ctx : Ctx) : IO Unit := do
  let name := "Ünïcode Spaced.lean"
  let plain ← git #["diff", "--name-status", "HEAD~1"] ctx.fixture "git diff plain"
  ensure (!(plain.stdout.contains name))
      "git diff emitted a raw non-ASCII path without -z; §9.2 assumed it C-quotes"
  let z ← git #["diff", "--name-status", "-z", "HEAD~1"] ctx.fixture "git diff -z unicode"
  ensure (z.stdout.contains name) "git diff -z did not emit the non-ASCII path byte-exactly"

/-- §9.1 three-dot is the merge-base question; two-dot is not. -/
private def testThreeDot (ctx : Ctx) : IO Unit := do
  let leanCount (result : ProcResult) : Nat :=
    ((result.stdout.splitOn "\x00").filter (·.endsWith "lean")).length
  let threeDot ← git #["diff", "--name-status", "-z", "main...feature"] ctx.fixture "three-dot"
  let twoDot ← git #["diff", "--name-status", "-z", "main..feature"] ctx.fixture "two-dot"
  ensure (!(threeDot.stdout.contains "MainOnly.lean"))
      "three-dot diff reported a path the branch never touched"
  ensure (twoDot.stdout.contains "MainOnly.lean")
      "two-dot diff did not report MainOnly.lean; §9.1 rejected two-dot for exactly that noise"
  ensure (leanCount threeDot < leanCount twoDot)
      s!"three-dot ({leanCount threeDot}) did not select fewer paths than two-dot \
      ({leanCount twoDot})"

/-- §9.7 probe with rev-parse, not diff: outside a repository rev-parse exits 128 with one clean
line; git diff dumps its entire option usage. -/
private def testRevParseProbe (ctx : Ctx) : IO Unit := do
  let outside := ctx.work / "not-a-repo"
  IO.FS.createDirAll outside
  let revParse ← gitAny #["rev-parse", "--show-toplevel"] outside
  ensureEq "rev-parse outside a repository exits 128" 128 revParse.exitCode
  let revLines := ((revParse.stdout ++ revParse.stderr).splitOn "\n").filter (· != "")
  ensureEq "rev-parse outside a repository says one thing" 1 revLines.length
  let diff ← gitAny #["diff", "--name-status", "HEAD"] outside
  ensure (diff.exitCode != 128)
      "git diff now exits 128 outside a repository; §9.7 chose rev-parse on the assumption it does not"
  let diffLines := ((diff.stdout ++ diff.stderr).splitOn "\n").filter (· != "")
  ensure (diffLines.length >= 10)
      s!"git diff outside a repository no longer dumps usage ({diffLines.length} lines); \
      revisit the rev-parse choice"

-- -----------------------------------------------------------------------------------------------
-- The CLI surface: rejections and error paths.

private def expectRejection (ctx : Ctx) (what fragment : String) (args : Array String)
    (cwd : Option System.FilePath := none) : IO Unit := do
  let result ← runProc ctx.app args (cwd? := some (cwd.getD ctx.root))
  ensureEq s!"{what}: exit" 2 result.exitCode
  ensure (result.stderr.contains fragment)
      s!"{what}: expected to mention '{fragment}', got: {result.stderr}"

private def testWatchRejections (ctx : Ctx) : IO Unit := do
  -- §10 A writing mode under watch publishes source, which changes the mtimes the poll observes:
  -- self-sustaining by construction, so both writers are refused.
  expectRejection ctx "check --fix --watch" "not available for check --fix"
      #["check", "--fix", "--watch"]
  expectRejection ctx "format --watch" "not available for format" #["format", "--watch"]
  -- §7 A stream of documents is not a document, so json/sarif/junit need a destination.
  expectRejection ctx "sarif on stdout under watch" "requires --output-file"
      #["check", "--watch", "--output-format", "sarif"]
  expectRejection ctx "junit on stdout under watch" "requires --output-file"
      #["check", "--watch", "--output-format", "junit"]
  expectRejection ctx "json on stdout under watch" "requires --output-file"
      #["format", "--check", "--watch", "--output-format", "json"]
  -- §2 Watch observes disk; a buffer on stdin has no mtime to poll.
  expectRejection ctx "watch with stdin target" "stdin target"
      #["check", "--watch", "-", "--stdin-filename", "x.lean"]
  -- A tunable that only means something under --watch is refused elsewhere.
  expectRejection ctx "poll interval without watch" "valid only with --watch"
      #["check", "--poll-interval", "50"]
  -- §9 Naming files and asking git to name them are two answers to one question.
  expectRejection ctx "changed plus explicit files" "do not also name them"
      #["check", "--changed", "LeanFmt/Doc.lean"]
  expectRejection ctx "changed-since without a revision" "expects a revision"
      #["check", "--changed-since"]
  -- §9.7 An unknown revision names what the caller typed, distinctly from "not a repository".
  expectRejection ctx "unknown revision" "unknown revision: definitely-not-a-ref"
      #["check", "--changed-since", "definitely-not-a-ref"]

/-- §9.7 outside a repository, the diagnostic is the one clean rev-parse line — not git diff's
usage dump, and not a Lean exception. -/
private def testChangedOutsideRepo (ctx : Ctx) : IO Unit := do
  let outside := ctx.work / "outside-repo"
  IO.FS.createDirAll outside
  let result ← runProc ctx.app #["check", "--changed", "--root", "."] (cwd? := some outside)
  ensureEq "changed outside a repository exits 2" 2 result.exitCode
  ensure (result.stderr.contains "requires a git repository")
      s!"expected a git-repository diagnostic outside a repository, got: {result.stderr}"
  ensure (!(result.stderr.contains "--no-index"))
      "the non-repository diagnostic leaked git diff's usage text; §9.7 probes with rev-parse"

/-- §9.6 a selection of zero files is a success with an explicit notice — never a silent clean
report, and never the whole project. -/
private def testStagedEmpty (ctx : Ctx) : IO Unit := do
  let result ← runProc ctx.app #["check", "--staged", "--root", "."] (cwd? := some ctx.root)
  ensureEq "an empty staged selection succeeds" 0 result.exitCode
  ensure (result.stderr.contains "no changed Lean sources")
      s!"an empty --staged selection did not say so explicitly: {result.stderr}"

/-- §9.6 a non-empty selection discloses that it covers a subset. -/
private def testChangedDisclosure (ctx : Ctx) : IO Unit := do
  let clean := ctx.root / "tests" / "fixtures" / "check" / "Clean.lean"
  let backup := ctx.work / "Clean.lean.orig"
  discard <| expectExit 0 "backup" "cp" #["-p", clean.toString, backup.toString]
  try
    IO.FS.withFile clean .append fun handle => handle.putStr "\n"
    let result ← runProc ctx.app #["check", "--changed", "--root", "."] (cwd? := some ctx.root)
    ensure (result.stderr.contains "changed-file selection: worktree vs HEAD")
        s!"a --changed run did not report its comparison: {result.stderr}"
    ensure (result.stderr.contains "not the whole project")
        s!"a --changed run did not disclose that it covers a subset: {result.stderr}"
  finally
    discard <| expectExit 0 "restore" "cp" #["-p", backup.toString, clean.toString]

/-- §9.5 regression: an untracked non-Lean file must not abort a --changed run. An explicitly
named file bypasses gates 2-4, and the floor it cannot skip is a hard error — so the adapter
applies the floor itself. -/
private def testUntrackedNonLean (ctx : Ctx) : IO Unit := do
  let marker := ctx.root / "tests" / "watch" / ".regression-untracked.md"
  writeFile marker "not a lean source\n"
  try
    let result ← runProc ctx.app #["check", "--changed", "--root", "."] (cwd? := some ctx.root)
    ensure (!(result.stderr.contains "is not a Lean source"))
        s!"an untracked non-Lean file aborted --changed: {result.stderr}"
    ensure (result.exitCode == 0 || result.exitCode == 1)
        s!"--changed with an untracked non-Lean file exited {result.exitCode}: {result.stderr}"
  finally
    removeFile? marker

end Watch

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  withTempDir fun work => do
      -- The fixture repository for the git assertions: a rename, a delete, a modification, an
      -- untracked file, and an ignored file.
      let fixture := work / "repo"
      IO.FS.createDirAll (fixture / "sub")
      discard <| Watch.git #["init", "-q", "-b", "main", "."] fixture "git init"
      discard <|
          Watch.git #["config", "user.email", "lean-fmt@example.invalid"] fixture "git config"
      discard <| Watch.git #["config", "user.name", "lean-fmt tests"] fixture "git config"
      writeFile (fixture / "A.lean") "a\n"
      writeFile (fixture / "sub" / "B.lean") "b\n"
      writeFile (fixture / "C.lean") "c\n"
      discard <| Watch.git #["add", "-A"] fixture "git add"
      discard <| Watch.git #["commit", "-qm", "base"] fixture "git commit"
      discard <| Watch.git #["mv", "A.lean", "Renamed.lean"] fixture "git mv"
      IO.FS.withFile (fixture / "sub" / "B.lean") .append fun handle => handle.putStr "b2\n"
      discard <| Watch.git #["rm", "-q", "C.lean"] fixture "git rm"
      writeFile (fixture / "New.lean") "n\n"
      writeFile (fixture / "Ignored.lean") "ig\n"
      writeFile (fixture / ".gitignore") "Ignored.lean\n"
      let ctx : Watch.Ctx :=
        { root, app := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, work, fixture }
      -- The byte-exact case needs the rename/delete committed first, then the non-ASCII path.
      let byteExact : IO Unit := do
        discard <| Watch.git #["add", "-A"] fixture "git add"
        discard <| Watch.git #["commit", "-qm", "second"] fixture "git commit"
        writeFile (fixture / "Ünïcode Spaced.lean") "u\n"
        discard <| Watch.git #["add", "-A"] fixture "git add"
        discard <| Watch.git #["commit", "-qm", "unicode"] fixture "git commit"
        Watch.testZByteExact ctx
      -- The merge-base case needs the branch topology.
      let threeDot : IO Unit := do
        discard <| Watch.git #["checkout", "-q", "-b", "feature"] fixture "git branch"
        writeFile (fixture / "Feat.lean") "feat\n"
        discard <| Watch.git #["add", "-A"] fixture "git add"
        discard <| Watch.git #["commit", "-qm", "feat"] fixture "git commit"
        discard <| Watch.git #["checkout", "-q", "main"] fixture "git checkout"
        writeFile (fixture / "MainOnly.lean") "mainonly\n"
        discard <| Watch.git #["add", "-A"] fixture "git add"
        discard <| Watch.git #["commit", "-qm", "mainonly"] fixture "git commit"
        discard <| Watch.git #["checkout", "-q", "feature"] fixture "git checkout"
        Watch.testThreeDot ctx
      let cases : Array Case :=
        #[{ name := "mtime-granularity", run := Watch.testMtimeGranularity ctx },
          { name := "diff-never-reports-untracked",
            run := Watch.testDiffNeverReportsUntracked ctx },
          { name := "z-stream-records", run := Watch.testZStreamRecords ctx },
          { name := "z-byte-exact", run := byteExact }, { name := "three-dot", run := threeDot },
          { name := "rev-parse-probe", run := Watch.testRevParseProbe ctx },
          { name := "watch-rejections", run := Watch.testWatchRejections ctx },
          { name := "changed-outside-repo", run := Watch.testChangedOutsideRepo ctx },
          { name := "staged-empty", run := Watch.testStagedEmpty ctx },
          { name := "changed-disclosure", run := Watch.testChangedDisclosure ctx },
          { name := "untracked-non-lean", run := Watch.testUntrackedNonLean ctx }]
      runCases "watch" cases args
