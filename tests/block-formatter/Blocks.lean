module

namespace BlockFixture

syntax "custom_assumption" : tactic

macro_rules
  | `(tactic| custom_assumption) => `(tactic| assumption)

theorem atomic (proposition : Prop) (proof : proposition) : proposition := by exact proof

theorem sequence (left right : Prop) (leftProof : left) (rightProof : right) : left ∧ right := by
  constructor
  · exact leftProof
  · exact rightProof

theorem alternatives (proposition : Prop) (proof : proposition) : proposition := by
  first
  | exact proof
  | assumption

theorem combinator : True ∧ True := by
  constructor <;> trivial

theorem custom (proposition : Prop) (proof : proposition) : proposition := by
  custom_assumption

theorem commented : True ∧ True := by
  constructor
  /- between focused goals -/
  · trivial
  · trivial

def matchBlock (value : Nat) : Nat :=
  match value with
  | 0 => by exact 1
  | _ => by
    exact value

def doBlock : Option Nat := do
  let first ← some 1
  let second := first + 1
  pure second

def idRunBlock : Nat := Id.run do
  let first := 1
  let second := first + 1
  pure second

def localDeclaration (value : Nat) : Nat := helper value
where
  helper (current : Nat) : Nat := current + 1

end BlockFixture
