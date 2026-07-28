module

namespace DeclarationComments

/-- The declaration payload is exact. -/
@[inline] def value (input : Nat) : Nat := input -- trailing body payload

structure Pair where
  /-- The field payload is exact. -/
  left : Nat
  right : Nat

end DeclarationComments
