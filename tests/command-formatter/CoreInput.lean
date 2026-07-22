module
import   Lean

namespace CommandFixture
universe   u v
variable {α:Type u} (value : α)
open Nat hiding succ
export Nat (add mul)
set_option pp.universes false

syntax "identity!" term : term
macro_rules
| `(identity! $term) => `($term)

syntax "emit_custom" ident : command
macro_rules
| `(emit_custom $name) => `(def $name : Nat := 1)

emit_custom generated

def useIdentity : Nat := identity! generated
end CommandFixture
