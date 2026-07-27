module

public import Test

/-!
# The term-formatter suite

Port of `tests/term-formatter/run.sh`. Applications and structural control terms reflow at widths
20/40/80/100; let continuations, nested conditionals, match discriminants, and arm order survive;
project notation stays registry-driven only at its actual syntax node.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace TermFormatter

/-- The exact validation shape every width asserted. The fixture's 23 commands are reparsed under
the contexts the one frontend run left, so the count does not move with the width. -/
private def expectedValidation : Lean.Json := Lean.Json.mkObj [
  ("frontendRuns", Lean.toJson (1 : Nat)),
  ("renders", Lean.toJson (2 : Nat)),
  ("structuralComparisons", Lean.toJson (1 : Nat)),
  ("idempotencePasses", Lean.toJson (1 : Nat)),
  ("reparsedCommands", Lean.toJson (23 : Nat))
]

/-- The spellings every width asserted: operator and projection shapes, the project notation, one
binder, one explicit application. -/
private def spellings : Array FlexPattern := #[
  [.lit "alpha", .anyWs, .lit "+", .anyWs, .lit "beta"],
  [.lit "Nat.succ", .someWs, .lit "value"],
  [.lit "pair.1", .anyWs, .lit "+", .anyWs, .lit "pair.2"],
  [.lit "⊕custom"],
  [.lit "(value", .anyWs, .lit ":", .anyWs, .lit "Nat)"],
  [.lit "@Nat.succ"]
]

/-- One width's canonical text with the exact validation dict, the metric invariants, and the
spellings. -/
private def widthText (root setup : System.FilePath) (application : String) (width : Nat) :
    IO String := do
  let report ← analyzeExact root application setup
    "tests/term-formatter/Terms.lean" "Terms.lean" s!"4:{width}"
  let (canonical, text) ← canonical report s!"width {width}"
  ensure (jsonAt? canonical [.field "validation"] == some expectedValidation)
    s!"width {width}: validation counters changed"
  ensure (natAt? canonical [.field "metrics", .field "nativeDocuments"] ==
      natAt? canonical [.field "metrics", .field "commands"])
    s!"width {width}: nativeDocuments ≠ commands"
  let aligned := (natAt? canonical [.field "metrics", .field "alignedTokens"]).getD 0
  let commands := (natAt? canonical [.field "metrics", .field "commands"]).getD 0
  ensure (aligned > commands) s!"width {width}: alignedTokens stopped dominating commands"
  for pattern in spellings do
    ensureFlex s!"width {width}" text pattern
  return text

/-- Width 20: applications break after the first argument, the custom notation breaks inside its
parentheses, the conditional breaks, and the match arms stay in order. -/
private def testWidth20 (root setup : System.FilePath) (application : String) : IO Unit := do
  let text ← widthText root setup application 20
  ensureContains text "  consumeFive alpha\n    beta gamma delta\n    epsilon" "width 20"
  ensureContains text "consumeFive\n    (alpha ⊕custom\n      beta)" "width 20"
  ensureContains text "  if condition then\n    yes\n  else no" "width 20"
  match (["| 0, _ => alpha", "| _, 1 => beta"].map fun needle =>
      (text.splitOn needle).head!.utf8ByteSize) with
  | [first, second] =>
    ensure ((text.splitOn "| 0, _ => alpha").length == 2 &&
        (text.splitOn "| _, 1 => beta").length == 2 && first < second)
      "width 20: match arms reordered"
  | _ => throw <| IO.userError "impossible: splitOn returns a head"

/-- Width 40: one more argument fits, conditionals lie flat, lambdas and let continuations keep
their shapes. -/
private def testWidth40 (root setup : System.FilePath) (application : String) : IO Unit := do
  let text ← widthText root setup application 40
  ensureContains text "  consumeFive alpha beta gamma delta\n    epsilon" "width 40"
  ensureContains text "if condition then yes else no" "width 40"
  ensureContains text "fun first second => first + second" "width 40"
  ensureContains text "let first := alpha + beta\n  let second := first * gamma" "width 40"

/-- Width 80: applications lie flat, as do the flat terms, the else-if chain, the pattern let, and
the match discriminant. -/
private def testWidth80 (root setup : System.FilePath) (application : String) : IO Unit := do
  let text ← widthText root setup application 80
  ensureContains text "consumeFive alpha beta gamma delta epsilon" "width 80"
  ensureContains text "fun (first : Nat) (second : Nat) =>" "width 80"
  for flat in ["alpha + beta * gamma + delta", "(f := fun value => value + 1)",
      "`(alpha + beta * gamma)"] do
    ensureContains text flat "width 80"
  ensureContains text "else if second then" "width 80"
  ensureContains text "let (actual, _) := value" "width 80"
  ensureContains text "match _h : first, second with" "width 80"

/-- Width 100: the explicit application takes its argument. -/
private def testWidth100 (root setup : System.FilePath) (application : String) : IO Unit := do
  let text ← widthText root setup application 100
  ensureContains text "@Nat.succ value" "width 100"

/-- The widths disagree with each other — the term groups are not width-blind. -/
private def testWidthDistinctness (root setup : System.FilePath) (application : String) :
    IO Unit := do
  let narrow ← widthText root setup application 20
  let middle ← widthText root setup application 40
  let wide ← widthText root setup application 80
  ensure (narrow ≠ middle && middle ≠ wide) "term groups ignored configured width"

end TermFormatter

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  withScratchDir "term-formatter" fun work => do
    let setup ← setupFile root work "tests/term-formatter/Terms.lean"
    let cases : Array Case := #[
      { name := "width-20", run := TermFormatter.testWidth20 root setup application },
      { name := "width-40", run := TermFormatter.testWidth40 root setup application },
      { name := "width-80", run := TermFormatter.testWidth80 root setup application },
      { name := "width-100", run := TermFormatter.testWidth100 root setup application },
      { name := "width-distinctness",
        run := TermFormatter.testWidthDistinctness root setup application }
    ]
    runCases "term-formatter" cases args
