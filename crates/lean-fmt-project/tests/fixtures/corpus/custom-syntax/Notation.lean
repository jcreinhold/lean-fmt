import Init

/-! Custom syntax: user notation, an infix operator, and a small macro. Exercises the
formatter on declarations whose bodies are not plain terms. -/

namespace Notation

def boxedAdd (a b : Nat) : Nat := a + b

infixl:65 " ⊞ " => boxedAdd

notation:70 "‖" a "‖" => a * a

@[simp] def triple (n : Nat) : Nat := n + n + n

macro "triple_of " n:term:max : term => `(triple $n)

theorem boxed_comm (a b : Nat) : a ⊞ b = b ⊞ a := by
  simp [boxedAdd, Nat.add_comm]

theorem norm_square (a : Nat) : ‖a‖ = a * a := rfl

example : triple_of 2 = 6 := rfl

end Notation
