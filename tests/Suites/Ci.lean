module

public import Test

/-!
# The ci suite

The CI recipes in `docs/ci.md`, executed. A documented command nobody runs is a claim, not a recipe,
and every claim in that document is about a *consuming* project: a git `require`, real commit
history, and no warm state. This repository's own tree has none of those properties, so the suite
builds a scratch consumer in a temp dir and throws it away.

The pin is this working tree's HEAD, cloned over `file://`; the archive section reads
`git archive`. Both read **committed** state, so uncommitted changes are not under test here —
the suite answers "can a consumer install and run what is committed". Commit first, then run
this.

Lane: exclusive+slow — two full dependency builds (the consumer and the archive).
-/

open LeanFmt.Test

namespace Ci

structure Ctx where
  root : System.FilePath
  work : System.FilePath
  consumer : System.FilePath

private def gitQ (args : Array String) (cwd : System.FilePath) (label : String) : IO ProcResult :=
  expectExit 0 label "git"
    (#["-c", "user.email=ci@lean-fmt.invalid", "-c", "user.name=lean-fmt ci"] ++ args) (cwd? :=
    some cwd)

private def lake (ctx : Ctx) (args : Array String) (label : String) : IO ProcResult :=
  expectExit 0 label "lake" args (cwd? := some ctx.consumer) (timeoutMs := some 3600000)

private def lakeAny (ctx : Ctx) (args : Array String) : IO ProcResult :=
  runProc "lake" args (cwd? := some ctx.consumer) (timeoutMs := some 3600000)

private def commitAll (ctx : Ctx) (message : String) : IO Unit := do
  discard <| gitQ #["add", "-A"] ctx.consumer "git add"
  discard <| gitQ #["commit", "-qm", message] ctx.consumer "git commit"

/-- Recipe 1: the minimal lake lint job. `leanprover/lean-action` probes `check-lint` before
running `lake lint`, so a driver that does not announce itself is a job that silently lints
nothing. -/
private def testLintDriver (ctx : Ctx) : IO Unit := do
  discard <| lake ctx #["check-lint"] "lake check-lint does not see a configured driver"
  let clean ← lakeAny ctx #["lint"]
  ensureEq "lake lint on a clean tree did not return 0" 0 clean.exitCode
  -- Now give it something to find. FMT003 is a duplicate import: stable, safe-fixable, and it
  -- does not depend on line width or preview status.
  writeFile (ctx.consumer / "Demo" / "Dirty.lean")
      "module\n\nimport Demo.Basic\nimport Demo.Basic\n\npublic def other : String := greeting\n"
  IO.FS.withFile (ctx.consumer / "Demo.lean") .append fun handle =>
      handle.putStr "import Demo.Dirty\n"
  commitAll ctx "add a module with a duplicate import"
  let dirty ← lakeAny ctx #["lint"]
  ensureEq "lake lint with findings did not return 1" 1 dirty.exitCode
  ensure ((dirty.stdout ++ dirty.stderr).contains "FMT003 duplicate import")
      "lake lint did not carry the driver output through"

/-- Recipe 2: SARIF into code scanning. The recipe uploads unconditionally and guards on the file
existing; both halves are load-bearing, because getting either wrong fails only in CI, months
later. -/
private def testSarif (ctx : Ctx) : IO Unit := do
  let findings ←
    lakeAny ctx
        #["exe", "lean-fmt", "check", "--root", ".", "--output-format", "sarif", "--output-file",
          "findings.sarif"]
  ensureEq "sarif run with findings did not return 1" 1 findings.exitCode
  ensure
      ((← (ctx.consumer / "findings.sarif").pathExists) &&
        (← (ctx.consumer / "findings.sarif").metadata).byteSize > 0)
      "a run with findings wrote no SARIF log"
  -- A clean run must still write a complete log; this is what resolves previously-reported
  -- alerts, and if it stops being written stale alerts stay open forever.
  let clean ←
    lakeAny ctx
        #["exe", "lean-fmt", "check", "--root", ".", "--output-format", "sarif", "--output-file",
          "clean.sarif", "Demo/Basic.lean"]
  ensureEq "sarif run on a clean file did not return 0" 0 clean.exitCode
  let cleanSarif := ctx.consumer / "clean.sarif"
  ensure (← cleanSarif.pathExists) "a clean run wrote no SARIF log"
  let report ← parseJson (← IO.FS.readFile cleanSarif) "clean.sarif"
  ensureJsonAt report [.field "runs", .index 0, .field "results"] (.arr #[])
      "a clean run reported SARIF results"
  -- The `hashFiles(...) != ''` guard in the recipe exists because of exactly this.
  let absent ←
    lakeAny ctx
        #["exe", "lean-fmt", "check", "--root", ".", "--output-format", "sarif", "--output-file",
          "absent.sarif", "NoSuchFile.lean"]
  ensureEq "a missing named file did not return 2" 2 absent.exitCode
  ensure (!(← (ctx.consumer / "absent.sarif").pathExists))
      "an infrastructure failure left a SARIF file; the recipe guard assumes it does not"
  -- Schema validation where the tooling exists.
  let uv ← runProc "sh" #["-c", "command -v uv"]
  if uv.exitCode == 0 then
    discard <|
        expectExit 0 "SARIF from a consuming project failed schema validation" "uv"
          #["run", "--with", "check-jsonschema", "--quiet", "check-jsonschema", "--schemafile",
            (ctx.root / "tests" / "fixtures" / "reporting" / "sarif-schema-2.1.0.json").toString,
            (ctx.consumer / "findings.sarif").toString]
          (timeoutMs := some 600000)
  else
    IO.println "  skip the SARIF schema check needs uv"

/-- Recipe 3: changed files on a pull request. -/
private def testChangedSince (ctx : Ctx) : IO Unit := do
  discard <| gitQ #["checkout", "-q", "-b", "feature"] ctx.consumer "git branch"
  writeFile (ctx.consumer / "Demo" / "New.lean")
      "module\n\nimport Demo.Basic\nimport Demo.Basic\n\npublic def fresh : String := greeting\n"
  IO.FS.withFile (ctx.consumer / "Demo.lean") .append fun handle =>
      handle.putStr "import Demo.New\n"
  commitAll ctx "add another module with a duplicate import"
  let changed ← lakeAny ctx #["exe", "lean-fmt", "check", "--root", ".", "--changed-since", "main"]
  ensureEq "--changed-since with findings did not return 1" 1 changed.exitCode
  let output := changed.stdout ++ changed.stderr
  ensure (output.contains "main...HEAD (merge base)")
      s!"--changed-since stopped announcing its comparison: {output}"
  ensure (output.contains "Demo/New.lean")
      "--changed-since did not select the file this branch added"
  -- The subset claim: a file with a real finding that this branch did not touch stays
  -- unselected.
  ensure (!(output.contains "Demo/Dirty.lean"))
      "--changed-since selected a file the branch did not change"
  -- An empty selection means "nothing to do", not "the whole project".
  let empty ← lakeAny ctx #["exe", "lean-fmt", "check", "--root", ".", "--changed-since", "HEAD"]
  ensureEq "--changed-since selecting nothing did not return 0" 0 empty.exitCode
  ensure ((empty.stdout ++ empty.stderr).contains "no changed Lean sources")
      s!"--changed-since selecting nothing lost its notice: {empty.stdout}{empty.stderr}"

/-- Recipe 4: a generic runner, exit codes only — and a pipeline must not launder a failure into
success. -/
private def testGenericRunner (ctx : Ctx) : IO Unit := do
  let junit ←
    lakeAny ctx
        #["exe", "lean-fmt", "check", "--root", ".", "--output-format", "junit", "--output-file",
          "report.xml"]
  ensureEq "junit run with findings did not return 1" 1 junit.exitCode
  ensure ((← IO.FS.readFile (ctx.consumer / "report.xml")).contains "<testsuites name=\"lean-fmt\"")
      "the JUnit report lost its root element"
  let pipeScript := ctx.work / "pipe.sh"
  writeFile pipeScript
      "set -o pipefail\nlake exe lean-fmt check --root . Demo/Dirty.lean 2>/dev/null | head -1 \
     >/dev/null\necho $?\n"
  let piped ← runProc "bash" #[pipeScript.toString] (cwd? := some ctx.consumer)
  ensureEq "a truncated pipeline laundered the findings" "1" (piped.stdout.trimAscii.toString)

/-- What docs/ci.md tells CI to cache, and the three restores it has to survive.

Cache identity takes the formatter binary's **content**, so a restore hits whether or not the
binary's modification time and path survived the trip. All three cases here assert a hit, and that
is the point: they used to assert that the last two *missed*, because identity was (path, size,
mtime) and any CI job that rebuilt or reinstalled lean-fmt threw its whole cache away.

A total miss looks exactly like a warm cache that is merely slow — nothing in the report says which
happened — so the entry set is compared file by file rather than timed.

The negative direction, that a formatter with different bytes must miss, is not staged here: it
would need a second working lean-fmt built from different sources, and a corrupted copy would not
run. It belongs to `cacheIdentityDigest`, which folds the formatter digest in with the rest. -/
private def testCacheRestore (ctx : Ctx) : IO Unit := do
  discard <| gitQ #["checkout", "-q", "main"] ctx.consumer "git checkout main"
  removeDirAll? (ctx.consumer / ".lean-fmt-cache")
  discard <| lakeAny ctx #["exe", "lean-fmt", "check", "--root", "."]
  -- The formatter-identity memo is excluded: it is written whenever the cache opens at all, so
  -- counting it would let "a cold run wrote no cache entry" pass on a run that stored nothing.
  let entries (dir : System.FilePath) : IO (List String) := do
    if !(← dir.pathExists) then
      return []
    let found ← dir.walkDir
    return ((found.toList.map toString).filter fun path =>
            path.endsWith ".json" && !path.endsWith "formatter-identity.json").mergeSort
        (· < ·)
  let cacheDir := ctx.consumer / ".lean-fmt-cache"
  let before ← entries cacheDir
  ensure (before != []) "a cold run wrote no cache entry"
  -- Restore preserving mtimes, the way actions/cache unpacks with tar.
  discard <|
      expectExit 0 "tar create" "tar"
        #["-czf", (ctx.work / "cache.tgz").toString, ".lake", ".lean-fmt-cache"] (cwd? :=
        some ctx.consumer)
  removeDirAll? (ctx.consumer / ".lake")
  removeDirAll? cacheDir
  discard <|
      expectExit 0 "tar extract" "tar" #["-xzf", (ctx.work / "cache.tgz").toString] (cwd? :=
        some ctx.consumer)
  discard <| lakeAny ctx #["exe", "lean-fmt", "check", "--root", "."]
  ensureEq "an mtime-preserving restore did not hit the cache" before (← entries cacheDir)
  -- A new modification time must *not* orphan the cache. It used to: identity was the binary's
  -- path, size, and mtime, so any CI job that rebuilt or reinstalled lean-fmt threw away every
  -- stored entry for a binary that behaves identically. Identity is the content hash now, so the
  -- bytes decide and a touch decides nothing.
  let binary :=
    ctx.consumer / ".lake" / "packages" / "lean-fmt" / ".lake" / "build" / "bin" / "lean-fmt"
  discard <| expectExit 0 "touch" "touch" #[binary.toString]
  discard <| lakeAny ctx #["exe", "lean-fmt", "check", "--root", "."]
  ensureEq "touching the formatter binary orphaned the cache" before (← entries cacheDir)
  -- The same bytes at a different path, which is what reinstalling looks like. Both runs are
  -- direct rather than through `lake exe`, and the baseline is re-taken under a direct run first:
  -- `lake exe` injects its own environment into the child, and the epoch covers that environment,
  -- so comparing a direct run against a Lake-launched one would move two variables and blame the
  -- path for both.
  discard <|
      runProc binary.toString #["check", "--root", "."] (cwd? := some ctx.consumer) (timeoutMs :=
        some 1800000)
  let direct ← entries cacheDir
  let moved := ctx.work / "reinstalled-lean-fmt"
  copyFile binary moved
  discard <| expectExit 0 "chmod" "chmod" #["+x", moved.toString]
  discard <|
      runProc moved.toString #["check", "--root", "."] (cwd? := some ctx.consumer) (timeoutMs :=
        some 1800000)
  ensureEq "the same formatter at a different path orphaned the cache" direct (← entries cacheDir)

/-- Installation from clean sources. `git archive` carries exactly what is committed, which
catches a source file that is gitignored but needed to build — a defect invisible from any
working tree that has the file. -/
private def testArchiveInstallation (ctx : Ctx) : IO Unit := do
  let archive := ctx.work / "archive"
  IO.FS.createDirAll archive
  -- `git archive -o`: the tarball is binary, and a capture through a UTF-8 string would corrupt
  -- it, so git writes the file itself.
  let tarballPath := ctx.work / "archive.tar"
  discard <|
      expectExit 0 "git archive" "git"
        #["archive", "--format=tar", "-o", tarballPath.toString, "HEAD"] (cwd? := some ctx.root)
  discard <| expectExit 0 "tar extract" "tar" #["-xf", tarballPath.toString] (cwd? := some archive)
  ensure (!(← (archive / ".lake").pathExists)) "the archive carries a build directory"
  ensure (!(← (archive / ".lean-fmt-cache").pathExists)) "the archive carries a result cache"
  for required in ["lean-toolchain", "lakefile.lean", "lake-manifest.json", "lean-fmt.toml"] do
    ensure (← (archive / required).pathExists)
        s!"the archive is missing {required}, which a consumer needs"
  discard <|
      expectExit 0 "a clean git archive did not build" "lake" #["build"] (cwd? := some archive)
        (timeoutMs := some 3600000)
  let check ←
    runProc (archive / ".lake" / "build" / "bin" / "lean-fmt").toString #["check", "--root", "."]
        (cwd? := some archive) (timeoutMs := some 1800000)
  ensureEq "the archive's own binary did not run clean against the archive" 0 check.exitCode

end Ci

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  withTempDir fun work => do
      let headSha :=
        (←
            expectExit 0 "git rev-parse" "git" #["rev-parse", "HEAD"] (cwd? :=
                some root)).stdout.trimAscii.toString
      let consumer := work / "consumer"
      IO.FS.createDirAll (consumer / "Demo")
      copyFile (root / "lean-toolchain") (consumer / "lean-toolchain")
      writeFile (consumer / "lakefile.lean")
          s!"import Lake\nopen Lake DSL\n\nrequire «lean-fmt» from git \"file://{root}\" @ \
        \"{headSha}\"\n\npackage demo where\n  lintDriver := \"«lean-fmt»/«lean-fmt»\"\n  \
        lintDriverArgs := #[\"check\"]\n\n@[default_target]\nlean_lib Demo\n"
      writeFile (consumer / "Demo.lean") "module\n\nimport Demo.Basic\n"
      writeFile (consumer / "Demo" / "Basic.lean")
          "module\n\npublic def greeting : String := \"hello\"\n"
      writeFile (consumer / ".gitignore") ".lake/\n.lean-fmt-cache/\n*.sarif\n*.xml\n"
      -- `-b main`: the recipes branch and checkout `main` by name, and git's compiled-in
      -- default is still `master` on some runners — the assumption must be made, not inherited.
      discard <|
          expectExit 0 "git init" "git" #["init", "-q", "-b", "main", "."] (cwd? := some consumer)
      let ctx : Ci.Ctx := { root, work, consumer }
      Ci.commitAll ctx "clean baseline"
      discard <| Ci.lake ctx #["update"] "lake update could not resolve the git dependency"
      discard <| Ci.lake ctx #["build"] "the consuming project did not build"
      runCases "ci"
          #[{ name := "lint-driver-recipe", run := Ci.testLintDriver ctx },
            { name := "sarif-recipe", run := Ci.testSarif ctx },
            { name := "changed-since-recipe", run := Ci.testChangedSince ctx },
            { name := "generic-runner-recipe", run := Ci.testGenericRunner ctx },
            { name := "cache-restore", run := Ci.testCacheRestore ctx },
            { name := "archive-installation", run := Ci.testArchiveInstallation ctx }]
          args
