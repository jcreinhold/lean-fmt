module

public import Test

import all Test.Unit.Layout

/-!
# The layout suite: live-syntax comment ownership over real parsed modules

Port of `tests/layout/run.sh`. The exact frontend retains actual header, command, choice-selected,
and terminal syntax while it builds the ownership summary; this drives that path over the
repository's changing production corpus. The claim under test is the roadmap's "preserve every
comment exactly once", and it is decidable rather than aspirational: the live-syntax summary
validates one owner per independently extracted payload.

The suite absorbs the two subcommands the old script called: `doc-properties` (the unit tier's
`testDoc`) and `comment-summary` (decoded in-process from the analysis envelope).
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace LayoutSuite

/-- `find <root>/LeanFmt -name '*.lean'`, recursively, repo-relative. -/
private partial def collectModules (root dir : System.FilePath) (acc : Array String) :
    IO (Array String) := do
  let mut acc := acc
  for entry in ← dir.readDir do
    if ← entry.path.isDir then
      acc ← collectModules root entry.path acc
    else if entry.path.extension == some "lean" then
      acc := acc.push (entry.path.toString.drop (root.toString.length + 1)).toString
  return acc

/-- The `doc-properties` subcommand: the unit tier's document-properties case, run here too so the
suite stands alone. -/
private def testDocProperties : IO Unit := do
  match Unit.Layout.cases.find? (·.name == "testDoc") with
  | some docCase =>
    docCase.run
  | none =>
    throw <| IO.userError "the unit tier lost its testDoc case"

/-- Every production module, largest risk first (small modules first, so a regression surfaces
early): the ownership walk must validate everywhere, and the corpus must own enough comments that
the walk is proving something. -/
private def testCorpus (root : System.FilePath) (application : String) (work : System.FilePath) :
    IO Unit := do
  let modules₀ ← collectModules root (root / "LeanFmt") #[]
  let mut totalComments := 0
  let modules := (modules₀.qsort (· < ·)).push "Main.lean"
  let mut totalDangling := 0
  for module in modules do
    let setup ← LeanFmt.Test.Analyze.setupFile root work module
    let report ←
      LeanFmt.Test.Analyze.analyzeExact root application setup module module "3" (viaLakeEnv :=
          true)
    let summary ← commentSummary report module
    totalComments := totalComments + (natAt? summary [.field "comments"]).getD 0
    totalDangling := totalDangling + (natAt? summary [.field "dangling"]).getD 0
  IO.println
      s!"modules_checked={modules.size} comments_owned={totalComments} \
    dangling={totalDangling}"
  -- A floor rather than an exact count: a corpus that owned no comment would pass every assertion
  -- above while testing nothing. The number rises as the project is commented; only a broken walk
  -- drives it toward zero.
  ensure (totalComments >= 25)
      s!"corpus owned only {totalComments} comments; the walk is not finding them"

/-- Comment positions, on the real parser. Every corpus module reports `trailing=0` — this
repository puts its comments on their own lines — so the other positions need a fixture, and the
fixture borrows `tests/fixtures/check/Clean.lean`'s setup exactly as the old script did. The counts are
exact because each is a separate claim about the rule: three same-line comments trail (including
the newline-spanning block Lean's own `chooseNiceTrailStop` would tear in half), one own-line
comment leads, one past-the-last-token comment is file-dangling. -/
private def testPositions (root : System.FilePath) (application : String) (work : System.FilePath) :
    IO Unit := do
  let setup ← LeanFmt.Test.Analyze.setupFile root work "tests/fixtures/check/Clean.lean"
  let positions := work / "positions.lean"
  writeFile positions
      "module\n\ndef a : Nat := 0  -- trailing, same line as the token\n\n\
    -- leading, own line, before a declaration\ndef b : Nat := 1\n\n\
    def c : Nat := /- inline block -/ 2\n\ndef d : Nat := 3 /- block comment\nspanning a newline -/\n\n\
    -- dangling: past the last token, owned by no one\n"
  let report ←
    LeanFmt.Test.Analyze.analyzeExact root application setup positions.toString "positions.lean" "3"
        (viaLakeEnv := true)
  let summary ← commentSummary report "positions.lean"
  ensureJsonAt summary [.field "comments"] (Lean.toJson (5 : Nat))
      "every comment owned exactly once"
  ensureJsonAt summary [.field "trailing"] (Lean.toJson (3 : Nat))
      "same-line comments trail their syntax leaf"
  ensureJsonAt summary [.field "leading"] (Lean.toJson (1 : Nat))
      "an own-line comment leads the next syntax leaf"
  ensureJsonAt summary [.field "dangling"] (Lean.toJson (1 : Nat))
      "a comment past the last token is file-dangling"

end LayoutSuite

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  withScratchDir "layout" fun work => do
      let cases : Array Case :=
        #[{ name := "doc-properties", run := LayoutSuite.testDocProperties },
          { name := "corpus", run := LayoutSuite.testCorpus root application work },
          { name := "positions", run := LayoutSuite.testPositions root application work }]
      runCases "layout" cases args
