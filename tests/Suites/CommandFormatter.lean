module

public import Test

/-!
# The command-formatter suite

Port of `tests/command-formatter/run.sh`. Parsed headers, command boundaries, comments, and custom
commands use native layout; widths 32/60/100 are admitted and byte-idempotent with a descriptor
command; and lean-fmt's own commented command module aligns every command through native layout.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace CommandFormatter

/-- The exact validation shape every CoreInput width asserted: two frontend runs, two renders, one
structural comparison, one idempotence pass. -/
private def expectedValidation : Lean.Json := Lean.Json.mkObj [
  ("frontendRuns", Lean.toJson (2 : Nat)),
  ("renders", Lean.toJson (2 : Nat)),
  ("structuralComparisons", Lean.toJson (1 : Nat)),
  ("idempotencePasses", Lean.toJson (1 : Nat))
]

/-- One CoreInput width: the exact validation dict, the descriptor and alignment invariants, the
header and footer, the custom commands, and no trailing whitespace. -/
private def testWidth (root setup : System.FilePath) (application : String) (width : Nat) :
    IO Unit := do
  let report ← analyzeExact root application setup
    "tests/command-formatter/CoreInput.lean" "CoreInput.lean" s!"4:{width}"
  let (canonical, text) ← canonical report s!"width {width}"
  ensure (jsonAt? canonical [.field "validation"] == some expectedValidation)
    s!"width {width}: validation counters changed"
  let commands := (natAt? canonical [.field "metrics", .field "commands"]).getD 0
  ensure (commands >= 20) s!"width {width}: command floor dropped to {commands}"
  ensure (natAt? canonical [.field "metrics", .field "nativeDocuments"] == some commands)
    s!"width {width}: nativeDocuments ≠ commands"
  let aligned := (natAt? canonical [.field "metrics", .field "alignedTokens"]).getD 0
  ensure (aligned > commands) s!"width {width}: alignedTokens stopped dominating commands"
  ensureJsonAt canonical [.field "metrics", .field "descriptorDocuments"] (Lean.toJson (1 : Nat))
    s!"width {width}"
  ensure (text.startsWith "module\nimport Lean\n\nnamespace CommandFixture\n")
    s!"width {width}: header changed"
  -- The one width-dependent shape: the variable binder splits only at 32.
  if width == 32 then
    ensureContains text "\nuniverse u v\nvariable {α : Type u}\n  (value : α)" "width 32"
  else
    ensureContains text "\nuniverse u v\nvariable {α : Type u} (value : α)" s!"width {width}"
  ensureContains text "\nmacro_rules\n  | `(identity! $term)" s!"width {width}"
  ensureContains text "`($term)\n" s!"width {width}"
  ensureContains text "\nemit_custom generated\n" s!"width {width}"
  ensure (text.endsWith "\nend CommandFixture\n") s!"width {width}: footer changed"
  ensureNoTrailingWhitespace s!"width {width}" text

/-- Width must affect a breakable nested command. -/
private def testWidthDistinctness (root setup : System.FilePath) (application : String) :
    IO Unit := do
  let narrow ← do
    let report ← analyzeExact root application setup
      "tests/command-formatter/CoreInput.lean" "CoreInput.lean" "4:32"
    (·.2) <$> canonical report "width 32"
  let wide ← do
    let report ← analyzeExact root application setup
      "tests/command-formatter/CoreInput.lean" "CoreInput.lean" "4:100"
    (·.2) <$> canonical report "width 100"
  ensure (narrow ≠ wide) "width did not affect a breakable nested command"

/-- The comments fixture: every payload exactly once, including the trailing one glued to its
variable line. -/
private def testComments (root setup : System.FilePath) (application : String) : IO Unit := do
  let report ← analyzeExact root application setup
    "tests/command-formatter/Comments.lean" "Comments.lean" "4:60"
  let (_, text) ← canonical report "comments"
  for payload in ["-- trailing setup comment",
      "/-- A declaration doc comment remains before its owner. -/"] do
    ensure ((text.splitOn payload).length == 2) s!"comments: {payload} does not occur exactly once"
  ensureContains text "\nuniverse u\nvariable {α : Type u} -- trailing setup comment\n" "comments"

/-- lean-fmt's commented command module aligns every command through native layout. The floor was
20 while `Formatter/Command.lean` still held the handwritten command grammar; deleting it left the
module at exactly 20 commands, so the floor moves down rather than pinning the module's size —
what the check is for is that every command in a real commented module is a native document. -/
private def testSelfModule (root : System.FilePath) (application : String)
    (work : System.FilePath) : IO Unit := do
  let setup ← setupFile root work "LeanFmt/Formatter/Command.lean"
  let report ← analyzeExact root application setup
    "LeanFmt/Formatter/Command.lean" "LeanFmt/Formatter/Command.lean" "draft:100"
  let draft ← formatDraft report "self"
  let commands := (natAt? draft [.field "metrics", .field "commands"]).getD 0
  ensure (commands >= 15) s!"self: command floor dropped to {commands}"
  ensure (natAt? draft [.field "metrics", .field "nativeDocuments"] == some commands)
    "self: nativeDocuments ≠ commands"
  let aligned := (natAt? draft [.field "metrics", .field "alignedTokens"]).getD 0
  ensure (aligned > commands) "self: alignedTokens stopped dominating commands"

end CommandFormatter

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  withScratchDir "command-formatter" fun work => do
    let setup ← setupFile root work "tests/command-formatter/CoreInput.lean"
    let cases : Array Case := #[
      { name := "width-32", run := CommandFormatter.testWidth root setup application 32 },
      { name := "width-60", run := CommandFormatter.testWidth root setup application 60 },
      { name := "width-100", run := CommandFormatter.testWidth root setup application 100 },
      { name := "width-distinctness",
        run := CommandFormatter.testWidthDistinctness root setup application },
      { name := "comments", run := CommandFormatter.testComments root setup application },
      { name := "self-module", run := CommandFormatter.testSelfModule root application work }
    ]
    runCases "command-formatter" cases args
