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
- the field sequence of a record update, which `sepByIndent` requires to begin on its own line once
  any later separator breaks;
- the term of a `return`, which must stay on the `return` line.

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

structure Packet where
  first : Nat
  second : Nat
  third : Nat
  fourth : Nat

/- A record update whose field sequence is long enough to break at a later separator. -/
def updated (base : Packet) : Packet :=
  { base with first := 1, second := 2, third := 3, fourth := 4 }

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

end NativeLayoutOffside
