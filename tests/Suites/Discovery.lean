module

public import Test

/-!
# The discovery suite

Port of `tests/discovery/run.sh` (`ruff-13` RCD-FINAL): hierarchical configuration discovery end
to end, through the shipped binary, on real project trees.

This suite is deliberately separate from the modes suite. That one owns the *write* path inside
this repository, where a mistake damages tracked files. This one owns *discovery*, which needs
arbitrary tree shapes — nested workspaces, symlink loops, a config outside the root, thousands of
files — that cannot be built inside the formatter's own repository without polluting the printer
corpus and the git index. Every fixture here is a synthetic Lake project under a temporary
directory.

Lane: parallel — everything lives under a fresh temp dir and every invocation is `--no-cache`
against `--root <fixture>`; nothing in the repo is touched.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze (natAt?)

namespace Discovery

structure Ctx where
  root : System.FilePath
  application : String
  work : System.FilePath

/-- A minimal but real Lake project: the formatter loads a workspace for every run, so a fixture
without a toolchain and a lakefile would exercise the error path instead of discovery. -/
private def newProject (ctx : Ctx) (root : System.FilePath) : IO Unit := do
  IO.FS.createDirAll root
  copyFile (ctx.root / "lean-toolchain") (root / "lean-toolchain")
  writeFile (root / "lakefile.lean") "import Lake\nopen Lake DSL\npackage fixture\n"

/-- The discovered, selected set as a sorted list of root-relative paths. -/
private def selected (ctx : Ctx) (root : System.FilePath) (extra : Array String := #[])
    (label : String := "selected") : IO (List String) := do
  let result ← expectExit 0 label ctx.application
    (#["check", "--root", root.toString, "--json", "--no-cache"] ++ extra)
  let data ← parseJson result.stdout label
  let paths := (((jsonAt? data [.field "files"]).bind (·.getArr?.toOption)).getD #[]).filterMap
    fun file => (file.getObjValAs? String "path").toOption
  return paths.toList.mergeSort (· < ·)

/-- `config showConfig` as parsed JSON. -/
private def showConfig (ctx : Ctx) (root target : System.FilePath) (label : String := "config showConfig")
    (env : Array (String × Option String) := #[]) : IO Lean.Json := do
  let result ← expectExit 0 label ctx.application
    #["config", "show", target.toString, "--root", root.toString, "--json"] (env := env)
  parseJson result.stdout label

/-- The `value` of the setting with this key, as a string. -/
private def setting (json : Lean.Json) (key : String) (label : String) : IO String := do
  let some settings := (jsonAt? json [.field "settings"]).bind (·.getArr?.toOption)
    | throw <| IO.userError s!"{label}: no settings"
  for entry in settings do
    if (entry.getObjValAs? String "key").toOption == some key then
      match jsonAt? entry [.field "value"] with
      | some value =>
        -- The wire value is itself a string (`"42"`, `"[\"security\"]"`); quote only non-strings.
        match value with
        | .str text => return text
        | other => return other.compress
      | none => throw <| IO.userError s!"{label}: setting {key} has no value"
  throw <| IO.userError s!"{label}: no setting {key}"

/-- The `origin` basename of the setting with this key. -/
private def originBase (json : Lean.Json) (key : String) (label : String) : IO String := do
  let some settings := (jsonAt? json [.field "settings"]).bind (·.getArr?.toOption)
    | throw <| IO.userError s!"{label}: no settings"
  for entry in settings do
    if (entry.getObjValAs? String "key").toOption == some key then
      let some origin := (entry.getObjValAs? String "origin").toOption
        | throw <| IO.userError s!"{label}: setting {key} has no origin"
      return (origin.splitOn "/").getLast?.getD origin
  throw <| IO.userError s!"{label}: no setting {key}"

private def gate (json : Lean.Json) (label : String) : IO Nat :=
  match natAt? json [.field "gate"] with
  | some n => return n
  | none => throw <| IO.userError s!"{label}: no gate"

/-- Nested workspaces: the closest config governs, and does not merge. -/
private def testNested (ctx : Ctx) : IO Unit := do
  let nested := ctx.work / "nested"
  newProject ctx nested
  for dir in ["app", "lib/deep", "skipped"] do
    IO.FS.createDirAll (nested / dir)
  for file in ["Root.lean", "app/App.lean", "lib/Lib.lean", "lib/deep/Deep.lean",
      "skipped/Skipped.lean"] do
    writeFile (nested / file) "module\n"
  writeFile (nested / ".lean-fmt.toml") "exclude = [\"skipped\"]\n[format]\nline-width = 100\n"
  writeFile (nested / "lib" / ".lean-fmt.toml") "[format]\nline-width = 42\n"
  ensureEq "the excluded directory is pruned and every other source is selected"
    ["Root.lean", "app/App.lean", "lakefile.lean", "lib/Lib.lean", "lib/deep/Deep.lean"]
    (← selected ctx nested)
  ensureEq "the nested config governs its own directory" "42"
    (← setting (← showConfig ctx nested (nested / "lib" / "Lib.lean")) "format.line-width" "nested")
  ensureEq "the nested config governs its subdirectories too" "42"
    (← setting (← showConfig ctx nested (nested / "lib" / "deep" / "Deep.lean")) "format.line-width"
      "nested")
  ensureEq "a sibling directory keeps the root config" "100"
    (← setting (← showConfig ctx nested (nested / "app" / "App.lean")) "format.line-width" "nested")
  -- The hierarchy must not merge: `lib` never declared an exclude, so it has none -- it does not
  -- inherit the root's. This is the single decision that separates this design from a layered one.
  ensureEq "the nested config did not inherit the root's exclude" "[]"
    (← setting (← showConfig ctx nested (nested / "lib" / "Lib.lean")) "exclude" "nested")
  ensureEq "the root exclude reaches only the subtree it governs" 3
    (← gate (← showConfig ctx nested (nested / "skipped" / "Skipped.lean")) "nested")

/-- Extend: composition, anchors, and provenance. -/
private def testExtend (ctx : Ctx) : IO Unit := do
  let ext := ctx.work / "extend"
  newProject ctx ext
  IO.FS.createDirAll (ext / "shared")
  IO.FS.createDirAll (ext / "pkg")
  writeFile (ext / "pkg" / "Pkg.lean") "module\n"
  writeFile (ext / "shared" / "base.toml")
    "[format]\nline-width = 90\n[lint]\nselect = [\"security\"]\nextend-select = [\"FMT008\"]\n"
  writeFile (ext / "pkg" / ".lean-fmt.toml")
    "extend = \"../shared/base.toml\"\n[format]\nline-width = 42\n[lint]\n\
     extend-select = [\"FMT009\"]\n"
  let shown ← showConfig ctx ext (ext / "pkg" / "Pkg.lean")
  ensureEq "the extending file wins a scalar" "42"
    (← setting shown "format.line-width" "extend")
  ensureEq "the parent's base array is inherited" "[\"security\"]"
    (← setting shown "lint.select" "extend")
  ensureEq "extend-select concatenates parent then child" "[\"FMT008\", \"FMT009\"]"
    (← setting shown "lint.extend-select" "extend")
  -- `mktemp` roots are themselves symlinks on some systems; the physical root is what the product
  -- reports contributing files against.
  let physical := (← IO.FS.realPath ext).toString
  let contributing := (((jsonAt? shown [.field "contributingFiles"]).bind
      (·.getArr?.toOption)).getD #[]).filterMap fun file =>
    (file.getStr?.toOption).map fun path =>
      String.Pos.Raw.extract path ⟨physical.utf8ByteSize + 1⟩ ⟨path.utf8ByteSize⟩
  ensureEq "both contributing files are reported, parent first"
    ["shared/base.toml", "pkg/.lean-fmt.toml"] contributing.toList
  -- Provenance is per setting, not per file: the inherited value must name the *parent*, and the
  -- overriding value the child.
  ensureEq "an inherited value names the parent file" "base.toml:4"
    (← originBase shown "lint.select" "extend")
  ensureEq "an overriding value names the child file" ".lean-fmt.toml:3"
    (← originBase shown "format.line-width" "extend")

/-- Extend cycles terminate, and say so. -/
private def testExtendCycle (ctx : Ctx) : IO Unit := do
  let cyc := ctx.work / "cycle"
  newProject ctx cyc
  writeFile (cyc / "A.lean") "module\n"
  writeFile (cyc / "a.toml") "extend = \"b.toml\"\n"
  writeFile (cyc / "b.toml") "extend = \"a.toml\"\n"
  writeFile (cyc / ".lean-fmt.toml") "extend = \"a.toml\"\n"
  let result ← runProc ctx.application #["check", "--root", cyc.toString, "--no-cache"]
  ensureEq "an extend cycle fails rather than hanging" 2 result.exitCode
  let combined := (result.stdout ++ result.stderr).toLower
  ensure (combined.contains "cycle") "the cycle error does not name the cycle"

/-- Symlinks: the walk is finite, a symlinked source collapses onto its target, and a symlink out
of the root is dropped. -/
private def testSymlinks (ctx : Ctx) : IO Unit := do
  let sym := ctx.work / "symlink"
  newProject ctx sym
  IO.FS.createDirAll (sym / "real")
  IO.FS.createDirAll (sym / "dir")
  writeFile (sym / "real" / "Real.lean") "module\n"
  writeFile (sym / "dir" / "Dir.lean") "module\n"
  -- A symlinked *file* inside the tree, and a directory symlink pointing at its own ancestor.
  discard <| expectExit 0 "ln file" "ln" #["-s", "../real/Real.lean", (sym / "dir" / "Link.lean").toString]
  discard <| expectExit 0 "ln loop" "ln" #["-s", "..", (sym / "dir" / "loop").toString]
  writeFile (ctx.work / "outside.lean") "module\n"
  -- A symlink whose target is outside the root.
  discard <| expectExit 0 "ln outside" "ln"
    #["-s", (ctx.work / "outside.lean").toString, (sym / "Outside.lean").toString]
  let symSelected ← selected ctx sym
  -- The walk does not descend into directory symlinks, so a loop terminates and contributes
  -- nothing. That is the property worth pinning: not that symlinks are "handled", but that the
  -- walk is finite.
  ensure (!(symSelected.any (·.contains "loop")))
    "the walk descended into a directory symlink loop"
  -- A symlinked source resolves to its target and is reported once, under the target's own path
  -- -- not twice under both names. Processing it twice would mean two writes to one file.
  ensureEq "a symlinked source collapses onto its target rather than duplicating it"
    ["dir/Dir.lean", "lakefile.lean", "real/Real.lean"] symSelected
  let linkShow ← showConfig ctx sym (sym / "dir" / "Link.lean")
  let some relative := (linkShow.getObjValAs? String "relativePath").toOption
    | throw <| IO.userError "symlink: no relativePath"
  ensureEq "the symlink's own path resolves to the target it points at" "real/Real.lean" relative
  -- A symlink out of the root resolves to its target, and the target is outside the project.
  -- Discovering it would mean a no-arg `format` writes outside the tree it was pointed at, so the
  -- walk drops it and `config showConfig` reports gate 1 -- the same floor `.lake` sits behind.
  ensureEq "a symlink whose target is outside the root is gate 1" 1
    (← gate (← showConfig ctx sym (sym / "Outside.lean")) "symlink")

/-- Ignore sources: `.gitignore` (dir and glob), `.git/info/exclude`, `.ignore`, a nearer
negation, and the master switch. -/
private def testIgnoreSources (ctx : Ctx) : IO Unit := do
  let ign := ctx.work / "ignore"
  newProject ctx ign
  IO.FS.createDirAll (ign / ".git" / "info")
  for dir in ["build", "keep", "dot"] do
    IO.FS.createDirAll (ign / dir)
  writeFile (ign / ".git" / "HEAD") "ref: refs/heads/main\n"
  for file in ["build/Built.lean", "keep/Keep.lean", "keep/Scratch.tmp.lean", "dot/Dot.lean",
      "Excluded.lean"] do
    writeFile (ign / file) "module\n"
  writeFile (ign / ".gitignore") "build/\n*.tmp.lean\n"
  writeFile (ign / ".git" / "info" / "exclude") "Excluded.lean\n"
  writeFile (ign / ".ignore") "dot/\n"
  ensureEq "every ignore source prunes (.gitignore dir, .gitignore glob, info/exclude, .ignore)"
    ["keep/Keep.lean", "lakefile.lean"] (← selected ctx ign)
  writeFile (ign / "keep" / ".gitignore") "!*.tmp.lean\n"
  ensureEq "a nearer .gitignore negation re-includes a file the outer one excluded"
    ["keep/Keep.lean", "keep/Scratch.tmp.lean", "lakefile.lean"] (← selected ctx ign)
  writeFile (ign / ".lean-fmt.toml") "respect-gitignore = false\n"
  ensureEq "respect-gitignore = false turns every git source off at once" 6
    (← selected ctx ign).length
  IO.FS.removeFile (ign / ".lean-fmt.toml")
  let ignShow ← showConfig ctx ign (ign / "keep" / "Keep.lean")
  let sources := ((jsonAt? ignShow [.field "ignoreSources"]).bind (·.getArr?.toOption)
    |>.getD #[]).filterMap (·.getStr?.toOption)
  ensure (sources.any (·.endsWith "keep/.gitignore"))
    "config showConfig did not list the keep/.gitignore source in force"
  ensure (sources.any (·.endsWith "info/exclude"))
    "config showConfig did not list the info/exclude source in force"

/-- Explicit paths and force-exclude. -/
private def testExplicitPaths (ctx : Ctx) : IO Unit := do
  let exp := ctx.work / "explicit"
  newProject ctx exp
  IO.FS.createDirAll (exp / "vendor")
  writeFile (exp / "vendor" / "Vendor.lean") "module\n"
  writeFile (exp / "Own.lean") "module\n"
  writeFile (exp / ".lean-fmt.toml") "exclude = [\"vendor\"]\n"
  ensureEq "an excluded directory is absent from a no-arg run" ["Own.lean", "lakefile.lean"]
    (← selected ctx exp)
  ensureEq "an explicitly named excluded path is still processed" ["vendor/Vendor.lean"]
    (← selected ctx exp #[(exp / "vendor" / "Vendor.lean").toString])
  writeFile (exp / ".lean-fmt.toml") "exclude = [\"vendor\"]\nforce-exclude = true\n"
  ensureEq "force-exclude applies exclusion to explicitly named paths too" ([] : List String)
    (← selected ctx exp #[(exp / "vendor" / "Vendor.lean").toString])
  -- `include` is a discovery filter, and `force-exclude` must not silently promote it into a
  -- filter on explicit paths -- those are different questions, and conflating them would surprise
  -- a user who named a file outside `include` on purpose.
  writeFile (exp / ".lean-fmt.toml") "include = [\"Own.lean\"]\nforce-exclude = true\n"
  ensureEq "force-exclude does not make include reject an explicitly named path"
    ["vendor/Vendor.lean"] (← selected ctx exp #[(exp / "vendor" / "Vendor.lean").toString])

/-- Migration warnings: a flat linter key still works and warns once; the same key set flat and
under `[lint]` is a hard error. -/
private def testMigration (ctx : Ctx) : IO Unit := do
  let mig := ctx.work / "migrate"
  newProject ctx mig
  writeFile (mig / "M.lean") "module\n"
  writeFile (mig / ".lean-fmt.toml") "select = [\"security\"]\n"
  let result ← expectExit 0 "migration check" ctx.application
    #["check", "--root", mig.toString, "--json", "--no-cache"]
  ensure (result.stderr.contains "select") "a flat linter key produced no deprecation notice"
  let notices := (result.stderr.splitOn "\n").filter (·.contains "deprecat")
  ensureEq "the notice is emitted once, not once per file" 1 notices.length
  writeFile (mig / ".lean-fmt.toml") "select = [\"security\"]\n[lint]\nselect = [\"all\"]\n"
  let both ← runProc ctx.application #["check", "--root", mig.toString, "--no-cache"]
  ensureEq "the same key set flat and under [lint] is a hard error" 2 both.exitCode

/-- Introspection is deterministic and read-only. -/
private def testIntrospection (ctx : Ctx) : IO Unit := do
  let nested := ctx.work / "nested"
  let target := nested / "lib" / "deep" / "Deep.lean"
  let first ← showConfig ctx nested target
  let second ← showConfig ctx nested target
  ensureEq "two config showConfig invocations agree byte for byte" first.compress second.compress
  let digestAll : IO String := do
    let mut rows : Array String := #[]
    for entry in ← nested.walkDir do
      if entry.extension == some "lean" || entry.extension == some "toml" then
        rows := rows.push (entry.toString ++ "=" ++ (← sha256 entry))
    return ";".intercalate (rows.qsort (· < ·)).toList
  let before ← digestAll
  discard <| showConfig ctx nested target
  let after ← digestAll
  ensureEq "config showConfig wrote nothing" before after

/-- One profiling line from stderr: `phase.discovery_ms=N`. -/
private def discoveryMs (stderr : String) (label : String) : IO Nat := do
  for line in stderr.splitOn "\n" do
    if line.startsWith "phase.discovery_ms=" then
      match (line.drop "phase.discovery_ms=".length).toString.toNat? with
      | some n => return n
      | none => throw <| IO.userError s!"{label}: unparsable profiling line {line}"
  throw <| IO.userError s!"{label}: no discovery_ms profiling line"

/-- Large-tree discovery timing. Timing goes through `config showConfig`, not `check`, on purpose:
`config showConfig` runs discovery and nothing else. A `check` over the same tree takes minutes, but
essentially none of that is the walk — measuring through `check` would report that cost as if
discovery had caused it. -/
private def testLargeTree (ctx : Ctx) : IO Unit := do
  let big := ctx.work / "big"
  newProject ctx big
  -- 1,000 sources across 100 directories, 10 nested configs, and a 200-file ignored subtree:
  -- enough for the walk to dominate any fixed cost, and shaped like a real project.
  for d in [0:100] do
    -- Zero-padded, as the old generator named them.
    let directory := big / s!"pkg{(if d / 20 < 10 then "0" else "")}{d / 20}" /
      s!"mod{(if d < 10 then "00" else if d < 100 then "0" else "")}{d}"
    IO.FS.createDirAll directory
    for f in [0:10] do
      writeFile (directory / s!"F{f}.lean") "module\n"
    if d % 10 == 0 then
      writeFile (directory / ".lean-fmt.toml") "[format]\nline-width = 80\n"
  IO.FS.createDirAll (big / "ignored")
  for f in [0:200] do
    writeFile (big / "ignored" / s!"I{f}.lean") "module\n"
  writeFile (big / ".gitignore") "ignored/\n"
  let deepTarget := big / "pkg04" / "mod099" / "F9.lean"
  let profileEnv := #[("LEAN_FMT_PROFILE_PHASES", some "1")]
  let deepRun ← expectExit 0 "deep config showConfig" ctx.application
    #["config", "show", deepTarget.toString, "--root", big.toString, "--json"] (env := profileEnv)
  let deep ← parseJson deepRun.stdout "deep"
  ensureEq "the walk reaches the deepest directory of a 1,200-file tree" 0 (← gate deep "deep")
  -- `mod090` carries a config and `mod099` does not. They are siblings, so `mod099` falls back to
  -- the root -- it must not pick up its neighbor's width.
  ensureEq "a directory with its own config uses it" "80"
    (← setting (← showConfig ctx big (big / "pkg04" / "mod090" / "F0.lean")) "format.line-width" "big")
  ensureEq "a sibling directory without one falls back to the root, not to its neighbor" "100"
    (← setting deep "format.line-width" "big")
  ensureEq "the ignored 200-file subtree is pruned at scale" 2
    (← gate (← showConfig ctx big (big / "ignored" / "I0.lean")) "big")
  let discoveryMillis ← discoveryMs deepRun.stderr "big"
  IO.println s!"   info discovery over 1,200 files with 10 nested configs: {discoveryMillis} ms"
  -- A bound, not a benchmark. The claim RCD-FINAL owes is that one walk is not on the critical
  -- path; a walk per file would be. The threshold is loose so this fails on a design regression
  -- rather than on a slow machine.
  ensure (discoveryMillis < 2000)
    s!"discovery took {discoveryMillis}ms over 1,200 files -- suspect a walk per file"
  -- The symlink loop and the large tree together: a walk that followed directory symlinks would
  -- multiply this tree by the loop depth.
  discard <| expectExit 0 "ln loop" "ln" #["-s", "..", (big / "pkg04" / "loop").toString]
  let loopRun ← expectExit 0 "loop config showConfig" ctx.application
    #["config", "show", deepTarget.toString, "--root", big.toString, "--json"] (env := profileEnv)
  let loopMillis ← discoveryMs loopRun.stderr "loop"
  IO.println s!"   info discovery over the same tree with a symlink loop in it: {loopMillis} ms"
  ensure (loopMillis < 2000)
    s!"a symlink loop multiplied the walk ({loopMillis}ms) -- directory symlinks are being followed"

end Discovery

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  withTempDir fun work => do
    let ctx : Discovery.Ctx :=
      { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, work }
    let cases : Array Case := #[
      { name := "nested-workspaces", run := Discovery.testNested ctx },
      { name := "extend", run := Discovery.testExtend ctx },
      { name := "extend-cycle", run := Discovery.testExtendCycle ctx },
      { name := "symlinks", run := Discovery.testSymlinks ctx },
      { name := "ignore-sources", run := Discovery.testIgnoreSources ctx },
      { name := "explicit-paths", run := Discovery.testExplicitPaths ctx },
      { name := "migration", run := Discovery.testMigration ctx },
      { name := "introspection", run := Discovery.testIntrospection ctx },
      { name := "large-tree", run := Discovery.testLargeTree ctx }
    ]
    runCases "discovery" cases args
