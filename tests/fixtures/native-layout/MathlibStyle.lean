/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public   import   Lean.Parser.Module

/-! The three shapes mathlib's style linters flag and the formatter therefore never produces:
an import row broken across lines, a focusing `·` isolated from its first tactic, and an
attribute-owned doc comment nested past the column its fixed payload was authored to fit. -/

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
