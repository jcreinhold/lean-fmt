/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public   import   Lean.Parser.Module

/-! The three shapes mathlib's style linters flag and the formatter therefore never produces:
an import row broken across lines, a focusing `·` isolated from its first tactic, and an
attribute-owned doc comment nested past the column its fixed payload was authored to fit. A linter
the formatter trips is a defect, whatever mechanism produced the row. -/

syntax (name := docCarrier) "doc_carrier" (docComment)? : attr

macro_rules
  | `(attr| doc_carrier $[$_doc]?) => `(attr| inline)

/-- The declaration's own doc comment stays above the attribute list. -/
@[doc_carrier
      /-- The **integralization** of a commutative additive monoid: the image of the universal
map into the groupification. It is the universal integral additive monoid under the source. -/
    ]
def integralization : Nat :=
  1

@[doc_carrier /-- A short hugged doc comment keeps the attribute's own row. -/]
def hugged : Nat :=
  2

example (n : Nat) (h : n = n) : n = n ∧ n = n := by
  constructor
  ·
    calc
      n = n := h
      _ = n := rfl
  ·
    exact h

example (n : Nat) (h : n = n) : n = n ∧ n = n ∧ n = n := by
  refine ⟨?_, ?_, ?_⟩
  · -- a comment before the tactic
    calc
      n = n := h
      _ = n := rfl
  ·
    ·
      calc
        n = n := h
        _ = n := rfl
  · skip
    exact h

example (n : Nat) (h : n = n) : n = n ∧ n = n := by
  constructor
  case left =>
    calc
      n = n := h
      _ = n := rfl
  case right => exact h

def addPair : Nat → Nat → Nat := (· + ·)

/- A structure instance whose `{` the source wrote mid-row and whose fields it then spread over
rows. The field rows used to be pinned to the columns the source spelled them at, which held only
while the brace stayed on its row; at a narrow width the value before it breaks, the brace lands
further left, and every pinned row is then right of the first field, where `sepByIndent` reads it
as one more argument of the previous field's value. 28 mathlib modules refused to format for it. -/
structure Pair where
  left : Nat
  right : Nat

structure Nested where
  inner : Pair
  tag : Nat

def midRowBrace (n : Nat) : Nested :=
  { inner := { left := n
               right := n }
    tag := n }

/- A block comment the source wrote over more than one row, in front of the first tactic of a
focusing dot. The comment is trailing on the `·`, and a trailing block comment used to leave the
row open, so the tactic followed the comment's closing bytes onto its last row -- offside of the
block it belongs to. 17 mathlib modules refused to format for it. -/
theorem dotComment (a : Nat) : a = a ∨ a = a := by
  rcases Nat.lt_or_ge a 1 with h | h
  · /- A comment the source wrote over
      more than one row, in front of the
      first tactic of a focusing dot. -/
    exact Or.inl rfl
  · exact Or.inr rfl

/- A `let` whose body the source broke onto its own row, inside the one command-embedding parser
that has no `ppDedent` of its own. The body carries an absolute source-column pin, and every row
inside a nested command carries that command's own cancellation -- so the cancellation reached the
pin twice and the body landed a level left of where the pin named. The pin is collected only for a
body the source already broke, so the first pass created the shape the second pass mis-pinned, and
13 mathlib modules refused as non-idempotent for it. -/
/-- info: let x := true;
x : Bool -/
#guard_msgs in
#check let x := true; x

/- A structure instance the source wrote with its `{` mid-row, whose fields were pinned to their
source columns. Canonical layout breaks in front of `mk`, so the brace opens a row of its own, and
the second pass reads that brace and lays the fields out relative to it -- somewhere the first pass
never put them. Six mathlib modules refused as non-idempotent for it. -/
structure Unital where
  leftIdentity : Nat
  rightIdentity : Nat

def unitalOf (n : Nat) (mk : Unital → Unital) : Unital :=
  mk { leftIdentity := n,
       rightIdentity := n }

/- A `let` whose body the source broke onto its own row, directly under the keyword, inside a
construct canonical layout indents. The body carried an absolute source-column pin, so the keyword
moved right and the body stayed -- stranded outside the construct it belongs to, and read by the
second pass as a column the first pass never chose. Five mathlib modules refused as non-idempotent
for it. -/
def letBodyShift (h : Nat → Nat → Nat) (m : Option Nat) : Nat → Nat := Id.run do
  if let some p := m then return fun _ => p
  return fun n =>
  let a := [1, 2, 3].foldl (init := 0) fun r p => Id.run do
    if r > 0 then return r
    return h (h (h (h (h (h (h r p) p) p) p) p) p) n
  if a > 0 then a
  else n
