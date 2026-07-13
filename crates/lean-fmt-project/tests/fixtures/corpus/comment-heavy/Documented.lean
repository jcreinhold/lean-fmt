import Init

/-!
# A comment-heavy module

This file is mostly prose: a module docstring, declaration docstrings, line comments, and a
nested block comment. It exercises the formatter's comment/docstring preservation on a file
whose trivia far outweighs its code.
-/

-- A leading line comment attached to the first declaration.
/-- The additive identity, spelled out. -/
def zero : Nat := 0

/- A block comment.
   It spans several lines
   /- and nests another block comment inside it -/
   and then continues. -/
def one : Nat := zero + 1 -- trailing comment after a definition

/-- Double a number.

A second docstring paragraph, to exercise multi-paragraph docstring handling. -/
def twice (n : Nat) : Nat :=
  -- an interior line comment inside the body
  n + n

/-- `twice zero` is `zero`. -/
theorem twice_zero : twice zero = zero := rfl
