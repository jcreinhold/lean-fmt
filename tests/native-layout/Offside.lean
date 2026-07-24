/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- The offside constraints the adapter enforces, and the constructs they must compose with.

Each constraint names a parser-significant column that native layout alone does not preserve:

- a guarded `let ... | ...` whose continuation is a sibling statement, which native layout can
  reparent under the guard's own sequence;
- the first item of a `sepByIndent` list whose separators the source wrote out, which has to begin on
  its own line so that a later separator breaking cannot dedent an item below it -- and the same list
  spelled with line-break separators, which the formatter's own `align` already positions and which a
  second break would displace;
- the term of a `return`, which must stay on the `return` line;
- a command written inside another command, which begins at the enclosing command's own column and not
  at the indent the embedding node's `nest` would otherwise impose.

`do`, nested `match`, tactic blocks, `where`, and equation alternatives are here because the
constraints have to compose with them, not because each needs a rule of its own. -/

public section

namespace NativeLayoutOffside

/- Guarded `let` whose `| return` continuation is followed by a sibling statement at the owning
indentation. Reparenting the sibling under the guard changes what runs. -/
def guardedSibling (value : Option Nat) : Nat := Id.run do
  let some current := value | return 0
  let doubled := current + current
  return doubled + 1

/- Two guards in one sequence, so the constraint has to apply per owner rather than once per command. -/
def guardedTwice (left right : Option Nat) : Nat := Id.run do
  let some first := left | return 0
  let some second := right | return first
  return first + second

/- A guarded `let` whose bail-out is long enough to need a break of its own. The short bail-outs above
cannot tell an honest boundary from one that only looks right at width 100: a constraint that pins this
bar's break has to leave the term's own break somewhere the `do` block still reads as part of the
bail-out. §1b renders this at 20 and 40, where it must break. -/
def guardedLongBailout (value : Option Nat) : Nat := Id.run do
  let some measured := value | return (Array.replicate 12 0).size + Array.size #[1, 2, 3]
  return measured

/- A bail-out the source spells on more than one line. The join is collected only for a bail-out the
source already fit on one line, because that is what makes flattening it free of the two leaves
flattening cannot remove -- and what bounds the resulting line. This one is not collected, keeps its
break after the bar, and is the negative half of that rule. -/
def guardedSpanningBailout (value : Option Nat) : Nat := Id.run do
  let some measured := value |
    let fallback := 3
    return fallback + 1
  return measured

structure Packet where
  first : Nat
  second : Nat
  third : Nat
  fourth : Nat

/- A record update whose field sequence is long enough to break at a later separator. -/
def updated (base : Packet) : Packet :=
  { base with first := 1, second := 2, third := 3, fourth := 4 }

/- The same update with the separators spelled as line breaks. `sepByIndent.formatter`
(`Lean/Parser/Extra.lean:211-223`) emits a forced `align` for exactly this spelling, so the sequence is
already positioned; the rule above must not fire here. It used to, and the extra break put a blank line
above `first` and left it indented one level past its siblings, which is where the parser stopped
reading fields. -/
def relaid (base : Packet) : Packet :=
  { base with
    first := 1
    second := 2
    third := 3
    fourth := 4 }

/- Nested `match` inside `do`, with alternatives whose bodies break. -/
def nestedMatch (value : Nat) : Nat := Id.run do
  let result :=
    match value with
    | 0 => 1
    | n + 1 =>
      match n with
      | 0 => 2
      | m + 1 => m + 3
  return result

/- A tactic block whose steps must stay siblings. -/
theorem tacticSiblings (n : Nat) : n + 0 = n := by
  have step : n + 0 = n := Nat.add_zero n
  exact step

/- The same list, spelled with `;` instead of line breaks. A tactic sequence is a `sepByIndent` list
like a record update's fields, and `by ` puts its first tactic one column right of the indent the `;`
separators break to -- so breaking a later one and not the first dedents it below the column
`many1Indent` saved, and the block ends there with the rest read as a command. -/
theorem semicolonTactics (n : Nat) : n + 0 = n ∧ n + 0 = n := by
  constructor; exact Nat.add_zero n; exact Nat.add_zero n

/- One tactic has no separator that can break at the wrong column, so nothing is forced and `by` keeps
its tactic. The negative half of the rule, and the reason it counts items rather than matching a kind. -/
theorem singleTactic (n : Nat) : n + 0 = n := by rfl

/- `where` bindings after an equation-alternative body. -/
def withWhere (value : Nat) : Nat :=
  helper value + helper (value + 1)
where
  helper (inner : Nat) : Nat := inner + 1

/- Equation alternatives with guarded bodies. -/
def alternatives : Nat → Nat
  | 0 => 0
  | 1 => 1
  | n + 2 => alternatives n + alternatives (n + 1)

/- A command nested inside another command. `#guard_msgs`'s parser spells `" in" ppLine command` with
no `ppDedent`, so Lean's document puts the embedded command inside the node's own `nest` and it lands
one level in. A command starts at column zero, so the boundary before it is dedented to the enclosing
command's column. That was D13. -/
/-- info: 3 -/
#guard_msgs in
#eval 1 + 2

/- The negative half: `open … in` spells the same embedding and Lean *does* dedent it. The correction
sets a column rather than adjusting one, so it spells here exactly the newline the document already
had. -/
open Nat in
def afterOpen : Nat := 0

end NativeLayoutOffside
