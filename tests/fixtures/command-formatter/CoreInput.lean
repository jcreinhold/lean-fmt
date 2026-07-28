module
import   Lean

namespace CommandFixture
universe   u v
variable {α:Type u} (value : α)
section Secondary
include value
omit value
end Secondary
open Nat hiding succ
export Nat (add mul)
set_option pp.universes false

syntax "identity!" term : term
notation "fortyTwo" => (42 : Nat)
macro_rules
| `(identity! $term) => `($term)

syntax "emit_custom" ident : command
macro_rules
| `(emit_custom $name) => `(def $name : Nat := 1)

emit_custom generated

@[inline] private def useIdentity : Nat := identity! generated
#check useIdentity
#eval useIdentity
#synth OfNat Nat 42
#print useIdentity
end CommandFixture
