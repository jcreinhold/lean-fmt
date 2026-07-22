module

import Lean

namespace TermFixture

syntax:65 term:66 " ⊕custom " term:65 : term

macro_rules
  | `($left ⊕custom $right) => `($left + $right)

def consumeFive (first second third fourth fifth : Nat) : Nat :=
  first + second + third + fourth + fifth

def application (alpha beta gamma delta epsilon : Nat) : Nat :=
  consumeFive alpha beta gamma delta epsilon

def identifiers (alpha beta : Nat) : Nat :=
  alpha + beta

def qualified (value : Nat) : Nat :=
  Nat.succ value + Nat.succ (Nat.succ value)

def precedence (alpha beta gamma delta : Nat) : Nat :=
  alpha + beta * gamma + delta

def customInsideApplication (alpha beta gamma delta : Nat) : Nat :=
  consumeFive (alpha ⊕custom beta) gamma delta alpha beta

def lambdaTerm : Nat → Nat → Nat :=
  fun first second => first + second

def sequentialLets (alpha beta gamma : Nat) : Nat :=
  let first := alpha + beta
  let second := first * gamma
  first + second

def conditional (condition : Bool) (yes no : Nat) : Nat :=
  if condition then yes else no

def projections (pair : Nat × Nat) : Nat :=
  pair.1 + pair.2

def namedArguments : List Nat :=
  List.map (f := fun value => value + 1) [1, 2, 3]

def quotation : Lean.MacroM (Lean.TSyntax `term) :=
  `(alpha + beta * gamma)

/- outer /- nested -/ payload -/
def c : Nat := 1

end TermFixture
