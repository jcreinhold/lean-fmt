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
comment with it. Mathlib writes the shape often. -/

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
out at. -/
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
`where` bindings are `checkColGe` against the first. -/
def documentedWhere (n : Nat) : Nat := twice n + once n
where
  /-- Doubles its argument. -/
  twice (n : Nat) : Nat := n + n
  /-- Adds one to its argument. -/
  once (n : Nat) : Nat := n + 1

/- Three runs the source spells on one line that a break inside would reparse. All three are Lean's own
`formatCommand` -- each was checked against it directly before the adapter was touched -- and all three
are the same failure `many1Indent` produces for a guarded `let`'s bail-out: a continuation lands at a
column the parser reads as the next item of the enclosing list. -/

/- A structure-instance field's binders. The group deciding the `ppSpace`s between them also holds the
field's body, so a multi-line body breaks the binders however short they are -- 21 columns here, and
`m` would land at the field's own column and be read as a second field.
`Mathlib/CategoryTheory/Sites/CoverLifting.lean` reported that as `Fields missing: Y, f`. -/
class BoundedField (a : Type) where
  bounded : ∀ {n : Nat} (m : Nat), n = m → Nat

instance : BoundedField Nat where
  bounded {n} m h := by
    have carried := h
    exact m + m

/- An `induction … generalizing` list, whose items are `colGt` against the tactic's own start column --
a column `nest` cannot name, because it is relative to the ambient indent instead. The head is written
long enough that the layout has to break somewhere; every remaining place is an atom the parser reads
without a column check. `Mathlib/Algebra/MonoidAlgebra/NoZeroDivisors.lean` reported the break between
two generalized variables as `unknown tactic`. -/
inductive Wrapped (a : Type) where
  | mk : a → Wrapped a

theorem generalizedInduction (theWrappedSubject : Wrapped Nat) (firstGeneralized : Nat)
    (secondGeneralized : Nat) :
    firstGeneralized + secondGeneralized = secondGeneralized + firstGeneralized := by
  induction hwrapped : theWrappedSubject using Wrapped.rec generalizing firstGeneralized secondGeneralized with
  | _ payload =>
  omega

/- A structure instance's `..`. It is also an application's placeholder suffix, so joining it onto the
line in front of it hands it to the `by` block that ended there and the instance loses its ellipsis. -/
structure Defaulted where
  first : Nat
  second : Nat := 0
  third : Nat := 0

def defaulted (n : Nat) : Defaulted :=
  { first := by
      exact n
    .. }

end NativeLayoutBoundaries
