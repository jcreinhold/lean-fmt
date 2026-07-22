/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Lean

public section

namespace AuditTarget

syntax (name := auditTerm) "audit_term(" term,* ")" : term
macro_rules
  | `(audit_term($terms,*)) => `([$terms,*])

syntax (name := auditTactic) "audit_exact " term : tactic
macro_rules
  | `(tactic| audit_exact $term) => `(tactic| exact $term)

syntax (name := auditCommand) "audit_command " ident " := " term : command
macro_rules
  | `(audit_command $name:ident := $term:term) => `(def $name := $term)

syntax (name := explicitCommand) "explicit_command" : command
macro_rules
  | `(explicit_command) => `(#check Nat)

@[formatter AuditTarget.explicitCommand]
meta def explicitCommandFormatter : Lean.PrettyPrinter.Formatter := do
  Lean.PrettyPrinter.Formatter.push "EXPLICIT_FORMATTER_WON"

infixl:65 " <+> " => Nat.add

end AuditTarget
