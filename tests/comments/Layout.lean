module

/- before import -/
import Lean

namespace CommentLayout

syntax "comment_leaf" : term
macro_rules
  /- before macro alternative -/
  | `(comment_leaf) => `(1)

variable {α : Type} /- between binders -/ (value : α)

def termComment (value : Nat) : Nat := value /- before operator -/ + comment_leaf

def collectionComment : List Nat := [
  1,
  /- before entry -/
  2,
]

theorem tacticComment (proposition : Prop) (proof : proposition) : proposition := by
  first
  | exact proof -- trailing tactic
  | /- alternative comment -/ assumption

def doComment : Option Nat := do
  -- leading item
  let value := 1 -- trailing item
  /- between items -/
  pure value

def matchComment (value : Option Nat) : Nat :=
  match value with
  | some current =>
    /- arm body -/
    current
  | none => 0

def whereComment (value : Nat) : Nat := helper value
where
  /- local declaration -/
  helper (current : Nat) : Nat := current + 1

end CommentLayout
