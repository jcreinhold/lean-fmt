/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Lean

/- Operator chains, whose links each inherit an indent level from the link outside them.

Lean's generated formatters wrap every category node in `group (nest format.indent …)`, so a chain of
one operator -- which parses as one node per link -- stacks one `nest` per link and steps each break
one column further in than the last. `LAY-CHAIN-COMPENSATION` in `NativeLayout.lean` cancels the
inherited level, and this fixture is where the cancelling is stated as rows.

Both associativities are here because they stack in opposite directions: `++` is `infixl`, so its
leftmost operand is deepest, and `::` is `infixr`, so its rightmost is. A parenthesised sub-chain is
here as the negative half -- the parentheses interpose a node of another kind, so it is not a
continuation and keeps its own indentation, which is the reading the parentheses ask for.

`viaLet` is the shape that the compensation used to miss. A `let` holds its body's row at a source
column, and the leftmost operand of a chain starts exactly where that row does, so a test that
declined an operand holding a column pin declined every chain written as a `let` body -- which is
ordinary Lean, and which rendered at 152 columns of indent in this repository's own source. The pin
has to sit *strictly inside* an operand to contradict this constraint.

`third` is the shape that is a chain by kind and not by layout: `p.1.2` is `proj` inside `proj`, the
same node on the same side, and dot projection has no break and so no `nest` to cancel. A module of
the verification corpus carrying one refused outright while the compensation was a required
constraint; it is not, and this row is the pin on that.

Renders at widths 100, 40, and 20. Nothing later is expected to move them; a toolchain that changes
what the category formatter wraps will, and that is the change this fixture exists to notice. -/

public def joined (a b c d e f : String) : String :=
  "alpha" ++ a ++ "bravo" ++ b ++ "charlie" ++ c ++ "delta" ++ d ++ "echo" ++ e
      ++ "foxtrot" ++ f ++ "golf"

public def stacked (a b c d : Nat) : List Nat :=
  a :: b :: c :: d :: a :: b :: c :: d :: a :: b :: c :: d :: a :: b :: c :: d :: a :: b :: c :: d
        :: []

public def grouped (a b c d e f : String) : String :=
  (a ++ "alpha" ++ b ++ "bravo" ++ c ++ "charlie" ++ d ++ "delta" ++ e ++ "echo" ++ f ++ "foxtrot")
      ++ "golf" ++ a ++ b

public def viaLet (a b c d e : String) : String :=
  let head := "head"
  head ++ "alpha" ++ a ++ "bravo" ++ b ++ "charlie" ++ c ++ "delta" ++ d ++ "echo" ++ e
      ++ "foxtrot" ++ "golf" ++ "hotel"

public def third (p : (Nat × Nat) × Nat) : Nat := p.1.2
