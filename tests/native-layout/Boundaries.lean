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
a field's docstring onto the structure and leaves the native separator where the docstring was. -/

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

structure Fields where
  /-- A field doc comment stays on its field, not on the structure. -/
  first : Nat
  second : Nat

inductive Choice where
  /-- A constructor doc comment stays on its constructor. -/
  | left
  | right

def danglingOwner : Nat := Id.run do
  let value := 8
  return value
  -- dangling comment after the last statement

end NativeLayoutBoundaries
