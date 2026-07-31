module

public import Test

import all LeanFmt.Config

/-!
# The declaration-formatter suite

Port of `tests/fixtures/declaration-formatter/run.sh`. Declaration families use structural groups at widths
20/40/80/100; members, constructors, deriving, mutual, where, comments, and custom terms preserve
order. The old Python regexes — including the `\b`-guarded keywords — are `FlexPattern`s here.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace DeclarationFormatter

/-- The keyword inventory every width asserted, in the old block's order. `\b` guards become
`wordBoundary` tokens. -/
private def requiredPatterns : Array FlexPattern :=
  #[[.lit "abbrev", .someWs, .lit "VeryLongAliasName"],
    [.lit "opaque", .someWs, .lit "opaqueValue"], [.lit "axiom", .someWs, .lit "assumedValue"],
    [.lit "@[inline]", .someWs, .lit "private", .someWs, .lit "def", .someWs, .lit "modifiedValue"],
    [.lit "«name with spaces»"], [.wordBoundary, .lit "instance", .wordBoundary],
    [.lit "structure", .someWs, .lit "Packet"], [.lit "structure", .someWs, .lit "ExtendedPacket"],
    [.lit "class", .someWs, .lit "HasValue"], [.lit "class", .someWs, .lit "ExtendedHasValue"],
    [.lit "inductive", .someWs, .lit "Choice"], [.lit "coinductive", .someWs, .lit "Always"],
    [.lit "class", .someWs, .lit "inductive", .someWs, .lit "Classified"],
    [.wordBoundary, .lit "mutual", .wordBoundary], [.lit "def", .someWs, .lit "isEven"],
    [.lit "def", .someWs, .lit "isOdd"], [.lit "def", .someWs, .lit "countdown"],
    [.lit "termination_by"], [.lit "def", .someWs, .lit "withLocal"],
    [.wordBoundary, .lit "where", .wordBoundary]]

/-- Byte position of `needle`'s first occurrence, or none. -/
private def positionOf? (text needle : String) : Option Nat :=
  match text.splitOn needle with
  | head :: _ :: _ => some head.utf8ByteSize
  | _ => none

/-- One Families width: idempotence and the metric invariants, the keyword inventory, the field,
constructor, and mutual orderings, and no trailing whitespace. -/
private def testWidth (root setup : System.FilePath) (application : String) (width : Nat) :
    IO Unit := do
  let report ←
    analyzeExact root application setup "tests/fixtures/declaration-formatter/Families.lean"
        "Families.lean" s!"4:{width}"
  let (canonical, text) ← canonical report s!"width {width}"
  ensure
      (natAt? canonical [.field "metrics", .field "nativeDocuments"] ==
        natAt? canonical [.field "metrics", .field "commands"])
      s!"width {width}: nativeDocuments ≠ commands"
  let aligned := (natAt? canonical [.field "metrics", .field "alignedTokens"]).getD 0
  let commands := (natAt? canonical [.field "metrics", .field "commands"]).getD 0
  ensure (aligned > commands) s!"width {width}: alignedTokens stopped dominating commands"
  for pattern in requiredPatterns do
    ensureFlex s!"width {width}" text pattern
  match ["first : α", "second : α", "count : Nat"].map (positionOf? text) |>.toArray with
  | #[some first, some second, some count] =>
    ensure (first < second && second < count) s!"width {width}: structure fields reordered"
  | _ =>
    throw <| IO.userError s!"width {width}: structure fields missing"
  let constructorPatterns : Array FlexPattern :=
    #[[.lit "|", .someWs, .lit "neither"], [.lit "|", .someWs, .lit "left"],
      [.lit "|", .someWs, .lit "right"]]
  match constructorPatterns.map (flexFind? text) with
  | #[some neither, some left, some right] =>
    ensure (neither < left && left < right) s!"width {width}: constructors reordered"
  | _ =>
    throw <| IO.userError s!"width {width}: constructors missing"
  match flexFind? text [.lit "def", .someWs, .lit "isEven"],
    flexFind? text [.lit "def", .someWs, .lit "isOdd"] with
  | some isEven, some isOdd =>
    ensure (isEven < isOdd) s!"width {width}: mutual definitions reordered"
  | _, _ =>
    throw <| IO.userError s!"width {width}: mutual definitions missing"
  ensureNoTrailingWhitespace s!"width {width}" text

/-- The narrow-width shapes: the opaque signature and the extending structure break where the old
regexes pinned them. -/
private def testNarrowLayout (root setup : System.FilePath) (application : String) : IO Unit := do
  let narrow ←
    do
      let report ←
        analyzeExact root application setup "tests/fixtures/declaration-formatter/Families.lean"
            "Families.lean" "4:20"
      (·.2) <$> canonical report "width 20"
  ensureFlex "width 20" narrow
      [.lit "opaque", .someWs, .lit "opaqueValue", .someWs, .lit "(first", .someWs, .lit "second",
        .anyWs, .lit ":", .anyWs, .lit "Nat)"]
  ensureFlex "width 20" narrow
      [.lit "structure", .someWs, .lit "ExtendedPacket", .someWs, .lit "(α", .anyWs, .lit ":",
        .anyWs, .lit "Type", .someWs, .lit "u)"]

/-- The wide-width shape: the extending structure stays on one line, and the widths disagree. -/
private def testWideLayout (root setup : System.FilePath) (application : String) : IO Unit := do
  let wide ←
    do
      let report ←
        analyzeExact root application setup "tests/fixtures/declaration-formatter/Families.lean"
            "Families.lean" "4:100"
      (·.2) <$> canonical report "width 100"
  ensureFlex "width 100" wide
      [.lit "structure", .someWs, .lit "ExtendedPacket", .someWs, .lit "(α", .anyWs, .lit ":",
        .anyWs, .lit "Type", .someWs, .lit "u)", .someWs, .lit "extends", .someWs, .lit "Packet",
        .someWs, .lit "α", .someWs, .lit "where"]
  let narrow ←
    do
      let report ←
        analyzeExact root application setup "tests/fixtures/declaration-formatter/Families.lean"
            "Families.lean" "4:20"
      (·.2) <$> canonical report "width 20"
  ensure (narrow ≠ wide) "declaration groups ignored width"

/-- The comments fixture: each payload exactly once. -/
private def testComments (root setup : System.FilePath) (application : String) : IO Unit := do
  let report ←
    analyzeExact root application setup "tests/fixtures/declaration-formatter/Comments.lean"
        "Comments.lean" "4:60"
  let (_, text) ← canonical report "comments"
  for payload in
    ["/-- The declaration payload is exact. -/", "-- trailing body payload",
      "/-- The field payload is exact. -/"]do
    ensure ((text.splitOn payload).length == 2) s!"comments: {payload} does not occur exactly once"

/-- `declaration-body`: the canonical `next-line` default breaks even a short body in both
directions; `same-line` joins when the joined line fits `line-width` — source-flat and
already-broken alike — and breaks exactly as the default when it does not. The bodies live in a
scratch file so the two configurations render the same source through the full config plumbing. -/
private def testDeclarationBody (root work setup : System.FilePath) (application : String) :
    IO Unit := do
  let fixture := work / "Bodies.lean"
  writeFile fixture
      "module\n\ndef foo := 1\n\ndef bar :=\n  2\n\ndef baz := Nat.succ (Nat.succ (Nat.succ (Nat.succ (Nat.succ (Nat.succ (Nat.succ Nat.zero)))))) + 1111\n"
  let canonicalFormat : LeanFmt.Internal.FormatConfig := { }
  let report ←
    analyzeExact root application setup fixture.toString "Bodies.lean"
        s!"4j{(Lean.toJson canonicalFormat).compress}"
  let (_, text) ← canonical report "declaration-body default"
  ensureContains text "def foo :=\n  1" "the default did not keep the canonical body break"
  ensureContains text "def bar :=\n  2" "the default joined an already-broken body"
  let sameLine : LeanFmt.Internal.FormatConfig := { declarationBody := .sameLine }
  let joined ←
    analyzeExact root application setup fixture.toString "Bodies.lean"
        s!"4j{(Lean.toJson sameLine).compress}"
  let (_, joinedText) ← canonical joined "declaration-body same-line"
  ensureContains joinedText "def foo := 1\n" "same-line did not keep a source-flat body flat"
  ensureContains joinedText "def bar := 2\n" "same-line did not join an already-broken body"
  ensureContains joinedText "def baz :=\n  Nat.succ"
      "same-line joined a body whose joined line overflows"

end DeclarationFormatter

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  withScratchDir "declaration-formatter" fun work => do
      let setup ← setupFile root work "tests/fixtures/declaration-formatter/Families.lean"
      let cases : Array Case :=
        #[{ name := "width-20", run := DeclarationFormatter.testWidth root setup application 20 },
          { name := "width-40", run := DeclarationFormatter.testWidth root setup application 40 },
          { name := "width-80", run := DeclarationFormatter.testWidth root setup application 80 },
          { name := "width-100", run := DeclarationFormatter.testWidth root setup application 100 },
          { name := "narrow-layout",
            run := DeclarationFormatter.testNarrowLayout root setup application },
          { name := "wide-layout",
            run := DeclarationFormatter.testWideLayout root setup application },
          { name := "comments", run := DeclarationFormatter.testComments root setup application },
          { name := "declaration-body",
            run := DeclarationFormatter.testDeclarationBody root work setup application }]
      runCases "declaration-formatter" cases args
