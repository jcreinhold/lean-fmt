/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import Lean

/- The executable form of `docs/upstream-defects.md`'s reproductions for §§1-9, which are the
pretty-printer defects. Nothing here is compiled: no `lean_lib` globs this file, `lean-fmt.toml`
excludes `tests/fixtures/**`, and the syntax below is deliberately the syntax the toolchain cannot
format. Run it the way the document says to, never with a bare `lean`:

    lake env lean tests/fixtures/upstream-defects/Probe.lean

Each row prints exactly one line, `PROBE <label> <TAG> <detail>`, and the `upstream-defects` suite
reads those lines. The suite owns every expectation; this file owns only the observation. That split
is the point — a row that starts behaving differently should fail with a message naming the mechanism
it lets us delete, and only the suite knows those.

`detail` escapes backslashes and newlines and nothing else, so a needle in the suite reads the way
the rendered source reads. `repr` would double every quote, and half the assertions here are about
quotes.

Controls are rows that must keep working. Without them a preamble that stops parsing would read as
"still defective" forever, which is the failure this whole apparatus exists to prevent. -/

open Lean Parser PrettyPrinter

/- One line, whatever happened. -/
def flat (s : String) : String :=
  (s.replace "\\" "\\\\").replace "\n" "\\n"

/- `docs/upstream-defects.md`'s `tryFmt`, with the outcome tagged rather than prose. -/
def probe (label s : String) (width : Nat := 100) : CoreM Unit := do
  match runParserCategory (← getEnv) `command s with
  | .error _ => IO.println s!"PROBE {label} PARSE-ERROR {flat s}"
  | .ok stx =>
    try
      let rendered := (← formatCommand stx).pretty width
      IO.println s!"PROBE {label} OK {flat rendered}"
    catch e =>
      IO.println s!"PROBE {label} THREW {flat (← e.toMessageData.toString)}"

/- §8 asks a different question: not what the layout is, but whether it stayed inside the width it
was given. The document's indent table is explicitly marked re-fit-before-you-quote, so the tag is
the assertion and the numbers ride along for the failure message. -/
def probeWidth (label s : String) (width : Nat := 100) : CoreM Unit := do
  match runParserCategory (← getEnv) `command s with
  | .error _ => IO.println s!"PROBE {label} PARSE-ERROR {flat s}"
  | .ok stx =>
    try
      let rows := (← formatCommand stx).pretty width |>.splitOn "\n"
      let widest := rows.foldl (fun acc row => max acc row.length) 0
      let deepest := rows.foldl (fun acc row => max acc (row.toList.takeWhile (· == ' ')).length) 0
      let tag := if widest > width then "OVERRUN" else "WITHIN"
      IO.println s!"PROBE {label} {tag} widest={widest} asked={width} indent={deepest}"
    catch e =>
      IO.println s!"PROBE {label} THREW {flat (← e.toMessageData.toString)}"

/- A chain of `n` string operands under one operator, §8's generated family. -/
def chain (operands : Nat) : String :=
  "example := " ++ String.intercalate " ++ " ((List.range operands).map fun i => s!"\"a{i}\"")

/- §1's two probe syntaxes. The branches are swapped between them, and that is the whole
experiment: `pp4` is the control. -/
syntax "pp3 " (interpolatedStr(term) <|> term) : term
syntax "pp4 " (term <|> interpolatedStr(term)) : term

/- §3's tactic, with and without the optional trailing group a positional capture can land in. -/
syntax "cvt" "!"? (" using " num)? : tactic
syntax "cvt2" : tactic

/- §4's rows all declare into a category, and the document does not spell it. -/
declare_syntax_cat spcat

/- §5's `optional` base, the control that must keep formatting. -/
syntax "p7tac" (ppSpace ident)? : tactic

-- §1. `interpolatedStr.formatter` walks whatever node it is handed.
#eval show CoreM Unit from do
  probe "s1-ident" "example := pp3 foo"
  probe "s1-num" "example := pp3 1"
  probe "s1-paren" "example := pp3 (foo)"
  probe "s1-app" "example := pp3 (foo bar)"
  probe "s1-infix" "example := pp3 foo + bar"
  probe "s1-anonymous" "example := pp3 ⟨foo⟩"
  probe "s1-string" "example := pp3 \"x\""
  probe "s1-control-paren" "example := pp4 (foo)"
  probe "s1-control-app" "example := pp4 (foo bar)"
  probe "s1-control-string" "example := pp4 \"x\""
  probe "s1-throwerror-ident" "def a : MetaM Unit := throwError err"
  probe "s1-throwerror-string" "def b : MetaM Unit := throwError \"boom\""
  probe "s1-throwerror-paren" "def c : MetaM Unit := throwError (id \"x\")"
  probe "s1-trace-paren" "def d : MetaM Unit := do trace[x] (id \"x\")"
  probe "s1-trace-app" "def e : MetaM Unit := do trace[x] id \"x\""
  probe "s1-trace-interpolated" "def f : MetaM Unit := do trace[x] m!\"x\""

-- §2. `parserOfStack.formatter` reads one slot short.
#eval show CoreM Unit from do
  probe "s2-control-term" "def a := `(1 + 1)"
  probe "s2-control-tactic" "def b := `(tactic| skip)"
  probe "s2-conv" "def c := `(conv| skip)"
  probe "s2-doelem" "def d := `(doElem| pure ())"
  probe "s2-command" "def e := `(command| #eval 1)"
  probe "s2-macro-conv" "macro \"rc1\" : conv => `(conv| skip)"

-- §3. A `%$` positional capture makes any quotation unformattable.
#eval show CoreM Unit from do
  probe "s3-control-plain" "macro_rules | `(tactic| cvt !) => `(tactic| cvt2)"
  probe "s3-capture" "macro_rules | `(tactic| cvt !%$e) => `(tactic| cvt2)"
  probe "s3-control-optional" "macro_rules | `(tactic| cvt $[!]?) => `(tactic| cvt2)"
  probe "s3-capture-in-splice" "macro_rules | `(tactic| cvt $[!%$e]?) => `(tactic| cvt2)"
  probe "s3-capture-keyword" "macro_rules | `(tactic| cvt using%$u 1) => `(tactic| cvt2)"
  probe "s3-capture-quotation" "def f := `(tactic| cvt !%$e)"
  probe "s3-capture-term" "def g := `(1 +%$p 1)"
  probe "s3-control-bare" "example : True := by exact trivial"
  probe "s3-capture-bare" "example : True := by exact%$t trivial"

-- §4. Two forgotten separators in `src/Lean/Parser/Syntax.lean`.
#eval show CoreM Unit from do
  probe "s4-optkind" "macro_rules (kind := spcat) | x => x"
  probe "s4-control-behavior" "declare_syntax_cat foo (behavior := symbol)"
  probe "s4-control-name" "syntax (name := nm1) \"tok1\" : spcat"
  probe "s4-control-outer-list" "syntax \"t6\" \"a\" \"b\" : spcat"
  probe "s4-paren" "syntax \"t1\" (\"a\" \"b\") : spcat"
  probe "s4-optional" "syntax \"t2\" optional(\"a\" \"b\") : spcat"
  probe "s4-andthen" "syntax \"t3\" andthen(\"a\" \"b\", \"c\" \"d\") : spcat"
  probe "s4-sepby" "syntax \"t4\" sepBy(\"a\" \"b\", \",\") : spcat"
  probe "s4-sepby1" "syntax \"t5\" sepBy1(\"a\" \"b\", \",\") : spcat"
  probe "s4-abbrev" "syntax abbr2 := \"a\" \"b\""

-- §5. `sepByIndent.formatter` drops the antiquotation splice its own parser adds.
#eval show CoreM Unit from do
  probe "s5-splice-scope" "macro \"p1\" \"[\" h:term,* \"]\" : tactic => `(tactic| ($[have := $h];*))"
  probe "s5-splice-suffix" "macro \"p2\" \"[\" h:tactic,* \"]\" : tactic => `(tactic| ($h;*))"
  probe "s5-control-sepby-scope"
    "def p3 (xs : Array Lean.Term) : Lean.MacroM Lean.Syntax := `(#[$[$xs],*])"
  probe "s5-control-sepby-suffix"
    "def p4 (xs : Array Lean.Term) : Lean.MacroM Lean.Syntax := `(#[$xs,*])"
  probe "s5-control-many"
    "def p6 (xs : Array Lean.Ident) : Lean.MacroM Lean.Syntax := `(fun $[$xs]* => 1)"
  probe "s5-control-optional"
    "def p7 (x? : Option Lean.Ident) : Lean.MacroM Lean.Syntax := `(tactic| p7tac $[$x?]?)"

-- §6. `ctor` puts the newline after the docstring it should precede.
#eval show CoreM Unit from do
  probe "s6-first-constructor" "inductive Foo where\n  /-- the doc -/\n  | mk : Foo"
  probe "s6-later-constructor"
    "inductive Bar where\n  | first : Bar\n  /-- second's doc -/\n  | second : Bar"
  probe "s6-control-structure-field" "structure S where\n  /-- the field -/\n  fst : Nat"
  probe "s6-narrow" "inductive Foo where\n  /-- the doc -/\n  | mk : Foo" 20

-- §7. `guardMsgsCmd` omits the `ppDedent` every other command-embedding parser has.
#eval show CoreM Unit from do
  probe "s7-guard-msgs" "#guard_msgs in\nexample : True := trivial"
  probe "s7-guard-panic" "#guard_panic in\nexample : True := trivial"
  probe "s7-control-set-option" "set_option pp.all true in\nexample : True := trivial"

-- §8. The category formatter's `nest` accumulates once per link of an operator chain.
#eval show CoreM Unit from do
  probeWidth "s8-control-short-chain" (chain 8)
  probeWidth "s8-long-chain" (chain 64)

-- §9. Four toolchain parsers declare a node kind that names no constant.
#eval show CoreM Unit from do
  probe "s9-label-attr" "register_label_attr leanFmtProbeAttr"
  probe "s9-simp-attr" "register_simp_attr leanFmtProbeSimp"
  probe "s9-grind-attr" "register_grind_attr leanFmtProbeGrind"
  probe "s9-control" "example : True := trivial"
