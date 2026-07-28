module

public import Test

/-!
# The imports suite

Port of `tests/imports/run.sh`. The import-rule pipeline end-to-end: the three
`imports`-category diagnostics and the opt-in organizer, on committed module fixtures. The unit
tier pins the pure header rules and the organizer function; this pins the whole CLI path — read,
normalize, parse the surface header, merge fresh import findings (FMT004 via the live Lake graph),
select, report, and — for the organizer and `fix` — validate the rewrite by re-elaboration before
writing.

Import findings are computed fresh every run and never cached (FMT003/005 are pure over the file,
but FMT004 reads *other* files through the graph), so these fixtures use the exact-frontend
fallback (`LEAN_FMT_DISABLE_ARTIFACT` + `LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE`): the analyzer
runs, but the import layer is orthogonal to it.

Lane: workspace — the suite clears the root cache and edits committed fixtures in place (restoring
them, bytes and mtime, via `cp -p` backups; the final case asserts the sources came back exactly).
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace Imports

structure Ctx where
  root : System.FilePath
  application : String
  work : System.FilePath

private def fallbackEnv : Array (String × Option String) :=
  #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"), ("LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE", some "1")]

private def checkJson (ctx : Ctx) (expected : UInt32) (args : Array String) (label : String)
    (fallback : Bool := true) : IO Lean.Json := do
  let result ← expectExit expected label ctx.application args (cwd? := some ctx.root)
    (env := if fallback then fallbackEnv else #[])
  parseJson result.stdout label

private def oneFile (report : Lean.Json) (label : String) : IO Lean.Json := do
  let some file := jsonAt? report [.field "files", .index 0]
    | throw <| IO.userError s!"{label}: report has no file"
  return file

private def codesOf (file : Lean.Json) : Array String :=
  (((jsonAt? file [.field "findings"]).bind (·.getArr?.toOption)).getD #[]).map fun finding =>
    (finding.getObjValAs? String "code").toOption.getD ""

/-- `cp -p` — bytes and mtime, so the end-of-suite metadata snapshot sees the fixtures exactly as
committed. -/
private def cpPreserve (source destination : System.FilePath) (label : String) : IO Unit := do
  discard <| expectExit 0 label "cp" #["-p", source.toString, destination.toString]

/-- Run `action` against the committed fixture at `path`, restoring bytes and mtime afterwards
even when the action throws. -/
private def withRestored (ctx : Ctx) (path : System.FilePath) (action : IO Unit) : IO Unit := do
  let backup := ctx.work / (path.fileName.getD "fixture" ++ ".backup")
  cpPreserve path backup "backup"
  let result ← try
      action
      pure (Except.ok ())
    catch error =>
      pure (Except.error error)
  cpPreserve backup path "restore"
  match result with
  | .ok () => pure ()
  | .error error => throw error

/-- The committed fixtures this suite may never leave modified. -/
private def sources : Array String := #[
  "tests/imports/Duplicate.lean", "tests/imports/Ordering.lean",
  "tests/imports/Suppressed.lean"
]

/-- sha256 + mtime for the metadata snapshot. -/
private def snapshot (root : System.FilePath) : IO (Array (String × String × Int × UInt32)) := do
  let mut rows := #[]
  for name in sources do
    let path := root / name
    let hash ← sha256 path
    let modified := (← path.metadata).modified
    rows := rows.push (name, hash, modified.sec, modified.nsec)
  return rows

/-- FMT003: an exact duplicate fires once with a safe fix; nothing is withheld. -/
private def testDuplicate (ctx : Ctx) : IO Unit := do
  let report ← checkJson ctx 1
    #["check", "--root", ".", "--json", "--no-cache", "--select", "imports",
      "tests/imports/Duplicate.lean"] "duplicate"
  let file ← oneFile report "duplicate"
  ensure (((file.getObjValAs? String "status").toOption) == some "findings")
    "duplicate: status changed"
  let findings := ((jsonAt? file [.field "findings"]).bind (·.getArr?.toOption)).getD #[]
  let codes := findings.toList.map fun finding =>
    ((finding.getObjValAs? String "code").toOption.getD "",
      ((jsonAt? finding [.field "fix", .field "applicability"]).bind (·.getStr?.toOption)).getD "")
  ensureEq "duplicate: findings changed" [("FMT003", "safe")] codes

/-- FMT005: two imports out of order in one group; report-only (no fix in the finding). -/
private def testOrdering (ctx : Ctx) : IO Unit := do
  let report ← checkJson ctx 1
    #["check", "--root", ".", "--json", "--no-cache", "--select", "imports",
      "tests/imports/Ordering.lean"] "ordering"
  let file ← oneFile report "ordering"
  ensureEq "ordering: findings changed" ["FMT005"] (codesOf file).toList
  for finding in ((jsonAt? file [.field "findings"]).bind (·.getArr?.toOption)).getD #[] do
    ensure ((jsonAt? finding [.field "fix"]).isNone) "ordering: FMT005 carries a fix -- it must not"

/-- FMT004 fires on what a dependent can actually see, and on nothing else.

Both arms import `Demo.Base` alongside a module that imports it too. `Demo.Exported` re-exports it
with `public import`, so dropping the direct import would change nothing and the candidate is real.
`Demo.Private` does not, so `Base` is invisible through it and dropping the direct import would
break the build.

**The silent arm is the one that matters.** The rule asked Lake for `transImports`, which is the
*build* closure and takes every import regardless of `public` — so it reported the private arm too.
That is not a corner case: `tests/Test/Unit/Cases.lean` carried two `ignore[FMT004]` directives for
exactly this, with a comment admitting the rule was over-approximating, and this repository's own
tree could not be linted clean without them.

Its own project, because the shape needs a `public import` and no module under `LeanFmt/` uses one —
which is also why the old fixture (two repository modules, one transitively importing the other)
asserted a false positive and passed. -/
private def testRedundant (ctx : Ctx) : IO Unit := do
  let project := ctx.work / "visibility"
  IO.FS.createDirAll (project / "Demo")
  copyFile (ctx.root / "lean-toolchain") (project / "lean-toolchain")
  writeFile (project / "lakefile.lean")
    "import Lake\n\nopen Lake DSL\n\npackage \"visibility\"\n\nlean_lib Demo where\n  \
     globs := #[.submodules `Demo]\n"
  writeFile (project / "Demo" / "Base.lean") "module\n\npublic def base : Nat := 1\n"
  -- The two covering modules differ in one keyword, and that keyword is the whole test.
  writeFile (project / "Demo" / "Exported.lean")
    "module\n\npublic import Demo.Base\n\npublic def exported : Nat := base\n"
  writeFile (project / "Demo" / "Private.lean")
    "module\n\nimport Demo.Base\n\npublic def hidden : Nat := base\n"
  writeFile (project / "Demo" / "ViaExported.lean")
    "module\n\nimport Demo.Base\nimport Demo.Exported\n\npublic def viaExported : Nat := base\n"
  writeFile (project / "Demo" / "ViaPrivate.lean")
    "module\n\nimport Demo.Base\nimport Demo.Private\n\npublic def viaPrivate : Nat := base\n"
  let select := #["check", "--root", project.toString, "--json", "--no-cache", "--select", "imports"]
  let reported ← checkJson ctx 1 (select ++ #[(project / "Demo" / "ViaExported.lean").toString])
    "redundant-exported"
  let file ← oneFile reported "redundant-exported"
  ensureEq "redundant: a re-exported import was not reported" ["FMT004"] (codesOf file).toList
  for finding in ((jsonAt? file [.field "findings"]).bind (·.getArr?.toOption)).getD #[] do
    ensure ((jsonAt? finding [.field "fix"]).isNone) "redundant: FMT004 carries a fix -- it must not"
  ensureJsonAt reported [.field "withheldRedundant"] (Lean.toJson (0 : Nat)) "redundant-exported"
  let silent ← checkJson ctx 0 (select ++ #[(project / "Demo" / "ViaPrivate.lean").toString])
    "redundant-private"
  ensureEq "redundant: a privately-imported module was reported as reachable" ([] : List String)
    (codesOf (← oneFile silent "redundant-private")).toList

/-- Selection is honored: `--select FMT003` on the out-of-order fixture reports nothing (FMT005 is
not selected), proving import codes flow through the same selection projection as any rule. -/
private def testSelection (ctx : Ctx) : IO Unit := do
  let report ← checkJson ctx 0
    #["check", "--root", ".", "--json", "--no-cache", "--select", "FMT003",
      "tests/imports/Ordering.lean"] "selection"
  let file ← oneFile report "selection"
  ensureEq "selection: findings changed" ([] : List String) (codesOf file).toList

/-- The organizer, dry run: `--check` reports a pending change and exits 1 without touching the
file. -/
private def testOrganizeDryRun (ctx : Ctx) : IO Unit := do
  let report ← checkJson ctx 1
    #["organize", "--check", "--root", ".", "--json", "tests/imports/Ordering.lean"]
    "organize-check" (fallback := false)
  ensureJsonAt report [.field "mode"] (Lean.toJson "organize") "organize-check"
  let file ← oneFile report "organize-check"
  ensure (((file.getObjValAs? String "status").toOption) == some "would-organize")
    "organize-check: status changed"
  ensureJsonAt report [.field "written"] (Lean.toJson (0 : Nat)) "organize-check"

/-- The organizer, write: sort the group by module name, validated by re-elaboration, then
restore. -/
private def testOrganizeWrite (ctx : Ctx) : IO Unit := do
  let path := ctx.root / "tests" / "imports" / "Ordering.lean"
  withRestored ctx path do
    let report ← checkJson ctx 0
      #["organize", "--root", ".", "--json", "tests/imports/Ordering.lean"] "organize-write"
      (fallback := false)
    let file ← oneFile report "organize-write"
    ensure (((file.getObjValAs? String "status").toOption) == some "organized")
      "organize-write: status changed"
    ensureJsonAt report [.field "written"] (Lean.toJson (1 : Nat)) "organize-write"
    let imports := (← IO.FS.readFile path).splitOn "\n" |>.filter (·.startsWith "import ")
    ensureEq "organize-write: sorted group changed"
      ["import LeanFmt.Basic", "import LeanFmt.Digest"] imports

/-- `fix` applies the FMT003 safe dedup through the canonical patch (the printer keeps the
duplicate, so the fix is recomputed at canonical coordinates), validated and written; then
restore. -/
private def testFixDedup (ctx : Ctx) : IO Unit := do
  let path := ctx.root / "tests" / "imports" / "Duplicate.lean"
  withRestored ctx path do
    let report ← checkJson ctx 0
      #["fix", "--root", ".", "--json", "--no-cache", "--select", "imports",
        "tests/imports/Duplicate.lean"] "fix-dedup" (fallback := false)
    let file ← oneFile report "fix-dedup"
    ensure (((file.getObjValAs? String "status").toOption) == some "fixed")
      "fix-dedup: status changed"
    ensureJsonAt report [.field "written"] (Lean.toJson (1 : Nat)) "fix-dedup"
    let imports := (← IO.FS.readFile path).splitOn "\n" |>.filter (·.startsWith "import ")
    ensureEq "fix-dedup: deduped group changed" ["import LeanFmt.Basic"] imports

/-- Suppression composes with the import layer: a trailing `ignore[FMT003]` on the duplicate line
suppresses the import finding through the same post-cache projection every rule flows through. -/
private def testSuppressionComposes (ctx : Ctx) : IO Unit := do
  let report ← checkJson ctx 0
    #["check", "--root", ".", "--json", "--no-cache", "--select", "imports",
      "tests/imports/Suppressed.lean"] "suppressed"
  let file ← oneFile report "suppressed"
  ensure (((file.getObjValAs? String "status").toOption) == some "clean")
    "suppressed: status changed"
  ensureEq "suppressed: findings changed" ([] : List String) (codesOf file).toList
  ensureJsonAt report [.field "suppressed"] (Lean.toJson (1 : Nat)) "suppressed"

/-- Order is elaboration-significant, so the default `fix` must NEVER reorder a header — FMT005
carries no fix, and only the explicit `organize` command rewrites. -/
private def testFixNeverReorders (ctx : Ctx) : IO Unit := do
  let path := ctx.root / "tests" / "imports" / "Ordering.lean"
  withRestored ctx path do
    discard <| checkJson ctx 0
      #["fix", "--root", ".", "--json", "--no-cache", "tests/imports/Ordering.lean"]
      "fix-noreorder"
    let imports := (← IO.FS.readFile path).splitOn "\n" |>.filter (·.startsWith "import ")
    ensureEq "fix reordered the header -- it must never"
      ["import LeanFmt.Digest", "import LeanFmt.Basic"] imports

/-- The split, on the load-bearing FMT003 regression: a file with a duplicate import AND trailing
whitespace. `fix` removes the duplicate at original coordinates and leaves the whitespace (layout
is not fix's job); `format` trims the whitespace and keeps both imports (it applies no fix). The
seed file lives in the scratch dir, under the project root as `fix` requires. -/
private def testFixFormatSplit (ctx : Ctx) : IO Unit := do
  let conflict := ctx.work / "fixconflict.lean"
  let seed : IO Unit :=
    writeFile conflict
      "module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n\ndef importFixConflictNoop : Nat := 0  \n"
  seed
  let fixReport ← checkJson ctx 0
    #["fix", "--root", ".", "--json", "--no-cache", conflict.toString] "fix-conflict"
  let fixFile ← oneFile fixReport "fix-conflict"
  ensure (((fixFile.getObjValAs? String "status").toOption) == some "fixed")
    "fix-conflict: status changed"
  ensureJsonAt fixReport [.field "written"] (Lean.toJson (1 : Nat)) "fix-conflict"
  let afterFix ← IO.FS.readFile conflict
  let fixImports := afterFix.splitOn "\n" |>.filter (·.startsWith "import ")
  ensureEq "fix-conflict: FMT003 fix not applied at original coordinates"
    ["import LeanFmt.Basic"] fixImports
  ensure (afterFix.endsWith "0  \n") "fix-conflict: fix touched the layout -- it must not"
  seed
  let formatReport ← checkJson ctx 1
    #["format", "--check", "--root", ".", "--json", "--no-cache", conflict.toString]
    "format-conflict"
  let formatFile ← oneFile formatReport "format-conflict"
  ensure (((formatFile.getObjValAs? String "status").toOption) == some "would-format")
    "format-conflict: status changed"
  let out := (formatFile.getObjValAs? String "formatted").toOption.getD ""
  let formatImports := out.splitOn "\n" |>.filter (·.startsWith "import ")
  ensureEq "format-conflict: format applied a fix -- it must not"
    ["import LeanFmt.Basic", "import LeanFmt.Basic"] formatImports
  ensure (!(out.contains "  \n")) "format-conflict: layout not trimmed"
  ensure (codesOf formatFile |>.contains "FMT003") "format-conflict: FMT003 not reported"

/-- The metadata snapshot: every committed source the suite touched came back byte- and
mtime-identical. -/
private def testSourcesUnchanged (ctx : Ctx) (before : Array (String × String × Int × UInt32)) :
    IO Unit := do
  ensureEq "the suite left a committed source modified" before.toList (← snapshot ctx.root).toList

end Imports

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  removeDirAll? (root / ".lean-fmt-cache")
  withScratchDir "imports" fun work => do
    let ctx : Imports.Ctx :=
      { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, work }
    let before ← Imports.snapshot root
    let cases : Array Case := #[
      { name := "duplicate-fmt003", run := Imports.testDuplicate ctx },
      { name := "ordering-fmt005", run := Imports.testOrdering ctx },
      { name := "redundant-fmt004", run := Imports.testRedundant ctx },
      { name := "selection-honored", run := Imports.testSelection ctx },
      { name := "organize-dry-run", run := Imports.testOrganizeDryRun ctx },
      { name := "organize-write", run := Imports.testOrganizeWrite ctx },
      { name := "fix-dedup", run := Imports.testFixDedup ctx },
      { name := "suppression-composes", run := Imports.testSuppressionComposes ctx },
      { name := "fix-never-reorders", run := Imports.testFixNeverReorders ctx },
      { name := "fix-format-split", run := Imports.testFixFormatSplit ctx },
      { name := "sources-unchanged", run := Imports.testSourcesUnchanged ctx before }
    ]
    runCases "imports" cases args
