module

public import Test

/-!
# The suppression suite

Port of `tests/suppression/run.sh`: end-to-end acceptance for the source-suppression layer
(`RSP-FINAL`), driving the real CLI over committed fixtures parsed by the real frontend — nested
syntax, doc comments, custom commands, formatting movement, unknown rules, per-file config, and
unused fixes. Where the unit tier's `testSuppression` checks `apply`/`collect` against a hand-built
projection, this is the acceptance matrix.

The retired-only-suppression case of the old script is deliberately absent, for the reason its own
comment recorded: the pre-release renumbering made FMT001 a live security rule and emptied
`reservedCodes`, so a directive naming it is a live-but-not-firing code — FMT900, the opposite of
what the case asserted. The fixture went with it; the production branch is untested until a rule
genuinely retires.

Lane: workspace. The preamble clears the root `.lean-fmt-cache`, which other suites use.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace Suppression

/-- One CLI run expecting `expected`, parsed as JSON. -/
private def runJson (root : System.FilePath) (application : String) (expected : UInt32)
    (cliArgs : Array String) (label : String) : IO Lean.Json := do
  let result ← expectExit expected label application cliArgs (cwd? := some root)
  parseJson result.stdout label

/-- A `check` against repo-relative fixtures. -/
private def checkJson (root : System.FilePath) (application : String) (expected : UInt32)
    (fixtures : Array String) (label : String) (extra : Array String := #[]) : IO Lean.Json :=
  runJson root application expected
    (#["check", "--root", ".", "--json", "--no-cache"] ++ extra ++ fixtures) label

/-- The single selected file of a report. -/
private def oneFile (report : Lean.Json) (label : String) : IO Lean.Json := do
  let some files := (jsonAt? report [.field "files"]).bind (·.getArr?.toOption)
    | throw <| IO.userError s!"{label}: report has no files"
  let some file := files[0]?
    | throw <| IO.userError s!"{label}: report has no file"
  ensure (files.size == 1) s!"{label}: report selected {files.size} files"
  return file

private def codesOf (file : Lean.Json) : Array String :=
  (((jsonAt? file [.field "findings"]).bind (·.getArr?.toOption)).getD #[]).map fun finding =>
    (finding.getObjValAs? String "code").toOption.getD ""

private def findingsOf (file : Lean.Json) : Array Lean.Json :=
  ((jsonAt? file [.field "findings"]).bind (·.getArr?.toOption)).getD #[]

/-- Doc comments and module docstrings are tokens, not comments: directive text in them is inert.
The FMT003 duplicate-import finding must still report; suppressed stays 0. -/
private def testDocCommentInert (root : System.FilePath) (application : String) : IO Unit := do
  let report ← checkJson root application 1 #["tests/suppression/DocComment.lean"] "doc-comment"
  let file ← oneFile report "doc-comment"
  let codes := codesOf file
  ensure (codes.contains "FMT003") s!"a docstring silenced a real finding: {codes}"
  ensure (!(codes.any fun code => code == "FMT900" || code == "FMT901"))
    s!"docstring text parsed as a directive: {codes}"
  ensureJsonAt file [.field "suppressed"] (Lean.toJson (0 : Nat)) "doc-comment"

/-- Nested syntax: ignore-next inside a namespace suppresses the inner finding. The finding is a
redundant nested paren (FMT011, a syntax rule opted into with `--select`), since no default finding
lands on a `def` inside a namespace. -/
private def testNested (root : System.FilePath) (application : String) : IO Unit := do
  let report ← checkJson root application 0 #["tests/suppression/Nested.lean"] "nested"
    (extra := #["--preview", "--select", "FMT011"])
  let file ← oneFile report "nested"
  ensure (findingsOf file |>.isEmpty) "a nested ignore-next did not suppress"
  ensureJsonAt file [.field "suppressed"] (Lean.toJson (1 : Nat)) "nested"

/-- Custom command: file-local syntax + macro. ignore-file suppresses, and the custom command
round-trips. -/
private def testCustomCommand (root : System.FilePath) (application : String) : IO Unit := do
  let report ← checkJson root application 0 #["tests/suppression/Custom.lean"] "custom-command"
  let file ← oneFile report "custom-command"
  ensure (findingsOf file |>.isEmpty) "ignore-file left a finding on a custom command"
  let suppressed := (natAt? file [.field "suppressed"]).getD 0
  ensure (suppressed >= 1) s!"custom-command suppression miscounted: {suppressed}"

/-- Formatting movement + the round-trip invariant. `format` collapses the ignore-next item's
non-canonical spacing (a movement the printer owns, as `tests/modes` proves on `Layout.lean`) and
the directive comment round-trips exactly once; `fix` applies rule fixes only, so on this
finding-free file it is a no-op that leaves the layout byte-for-byte. The ignore-next covers a
namespace with no finding, so it is an honest FMT900 throughout. -/
private def testMovement (root : System.FilePath) (application : String)
    (work : System.FilePath) : IO Unit := do
  let scratch := work / "Movement.lean"
  copyFile (root / "tests" / "suppression" / "Movement.lean") scratch
  let original ← IO.FS.readFile scratch
  ensure ((original.splitOn "lean-fmt: ignore-next").length == 2) "movement fixture drifted"
  -- `format` reflows the item, and the directive survives the movement exactly once.
  let report ← runJson root application 1
    #["format", "--check", "--root", ".", "--json", "--no-cache", scratch.toString] "move-format"
  let file ← oneFile report "move-format"
  ensure ((file.getObjValAs? String "status").toOption == some "would-format")
    "move-format: status changed"
  let out := (file.getObjValAs? String "formatted").toOption.getD ""
  ensureContains out "namespace Beta\n" "move-format"
  ensure (!(out.contains "namespace     Beta")) "move-format: the item was not reflowed"
  ensure ((out.splitOn "lean-fmt: ignore-next").length == 2)
    "move-format: the directive did not round-trip exactly once"
  -- `fix` is a no-op: no rule finding here, and layout is not fix's job, so the file -- spacing
  -- and all -- is written zero times and left byte-for-byte.
  let fixRun ← expectExit 0 "move-fix" application
    #["fix", "--root", ".", "--no-cache", scratch.toString] (cwd? := some root)
  ensureContains fixRun.stdout "written=0" "move-fix"
  ensure ((← IO.FS.readFile scratch) == original) "fix reflowed the item -- it must not"
  -- The directive is unused (its item carries no finding): check reports a lone FMT900.
  let recheck ← checkJson root application 1 #[scratch.toString] "move-recheck"
  let refile ← oneFile recheck "move-recheck"
  ensureEq "directive is not a lone unused-directive report" ["FMT900"] (codesOf refile).toList

/-- Unused fixes. A blanket ignore over a clean file is FMT900 with a *safe* removal fix whose
edit deletes exactly the directive line and its newline — the editor code-action, never batch fix. -/
private def testUnusedFix (root : System.FilePath) (application : String) : IO Unit := do
  let report ← checkJson root application 1 #["tests/suppression/Unused.lean"] "unused-fix"
  let file ← oneFile report "unused-fix"
  let findings := findingsOf file
  let some find := findings[0]?
    | throw <| IO.userError "unused-fix: no findings"
  ensure (findings.size == 1) "unused-fix: more than one finding"
  ensure ((find.getObjValAs? String "code").toOption == some "FMT900")
    "a blanket ignore over a clean file is not FMT900"
  let some fix := jsonAt? find [.field "fix"] | throw <| IO.userError "unused-fix: no fix"
  ensure ((fix.getObjValAs? String "applicability").toOption == some "safe")
    "the removal fix is not safe"
  let some edits := (jsonAt? fix [.field "edits"]).bind (·.getArr?.toOption)
    | throw <| IO.userError "unused-fix: fix has no edits"
  let some edit := edits[0]? | throw <| IO.userError "unused-fix: no edit"
  ensure (edits.size == 1) "unused-fix: more than one edit"
  let source ← IO.FS.readFile (root / "tests" / "suppression" / "Unused.lean")
  let start := (natAt? edit [.field "range", .field "start"]).getD 0
  let stop := (natAt? edit [.field "range", .field "stop"]).getD 0
  let replacement := ((jsonAt? edit [.field "replacement"]).bind (·.getStr?.toOption)).getD ""
  let cut := String.Pos.Raw.extract source ⟨0⟩ ⟨start⟩ ++ replacement ++
    String.Pos.Raw.extract source ⟨stop⟩ ⟨source.utf8ByteSize⟩
  ensureEq "removal fix left a mess" "module\n\ndef unusedValue : Nat := 1\n" cut

/-- Malformed directive: an unknown verb is FMT901 [display-only], reported never dropped. -/
private def testMalformedDirective (root : System.FilePath) (application : String) : IO Unit := do
  let report ← checkJson root application 1 #["tests/suppression/Malformed.lean"] "malformed"
  let file ← oneFile report "malformed"
  let fmts := findingsOf file |>.filter fun finding =>
    (finding.getObjValAs? String "code").toOption == some "FMT901"
  let some find := fmts[0]?
    | throw <| IO.userError "malformed: no FMT901 finding"
  ensure (fmts.size == 1) "malformed: more than one FMT901"
  ensure (((jsonAt? find [.field "fix", .field "applicability"]).bind (·.getStr?.toOption)) ==
      some "display-only")
    "FMT901 is not display-only"
  let message := (find.getObjValAs? String "message").toOption.getD ""
  ensureContains message "ignor" "FMT901 did not name the bad verb"

/-- Per-file config composition. The config already ignores FMT003 for this glob, so the trailing
directive naming FMT003 suppresses nothing and is itself unused: the RUF100 analog composes with
config. -/
private def testPerFileConfig (root : System.FilePath) (application : String) : IO Unit := do
  let report ← checkJson root application 1 #["tests/suppression/PerFile.lean"] "per-file"
    (extra := #["--config", "tests/suppression/per-file-ignores.toml"])
  let file ← oneFile report "per-file"
  ensureEq "a config-redundant directive is not the lone FMT900" ["FMT900"] (codesOf file).toList
  ensureJsonAt file [.field "suppressed"] (Lean.toJson (0 : Nat)) "per-file"

end Suppression

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  removeDirAll? (root / ".lean-fmt-cache")
  withScratchDir "suppression" fun work => do
    let cases : Array Case := #[
      { name := "doc-comment-inert", run := Suppression.testDocCommentInert root application },
      { name := "nested", run := Suppression.testNested root application },
      { name := "custom-command", run := Suppression.testCustomCommand root application },
      { name := "movement", run := Suppression.testMovement root application work },
      { name := "unused-fix", run := Suppression.testUnusedFix root application },
      { name := "malformed-directive", run := Suppression.testMalformedDirective root application },
      { name := "per-file-config", run := Suppression.testPerFileConfig root application }
    ]
    runCases "suppression" cases args
