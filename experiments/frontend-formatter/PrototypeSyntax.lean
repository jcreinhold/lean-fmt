/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Lean

public section

namespace FormatterPrototypeSyntax

syntax (name := prototypeTerm) "prototype_term(" term,* ")" : term
macro_rules
  | `(prototype_term($terms,*)) => `([$terms,*])

syntax (name := prototypeTactic) "prototype_exact " term : tactic
macro_rules
  | `(tactic| prototype_exact $term) => `(tactic| exact $term)

syntax (name := prototypeCommand) "prototype_command " ident " := " term : command
macro_rules
  | `(prototype_command $name:ident := $term:term) => `(def $name := $term)

end FormatterPrototypeSyntax
