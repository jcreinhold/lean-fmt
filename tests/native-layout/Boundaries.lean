/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/-! A module doc comment is a command, not trivia, and owns its own bytes. -/

/- Every comment position the adapter distinguishes appears once: leading, trailing, interior between
two tokens, interior inside a delimiter pair, dangling at the end of a block, consecutive comments in
one gap, and doc comments on a declaration, a structure field, and a constructor.

Doc comments are the case that must stay in place. Hoisting them to the front of their command moves
a field's docstring onto the structure and leaves the native separator where the docstring was.

An ordinary comment written *above* a docstring is the case that must not be swept up with it. Lean
stores a docstring's opening token in the following token's trivia, so both comments arrive at the
ownership layer as leading trivia of one command; the rule that keeps the command's own docstring from
being emitted twice has to select by comment kind, because dropping the whole run drops the ordinary
comment with it. That was D8, and mathlib writes the shape often. -/

public section

namespace NativeLayoutBoundaries

-- leading line comment
def leadingOwner : Nat := 0 -- trailing line comment

/- leading block comment -/
def blockOwner : Nat := 1

-- first of two consecutive comments
-- second of two consecutive comments
def consecutiveOwner : Nat := 2

def interiorOwner : Nat :=
  3 + -- interior line comment before a continuation
    4

def delimitedOwner : List Nat :=
  [ /- interior block comment inside a delimiter -/ 5, 6]

/-- A declaration doc comment stays on its declaration. -/
def documented : Nat := 7

-- an ordinary comment above a docstring is not part of it
/-- A doc comment can be preceded by ordinary comments the command does not own. -/
def documentedAfterComment : Nat := 7

-- the first of two comments above a docstring
-- the second of two comments above a docstring
/-- Both of them survive, because the exclusion is by comment kind and not by trivia run. -/
def documentedAfterTwoComments : Nat := 7

structure Fields where
  /-- A field doc comment stays on its field, not on the structure. -/
  first : Nat
  second : Nat

inductive Choice where
  /-- A constructor doc comment stays on its constructor. -/
  | left
  | right

inductive Spanning where
  /-- A constructor doc comment can run onto a second line, and then the two halves of its repair
  pull against each other: the constraint that moves the first line must leave the bytes the
  exact island already carries exactly where they are. -/
  | only

/- A comment sitting in the one boundary the document spells as a forced alignment: between `by` and
the first tactic of a line-separated sequence. That align is `sepByIndent`'s reference column for every
later tactic, so a comment the adapter cannot place there is carried to the next boundary it can --
the following tactic's own leading padding, inside that tactic's `nest` -- where it renders one level
too deep and takes the tactic with it, leaving the second tactic to end the block.

The payload spans lines because that is the other half of the same fixture. `Format.text` re-indents
every newline it contains, so a continuation line carrying its own source column needs the cancelling
`nest` an exact island gets; without it the comment's bytes change and the contract refuses. -/
theorem alignBoundaryOwner (n : Nat) : n + 0 = n := by
  /- A comment written between `by` and the first tactic, too long to join the `by` line, with a
  continuation line that owns its own column. -/
  let doubled := n
  have step : doubled + 0 = doubled := Nat.add_zero doubled
  exact step

def danglingOwner : Nat := Id.run do
  let value := 8
  return value
  -- dangling comment after the last statement

def unalignedTail : Nat := 8
  -- indented past every block, aligned with none of them

/- A comment dangling at the end of a block that is *not* the command's last, so a statement follows it
at a shallower indent. The gap after the block's last token is the same gap as the one before that
statement, so a boundary can only render the comment at the following statement's column -- where a
reparse makes it that statement's leading trivia. Two of them, because a block can end in more than one
and they have to leave together, and the block's last item is itself an `if`/`else` chain, because that
puts one more `nest` between the node that claims the span and the indent the block's items were laid
out at. That was D17. -/
def danglingInnerBlock (flag : Bool) (n : Nat) : Nat := Id.run do
  let mut total := 0
  if flag then
    if n == 0 then
      total := total + 1
    else if n == 1 then
      total := total + 2
    -- dangling on the block the `if` opens
    -- and a second one, which leaves with the first
  total := total + 3
  return total

/- A docstring on a `where` binding: a doc comment that is an exact island *and* the terminal a doc
boundary was collected at, because it is neither the command's own docstring nor a constructor's. The
island consumed that terminal in one step and never asked for the boundary in front of it, so the
boundary stayed collected and the command was refused -- `Mathlib/Tactic/CasesM.lean` reported
`applied 4/5 boundaries`. Two bindings, because the second is where a column that moved would show:
`where` bindings are `checkColGe` against the first. That was D26. -/
def documentedWhere (n : Nat) : Nat := twice n + once n
where
  /-- Doubles its argument. -/
  twice (n : Nat) : Nat := n + n
  /-- Adds one to its argument. -/
  once (n : Nat) : Nat := n + 1

end NativeLayoutBoundaries
