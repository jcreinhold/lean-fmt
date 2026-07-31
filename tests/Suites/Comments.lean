module

public import Test

import all LeanFmt.Config

/-!
# The comments suite: actual-syntax comment ownership

Port of `tests/fixtures/comments/run.sh`. No projection-token attachment path is exercised here: the exact
frontend's live-syntax summary owns every payload exactly once — over a synthetic fixture covering
custom/macro/delimiter/terminal/suppression shapes, over the imported-syntax `LocalSyntax` fixture,
over CRLF normalization, and through structural comment layout at three widths.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace CommentsSuite

/-- The synthetic fixture: Unicode module documentation, a macro-generating custom command, nested
and inline blocks, doc comments, adjacent lines, a suppression scope, and a terminal tail. -/
private def ownershipSource : String :=
  "module\n\n/-! Unicode module documentation: λ → 外. -/\n\n\
  syntax \"comment_command\" ident : command\nmacro_rules\n  \
  | `(comment_command $name) => `(def $name : Nat := 0)\n\n\
  /- outer /- nested -/ comment -/\ncomment_command generated\n\n\
  /-- Declaration documentation. -/\ndef empty : List Nat := [ /- empty-container payload -/ ]\n\n\
  def trailing : Nat := 1 -- same-line payload\n\n\
  -- adjacent one\n-- adjacent two\ndef adjacent : Nat := 2\n\n\
  -- lean-fmt: ignore-next\ndef suppressed : Nat := /- payload inside suppression scope -/ 3\n\n\
  -- before terminal\n#exit\n-- verbatim tail, outside the parsed region\n"

/-- One summary run against the borrowed setup (the fixture defines its own syntax, so any clean
setup serves). -/
private def summarize (root : System.FilePath) (application : String) (setup : System.FilePath)
    (source display : String) : IO Lean.Json := do
  let report ← analyzeExact root application setup source display "3" (viaLakeEnv := true)
  commentSummary report display

/-- The summary's exact shape: counts plus the payload digest, pinned. -/
private def ensureSummary (summary : Lean.Json) (label : String)
    (comments leading trailing dangling suppressed : Nat) (digest : String) : IO Unit := do
  for (key, expected) in
    [("comments", comments), ("leading", leading), ("trailing", trailing), ("dangling", dangling),
      ("suppressed", suppressed)]do
    ensureJsonAt summary [.field key] (Lean.toJson expected) label
  ensureJsonAt summary [.field "payloadDigest"] (Lean.toJson digest) label

private def testOwnershipFixture (root : System.FilePath) (application : String)
    (work setup : System.FilePath) : IO Unit := do
  let fixture := work / "Ownership.lean"
  writeFile fixture ownershipSource
  let summary ← summarize root application setup fixture.toString "Ownership.lean"
  ensureSummary summary "ownership" 10 7 2 1 2
      "aeac5503e51c2284f134eaa98da9f9eafe18b2103a2bebc0261ea6b87a7510aa"

/-- CRLF normalization preserves the whole ownership summary, digest included. -/
private def testCrlfIdentical (root : System.FilePath) (application : String)
    (work setup : System.FilePath) : IO Unit := do
  let lf := work / "OwnershipLF.lean"
  let crlf := work / "OwnershipCRLF.lean"
  writeFile lf ownershipSource
  IO.FS.writeBinFile crlf (ownershipSource.replace "\n" "\r\n").toUTF8
  let left ← summarize root application setup lf.toString "OwnershipLF.lean"
  let right ← summarize root application setup crlf.toString "OwnershipCRLF.lean"
  ensure (left == right) "LF and CRLF summaries differ after normalization"

/-- Imported custom syntax, docstrings, nested comments, Unicode, and choice: the pinned summary
of `tests/fixtures/compiler/LocalSyntax.lean`. -/
private def testLocalSyntax (root : System.FilePath) (application : String)
    (work : System.FilePath) : IO Unit := do
  let setup ← setupFile root work "tests/fixtures/compiler/LocalSyntax.lean"
  let summary ←
    summarize root application setup "tests/fixtures/compiler/LocalSyntax.lean"
        "tests/fixtures/compiler/LocalSyntax.lean"
  ensureSummary summary "local-syntax" 6 5 1 0 0
      "e0e388ff4e428c9b7892288a3b908ae25640f0797eb1d18a1d17fc5cd99481e7"

/-- Structural comment layout across constructs, widths, and line endings: thirteen exact payloads
retain one logical owner through both of admission's readings of the module, and the contract is
width- and line-ending-stable. -/
private def testLayoutWidths (root : System.FilePath) (application : String)
    (work : System.FilePath) : IO Unit := do
  let setup ← setupFile root work "tests/fixtures/comments/Layout.lean"
  let summaryReport ←
    analyzeExact root application setup "tests/fixtures/comments/Layout.lean"
        "tests/fixtures/comments/Layout.lean" "3" (viaLakeEnv := true)
  let summary ← commentSummary summaryReport "layout"
  ensureSummary summary "layout" 13 8 5 0 0
      "274997ea206091bf77ee03b20c21942d8b31e495a8a687e0d93fd93e141a9a7d"
  let payloads :=
    ["/- before import -/", "/-! Module documentation remains one complete lexical command. -/",
      "/- before macro alternative -/", "/- between binders -/", "/- before operator -/",
      "/- before entry -/", "-- trailing tactic", "/- alternative comment -/", "-- leading item",
      "-- trailing item", "/- between items -/", "/- arm body -/", "/- local declaration -/"]
  let mut texts : Array String := #[]
  for width in [24, 60, 100]do
    let report ←
      analyzeExact root application setup "tests/fixtures/comments/Layout.lean"
          "tests/fixtures/comments/Layout.lean" s!"4:{width}"
    let (canonical, text) ← canonical report s!"layout width {width}"
    ensureJsonAt canonical [.field "metrics", .field "commentOwners"] (Lean.toJson (13 : Nat))
        s!"layout width {width}"
    for payload in payloads do
      ensure ((text.splitOn payload).length == 2)
          s!"layout width {width}: {payload} does not occur exactly once"
    ensure (text.startsWith "module\n\n/- before import -/\nimport Lean\n")
        s!"layout width {width}: header comment moved"
    ensureContains text "macro_rules\n  /- before macro alternative -/\n  |"
        s!"layout width {width}"
    texts := texts.push text
  -- CRLF at 60 must reproduce the LF render byte-for-byte.
  let crlfPath := work / "LayoutCRLF.lean"
  IO.FS.writeBinFile crlfPath
      ((← IO.FS.readFile (root / "tests" / "fixtures" / "comments" / "Layout.lean")).replace "\n"
          "\r\n").toUTF8
  let crlfSetup ← setupFile root work crlfPath.toString
  let crlfReport ←
    analyzeExact root application crlfSetup crlfPath.toString "LayoutCRLF.lean" "4:60"
  let (crlfCanonical, crlfText) ← canonical crlfReport "layout CRLF"
  ensure (crlfText == texts[1]!) "CRLF and LF renders differ"
  ensureJsonAt crlfCanonical [.field "metrics", .field "commentOwners"] (Lean.toJson (13 : Nat))
      "layout CRLF"
  ensure (texts[0]! ≠ texts[1]!) "configured width did not reflow the commented fixture"

/-- Import rows and their trailing comments (`tests/fixtures/comments/Imports.lean`). Import rows
never split — an import cannot be shortened, so a row over the width overflows whole, and mathlib's
longLine linter exempts whole import lines for exactly that reason (the native-layout suite's
mathlib-style case owns the never-break contract at widths 100 and 20). The comment half lives
here: at widths 100 and 50, and under `pinned-comments = []`, the fixture renders identically —
a trailing comment of any length, ordinary or pinned, rides its row untouched.

This case formerly pinned the opposite layout — over-width rows split one token per line, the
pinned `shake: keep` row held flat, and `pinned-comments = []` released it — until the
mathlib-style compliance change made import rows unbreakable and left these assertions stale.
That split was also the last breakable custom group: every non-header command renders as one
registered leaf whose breaks `Std.Format.prettyM` owns, so the `pinned-comments` hold/release
mechanism in `Doc.renderWork` has no group left to act on today. The width- and config-equality
pins below are the canaries: they fail if import rows ever become breakable again, which would
be a decision to make explicitly, not a regression to slip in. -/
private def testImportComments (root : System.FilePath) (application : String)
    (work : System.FilePath) : IO Unit := do
  let setup ← setupFile root work "tests/fixtures/comments/Imports.lean"
  let wide ←
    analyzeExact root application setup "tests/fixtures/comments/Imports.lean"
        "tests/fixtures/comments/Imports.lean" "4:100"
  let (_, wideText) ← canonical wide "import comments width 100"
  for row in
    ["public import Lean.Data.Json -- this trailing comment makes the line longer than one hundred characters and must not split the import row",
      "public import Lean.PrettyPrinter.Delaborator.FieldNotation -- shake: keep (required by artifact evidence for this module)",
      "public import Lean.PrettyPrinter.Delaborator.FieldNotation -- an ordinary comment"]do
    ensureContains wideText (row ++ "\n") s!"a trailing comment left its import row: {row}"
  let narrow ←
    analyzeExact root application setup "tests/fixtures/comments/Imports.lean"
        "tests/fixtures/comments/Imports.lean" "4:50"
  let (_, narrowText) ← canonical narrow "import comments width 50"
  ensure (narrowText == wideText) "width 50 reflowed an import row"
  let unpinned : LeanFmt.Internal.FormatConfig := { lineWidth := 50, pinnedComments := #[] }
  let released ←
    analyzeExact root application setup "tests/fixtures/comments/Imports.lean"
        "tests/fixtures/comments/Imports.lean" s!"4j{(Lean.toJson unpinned).compress}"
  let (_, releasedText) ← canonical released "import comments unpinned"
  ensure (releasedText == wideText) "pinned-comments = [] changed an import row"

end CommentsSuite

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  withScratchDir "comments" fun work => do
      let borrowedSetup ← setupFile root work "tests/fixtures/check/Clean.lean"
      let cases : Array Case :=
        #[{ name := "ownership-fixture",
            run := CommentsSuite.testOwnershipFixture root application work borrowedSetup },
          { name := "crlf-identical",
            run := CommentsSuite.testCrlfIdentical root application work borrowedSetup },
          { name := "local-syntax", run := CommentsSuite.testLocalSyntax root application work },
          { name := "layout-widths", run := CommentsSuite.testLayoutWidths root application work },
          { name := "import-comments",
            run := CommentsSuite.testImportComments root application work }]
      runCases "comments" cases args
