module

public import Test

import all LeanFmt.Config

/-!
# The collection-formatter suite

Tuples, lists, arrays, and trailing separators use native flat/broken documents; comma-bearing,
update, and layout-separated records preserve their parser contracts; actual operator association
controls left-, right-, and arrow-chain reflow; and project-defined entries remain opaque while
their collection ancestor reflows.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace CollectionFormatter

/-- One width's canonical text plus the metric invariants the old loop asserted per width. -/
private def widthText (root setup : System.FilePath) (application : String) (width : Nat) :
    IO String := do
  let report ←
    analyzeExact root application setup "tests/fixtures/collection-formatter/Collections.lean"
        "Collections.lean" s!"4:{width}"
  let (canonical, text) ← canonical report s!"width {width}"
  ensure
      (natAt? canonical [.field "metrics", .field "nativeDocuments"] ==
        natAt? canonical [.field "metrics", .field "commands"])
      s!"width {width}: nativeDocuments ≠ commands"
  let aligned := (natAt? canonical [.field "metrics", .field "alignedTokens"]).getD 0
  let commands := (natAt? canonical [.field "metrics", .field "commands"]).getD 0
  ensure (aligned > commands) s!"width {width}: alignedTokens stopped dominating commands"
  let offside := (natAt? canonical [.field "metrics", .field "offsideConstraints"]).getD 0
  ensure (offside >= 1) s!"width {width}: offsideConstraints dropped to {offside}"
  return text

/-- The per-width structural assertions: match-arm order, the opaque project-defined entry, and
left-before-right association. -/
private def testWidth (root setup : System.FilePath) (application : String) (width : Nat) :
    IO Unit := do
  let text ← widthText root setup application width
  let armPatterns : Array FlexPattern :=
    #[[.lit "|", .anyWs, .lit "0", .anyWs, .lit "=>", .anyWs, .lit "alpha"],
      [.lit "|", .anyWs, .lit "1", .anyWs, .lit "=>", .anyWs, .lit "beta"],
      [.lit "|", .anyWs, .lit "_", .anyWs, .lit "=>", .anyWs, .lit "gamma"]]
  match armPatterns.map (flexFind? text) with
  | #[some a, some b, some c] =>
    ensure (a < b && b < c) s!"width {width}: match arms reordered"
  | _ =>
    throw <| IO.userError s!"width {width}: match arms missing"
  ensureFlex s!"width {width}" text [.lit "custom{alpha}"]
  match flexFind? text [.lit "def", .someWs, .lit "leftAssociative"],
    flexFind? text [.lit "def", .someWs, .lit "rightAssociative"] with
  | some left, some right =>
    ensure (left < right) s!"width {width}: associativity declarations reordered"
  | _, _ =>
    throw <| IO.userError s!"width {width}: associativity declarations missing"

/-- At the narrow width the collections must break, and break where the old regexes pinned them. -/
private def testNarrowLayout (root setup : System.FilePath) (application : String) : IO Unit := do
  let narrow ← widthText root setup application 20
  for broken in
    ([[.lit "(alpha,", .anyWs, .lit "beta,", .newline, .lit "gamma,", .anyWs, .lit "delta)"],
        [.lit "[alpha,", .anyWs, .lit "beta,", .newline, .lit "gamma,", .anyWs, .lit "delta,",
          .newline, .lit "epsilon]"],
        [.lit "#[alpha,", .anyWs, .lit "beta,", .newline, .lit "gamma,", .anyWs, .lit "delta,",
          .newline, .lit "epsilon]"],
        [.lit "⟨alpha,", .anyWs, .lit "beta,", .newline, .lit "gamma⟩"]] :
      List FlexPattern) do
    ensureFlex "width 20" narrow broken
  ensureFlex "width 20 (trailing list separator)" narrow [.lit "gamma,", .anyWs, .lit "]"]
  ensureFlex "width 20" narrow
      [.lit "{", .anyWs, .lit "first", .anyWs, .lit ":=", .anyWs, .lit "alpha,", .anyWs,
        .lit "second", .anyWs, .lit ":=", .anyWs, .lit "beta,", .anyWs, .lit "third", .anyWs,
        .lit ":=", .anyWs, .lit "gamma", .anyWs, .lit "}"]
  ensureFlex "width 20" narrow
      [.lit "{", .anyWs, .lit "packet", .someWs, .lit "with", .newline, .lit "first", .anyWs,
        .lit ":=", .anyWs, .lit "alpha,", .anyWs, .lit "second", .anyWs, .lit ":=", .anyWs,
        .lit "beta", .anyWs, .lit "}"]
  ensureFlex "width 20" narrow
      [.lit "{", .anyWs, .lit "first", .anyWs, .lit ":=", .anyWs, .lit "alpha", .someWs,
        .lit "second", .anyWs, .lit ":=", .anyWs, .lit "beta", .someWs, .lit "third", .anyWs,
        .lit ":=", .anyWs, .lit "gamma", .anyWs, .lit "}"]
  ensureFlex "width 20" narrow
      [.lit "alpha", .anyWs, .lit "+", .anyWs, .lit "beta", .anyWs, .lit "+", .anyWs, .lit "gamma",
        .anyWs, .lit "+", .anyWs, .lit "delta"]
  ensureFlex "width 20" narrow
      [.lit "alpha", .anyWs, .lit "^", .anyWs, .lit "beta", .anyWs, .lit "^", .anyWs, .lit "gamma"]
  ensureFlex "width 20" narrow
      [.lit "Nat", .anyWs, .lit "→", .anyWs, .lit "Nat", .anyWs, .lit "→", .anyWs, .lit "Nat"]
  ensureFlex "width 20" narrow [.lit "[", .anyWs, .lit "custom{alpha},"]

/-- At width 80 the same collections lie flat, the update record still breaks, and the widths
disagree with each other — the registry is not width-blind. -/
private def testWideLayout (root setup : System.FilePath) (application : String) : IO Unit := do
  let wide ← widthText root setup application 80
  for flat in
    ["(alpha, beta, gamma, delta)", "[alpha, beta, gamma, delta, epsilon]",
      "#[alpha, beta, gamma, delta, epsilon]", "⟨alpha, beta, gamma⟩",
      "{ first := alpha, second := beta, third := gamma }", "{ first, second, third }",
      "{ first := alpha, second := beta, third := gamma : Packet }",
      "{ first := alpha, second := 0, third := 0, .. }"] do
    ensureContains wide flat "width 80"
  ensureFlex "width 80" wide
      [.lit "{", .anyWs, .lit "packet", .someWs, .lit "with", .newline, .lit "first", .anyWs,
        .lit ":=", .anyWs, .lit "alpha,", .anyWs, .lit "second", .anyWs, .lit ":=", .anyWs,
        .lit "beta", .anyWs, .lit "}"]
  let narrow ← widthText root setup application 20
  let middle ← widthText root setup application 40
  ensure (narrow ≠ middle && middle ≠ wide) "collection groups ignored configured width"

/-- `magic-trailing-comma`: at the flat width every trailing-comma collection in the fixture
explodes — one element per row at the collection-nested column, the closing bracket on its own
row dedented to the collection's row — under `ignore` the same collections are width's alone,
which keeps them flat here. The assertions are exact substrings: the columns are the contract. -/
private def testMagicTrailingComma (root setup : System.FilePath) (application : String) :
    IO Unit := do
  let report ←
    analyzeExact root application setup "tests/fixtures/collection-formatter/Collections.lean"
        "Collections.lean" "4:80"
  let (_, text) ← canonical report "magic-trailing-comma"
  for exploded in
    ["[\n    alpha,\n    beta,\n    gamma,\n  ]", "#[\n    alpha,\n    beta,\n    gamma,\n  ]",
      "(\n    alpha,\n    beta,\n    gamma,\n  )", "⟨\n    alpha,\n    beta,\n    gamma,\n  ⟩",
      "{\n    first := alpha,\n    second := beta,\n    third := gamma,\n  }",
      "#[\n    alpha,\n  ]",
      "(\n    #[\n      alpha,\n      beta,\n    ],\n    #[\n      gamma,\n    ],\n  )",
      "#[\n    -- leading comment\n    alpha,\n    beta,\n    gamma,\n  ]"] do
    ensureContains text exploded "magic-trailing-comma"
  let ignore : LeanFmt.Internal.FormatConfig := { magicTrailingComma := .ignore }
  let ignored ←
    analyzeExact root application setup "tests/fixtures/collection-formatter/Collections.lean"
        "Collections.lean" s!"4j{(Lean.toJson ignore).compress}"
  let (_, ignoredText) ← canonical ignored "magic-trailing-comma ignore"
  for flat in
    ["[alpha, beta, gamma, ]", "#[alpha, beta, gamma, ]", "(alpha, beta, gamma, )",
      "⟨alpha, beta, gamma, ⟩", "{ first := alpha, second := beta, third := gamma, }"] do
    ensureContains ignoredText flat "magic-trailing-comma ignore"

end CollectionFormatter

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  withScratchDir "collection-formatter" fun work => do
      let setup ←
        LeanFmt.Test.Analyze.setupFile root work
            "tests/fixtures/collection-formatter/Collections.lean"
      let cases : Array Case :=
        #[{ name := "width-20", run := CollectionFormatter.testWidth root setup application 20 },
          { name := "width-40", run := CollectionFormatter.testWidth root setup application 40 },
          { name := "width-80", run := CollectionFormatter.testWidth root setup application 80 },
          { name := "width-100", run := CollectionFormatter.testWidth root setup application 100 },
          { name := "narrow-layout",
            run := CollectionFormatter.testNarrowLayout root setup application },
          { name := "wide-layout",
            run := CollectionFormatter.testWideLayout root setup application },
          { name := "magic-trailing-comma",
            run := CollectionFormatter.testMagicTrailingComma root setup application }]
      runCases "collection-formatter" cases args
