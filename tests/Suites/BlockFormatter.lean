module

public import Test

/-!
# The block-formatter suite

Port of `tests/block-formatter/run.sh`. The fixture's tactic, do, control, match, and where roots
are analyzed through the exact frontend at four widths; every width must validate, render
idempotently through one aligned native document per command, and keep every block construct and
comment the fixture carries. The narrow width additionally proves the reflow is real: the registry
is not width-blind.
-/

open LeanFmt.Test

/-- The strings every width's render must keep: one representative per block family the fixture
exercises, plus its three pinned comments (each exactly once) and its `let` ordering. -/
private def requiredStrings : Array String := #[
  "exact proof", "constructor", "first", "| exact proof", "constructor <;>",
  "custom_assumption", "match value with", "let some value :=", "let some value ←",
  "input |", "long guarded let", "long guarded bind", "total ←", "have positive",
  "for value", "values do", "continue", "break", "while", "total <", "let rec count",
  "else if", "value.isNone then", "unless flag do", "repeat", "until flag", "let value ←",
  "{\n", "1;", "try", "catch _ =>", "catch\n", "finally", "dbg_trace", "assert!",
  "debug_assert!", "Id.run", "where"
]

namespace BlockFormatter

/-- A Nat at the end of a JSON path, when it exists and is one. -/
private def natAt? (json : Lean.Json) (path : List JsonStep) : Option Nat :=
  (jsonAt? json path).bind fun value => (Lean.fromJson? value).toOption

/-- Byte position of `needle`'s first occurrence, or none. -/
private def positionOf? (text needle : String) : Option Nat :=
  match text.splitOn needle with
  | _ :: _ :: _ => some (text.splitOn needle).head!.utf8ByteSize
  | _ => none

/-- Analyze the fixture at `width`, returning the canonical text after asserting the envelope's
invariants: no validation failure, idempotent, one native document per command, and the alignment
and offside counts the fixture's shape implies. -/
private def canonicalText (root work : System.FilePath) (application : String) (width : Nat) :
    IO String := do
  let result ← expectExit 0 s!"__analyze-exact at width {width}" application
    #["__analyze-exact", (work / "setup.json").toString, "tests/block-formatter/Blocks.lean",
      "Blocks.lean", "8589934592", s!"4:{width}"]
    (cwd? := some root)
  let report ← parseJson result.stdout s!"__analyze-exact at width {width}"
  -- Absent or null: the old Python asserted `report.get("validationFailure") is None`, which
  -- covers both, and the binary omits the key on success.
  ensure (jsonAt? report [.field "validationFailure"] |>.all (· == Lean.Json.null))
    s!"width {width}: validation failed"
  let some canonical := jsonAt? report [.field "canonical"]
    | throw <| IO.userError s!"width {width}: no canonical render"
  ensureJsonAt canonical [.field "validation", .field "idempotencePasses"] (Lean.toJson (1 : Nat))
    s!"width {width}"
  let metrics := (jsonAt? canonical [.field "metrics"]).getD Lean.Json.null
  ensure (natAt? metrics [.field "nativeDocuments"] == natAt? metrics [.field "commands"])
    s!"width {width}: nativeDocuments ≠ commands"
  let alignedTokens := (natAt? metrics [.field "alignedTokens"]).getD 0
  ensure (alignedTokens > 500) s!"width {width}: alignedTokens dropped to {alignedTokens}"
  let offsideConstraints := (natAt? metrics [.field "offsideConstraints"]).getD 0
  ensure (offsideConstraints >= 4) s!"width {width}: offsideConstraints dropped to {offsideConstraints}"
  let some text := (canonical.getObjValAs? String "text").toOption
    | throw <| IO.userError s!"width {width}: canonical text missing"
  return text

/-- One width's full inventory: required strings, the three pinned comments exactly once each, and
the `let` ordering. -/
private def widthCase (root work : System.FilePath) (application : String) (width : Nat) :
    IO Unit := do
  let text ← canonicalText root work application width
  for required in requiredStrings do
    ensureContains text required s!"width {width}"
  for comment in ["/- between focused goals -/", "/- match-arm comment -/", "/- long guarded let -/",
      "/- long guarded bind -/"] do
    ensure ((text.splitOn comment).length == 2)
      s!"width {width}: {comment} does not occur exactly once"
  match (["let first", "let second", "pure second"].map (positionOf? text)).toArray with
  | #[some first, some second, some pure] =>
    ensure (first < second && second < pure) s!"width {width}: let/pure ordering moved"
  | _ => throw <| IO.userError s!"width {width}: let/pure markers missing"

private def testNarrowReflow (root work : System.FilePath) (application : String) : IO Unit := do
  let narrow ← canonicalText root work application 20
  ensureContains narrow "by\n  constructor\n  ·" "width 20"
  ensureContains narrow "first\n  | exact proof\n  | assumption" "width 20"
  ensureContains narrow "Option Nat := do\n  let first ←" "width 20"
  ensureContains narrow "Id.run do\n    let" "width 20"
  ensureContains narrow ":= do\n  {" "width 20"
  match (["| 0 =>", "| _ =>"].map (positionOf? narrow)).toArray with
  | #[some literal, some fallback] =>
    ensure (literal < fallback) "width 20: fallback arm moved before the literal arm"
  | _ => throw <| IO.userError "width 20: match arms missing"
  let wide ← canonicalText root work application 80
  ensure (narrow ≠ wide) "block registry ignored configured width"

end BlockFormatter

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  withTempDir fun work => do
    let setup ← expectExit 0 "lake setup-file" "lake"
      #["setup-file", "tests/block-formatter/Blocks.lean"] (cwd? := some root)
    writeFile (work / "setup.json") setup.stdout
    let cases : Array Case := #[
      { name := "width-20", run := BlockFormatter.widthCase root work application 20 },
      { name := "width-40", run := BlockFormatter.widthCase root work application 40 },
      { name := "width-80", run := BlockFormatter.widthCase root work application 80 },
      { name := "width-100", run := BlockFormatter.widthCase root work application 100 },
      { name := "narrow-reflow", run := BlockFormatter.testNarrowReflow root work application }
    ]
    runCases "block-formatter" cases args
