import Init

/-! Mathlib-style idioms — a typeclass with structure fields, instances, and `by` proofs —
written from scratch (no Mathlib import) so the file parses standalone. -/

namespace Algebra

/-- A commutative monoid on `Nat`-valued carriers, stated as a bare structure. -/
class CommMonoidLike (α : Type) where
  op : α → α → α
  unit : α
  op_comm : ∀ a b, op a b = op b a
  op_unit : ∀ a, op a unit = a

namespace CommMonoidLike

variable {α : Type} [CommMonoidLike α]

theorem unit_op (a : α) : op unit a = a := by
  rw [op_comm]
  exact op_unit a

instance : CommMonoidLike Nat where
  op := Nat.add
  unit := 0
  op_comm := Nat.add_comm
  op_unit := Nat.add_zero

example : op (2 : Nat) 3 = 5 := rfl

end CommMonoidLike

end Algebra
