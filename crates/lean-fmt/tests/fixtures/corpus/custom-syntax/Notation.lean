import Init

/-! Custom syntax: user notation, an infix operator, and a small macro. Exercises the
formatter on the *declaration* forms whose bodies are not plain terms — `infixl`, `notation`,
and `macro`.

Note: this file only *declares* custom syntax; it does not *use* the new symbol tokens
(`⊞`, `‖ ‖`) in later declarations. The formatter's syntax-only parse does not register a
same-file notation's tokens before it reaches a later command, so a use of `⊞` here would lex
as an unknown token. Uses stay in terms of the underlying functions, keeping the file cleanly
parseable while still exercising the notation-declaration surface. -/

namespace Notation

def boxedAdd (a b : Nat) : Nat := a + b

infixl:65 " ⊞ " => boxedAdd

notation:70 "‖" a "‖" => a * a

@[simp] def triple (n : Nat) : Nat := n + n + n

macro "triple_of " n:term:max : term => `(triple $n)

theorem boxed_comm (a b : Nat) : boxedAdd a b = boxedAdd b a := by
  simp [boxedAdd, Nat.add_comm]

theorem triple_eq (n : Nat) : triple n = n + n + n := by
  simp [triple]

end Notation
