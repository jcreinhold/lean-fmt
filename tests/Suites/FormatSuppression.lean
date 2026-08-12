module

public import Test

/-!
# The format-suppression suite

`format-ignore-next` copies one complete unit and canonical formatting resumes; suppression is
idempotent at widths 20/100 and identical after CRLF normalization; the unit reaches back over a
comment written above the directive; header-spanning and unmatched formatter directives are
non-silent FMT901 findings; and a final file-owned Unicode comment survives exactly once.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace FormatSuppression

private def fixture : String :=
  "tests/fixtures/format-suppression/Suppressed.lean"

/-- Suppression at one width: the directive once, the preserved unit byte-for-byte, and formatting
resumed after it. -/
private def testWidth (root setup : System.FilePath) (application : String) (width : Nat) :
    IO Unit := do
  let report ← analyzeExact root application setup fixture "Suppressed.lean" s!"4:{width}"
  let (_, text) ← canonical report s!"width {width}"
  ensure ((text.splitOn "-- lean-fmt: format-ignore-next").length == 2)
      s!"width {width}: directive does not occur exactly once"
  ensureContains text "def preserved(alpha:Nat):Nat:=alpha+1" s!"width {width}"
  ensureContains text "def resumed" s!"width {width}"
  ensureContains text "beta + 1" s!"width {width}"

/-- CRLF normalization reproduces the LF render, and formatting after the suppressed unit is still
width-sensitive. -/
private def testCrlfAndWidths (root setup : System.FilePath) (application : String)
    (work : System.FilePath) : IO Unit := do
  let crlfPath := work / "crlf.lean"
  IO.FS.writeBinFile crlfPath ((← IO.FS.readFile (root / fixture)).replace "\n" "\r\n").toUTF8
  let crlfReport ← analyzeExact root application setup crlfPath.toString "Suppressed.lean" "4:100"
  let (_, crlfText) ← canonical crlfReport "CRLF"
  let wideReport ← analyzeExact root application setup fixture "Suppressed.lean" "4:100"
  let (_, wideText) ← canonical wideReport "width 100"
  ensure (crlfText == wideText) "LF/CRLF normalized suppression diverged"
  let narrowReport ← analyzeExact root application setup fixture "Suppressed.lean" "4:20"
  let (_, narrowText) ← canonical narrowReport "width 20"
  ensure (narrowText ≠ wideText) "formatting did not resume with width-sensitive layout"

/-- Header-spanning and unmatched formatter directives are non-silent FMT901 findings, one per
file, with the two distinct messages. -/
private def testMalformedDirectives (root : System.FilePath) (application : String) : IO Unit := do
  let result ←
    runProc application
        #["check", "--output-format", "json", "--root", ".",
          "tests/fixtures/format-suppression/Unmatched.lean",
          "tests/fixtures/format-suppression/Header.lean"]
        (cwd? := some root)
  let report ← parseJson result.stdout "malformed directives"
  let some files :=
    (jsonAt? report [.field "files"]).bind
      (·.getArr?.toOption) | throw <| IO.userError "malformed-directives report has no files"
  let findings :=
    files.foldl (init := #[]) fun acc file =>
      acc ++ ((jsonAt? file [.field "findings"]).bind (·.getArr?.toOption)).getD #[]
  let codes := findings.map fun finding => (finding.getObjValAs? String "code").toOption.getD ""
  ensureEq "malformed directives are not exactly two FMT901s" ["FMT901", "FMT901"] codes.toList
  let messages :=
    "\n".intercalate
      (findings.map fun finding => (finding.getObjValAs? String "message").toOption.getD "").toList
  ensureContains messages "cannot target the module/import header" "malformed directives"
  ensureContains messages "has no following ordinary unit" "malformed directives"

/-- A comment written *above* the directive belongs to the suppressed unit too. The unit runs from
the first comment the command owns, not from the directive, so an explanatory line in front of it is
carried through verbatim rather than left to a composer that never emits it.

A docstring cannot be written above the directive: it is a child of the declaration's syntax, so the
directive would sit inside the command's range instead of leading it, and `formatIgnoreNext?` would
not fire at all. It goes below, where it is part of the preserved bytes. -/
private def testLedDirective (root setup : System.FilePath) (application : String) : IO Unit := do
  let report ←
    analyzeExact root application setup "tests/fixtures/format-suppression/LedDirective.lean"
        "LedDirective.lean" "4:100"
  let (_, text) ← canonical report "led-directive"
  ensureContains text
      "-- Why this shape is preserved, written above the directive rather than \
below it."
      "led-directive"
  ensureContains text "/-- The docstring belongs to the command, and is inside its syntax range. -/"
      "led-directive"
  ensureContains text "def ledPreserved(alpha:Nat):Nat:=alpha+1" "led-directive"
  -- The command after it is still laid out, so the unit stopped where it should have.
  ensureContains text "def ledResumed (beta : Nat) : Nat :=" "led-directive"

/-- A final file-owned Unicode comment survives exactly once. -/
private def testEofComment (root setup : System.FilePath) (application : String) : IO Unit := do
  let report ←
    analyzeExact root application setup "tests/fixtures/format-suppression/EofComment.lean"
        "EofComment.lean" "4:100"
  let (_, text) ← canonical report "eof-comment"
  ensure (text.endsWith "-- 𝔽𝔽 tail\n") "the final Unicode comment did not survive"

end FormatSuppression

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  withScratchDir "format-suppression" fun work => do
      let setup ← setupFile root work FormatSuppression.fixture
      let eofSetup ← setupFile root work "tests/fixtures/format-suppression/EofComment.lean"
      let ledSetup ← setupFile root work "tests/fixtures/format-suppression/LedDirective.lean"
      let cases : Array Case :=
        #[{ name := "width-20", run := FormatSuppression.testWidth root setup application 20 },
          { name := "width-100", run := FormatSuppression.testWidth root setup application 100 },
          { name := "crlf-and-widths",
            run := FormatSuppression.testCrlfAndWidths root setup application work },
          { name := "malformed-directives",
            run := FormatSuppression.testMalformedDirectives root application },
          { name := "led-directive",
            run := FormatSuppression.testLedDirective root ledSetup application },
          { name := "eof-comment",
            run := FormatSuppression.testEofComment root eofSetup application }]
      runCases "format-suppression" cases args
