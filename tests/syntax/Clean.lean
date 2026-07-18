module
/-! Module documentation. -/
set_option maxHeartbeats 400000
namespace Foo
@[simp, reducible]
def a : Nat := (1 + 1)
structure S where
  x : Nat
deriving Repr, BEq
end Foo
