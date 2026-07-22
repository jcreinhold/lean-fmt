/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Lean

public section

namespace AdapterSyntax

syntax (name := descriptorCommand) "descriptor_command" ident ":=" term : command

macro_rules
  | `(descriptor_command $name:ident := $value:term) => `(def $name := $value)

syntax (name := explicitCommand) "explicit_command" ident : command

macro_rules
  | `(explicit_command $name:ident) => `(def $name : Nat := 0)

@[formatter AdapterSyntax.explicitCommand]
meta def explicitCommandFormatter : Lean.PrettyPrinter.Formatter := do
  Lean.PrettyPrinter.Formatter.visitArgs do
    Lean.PrettyPrinter.Formatter.identNoAntiquot.formatter
    Lean.PrettyPrinter.Formatter.pushLine
    Lean.PrettyPrinter.Formatter.symbolNoAntiquot.formatter "explicit_command"

syntax (name := twiceTerm) "twice(" term ")" : term

macro_rules
  | `(twice($value:term)) => `($value + $value)

syntax (name := adapterExact) "adapter_exact" term : tactic

macro_rules
  | `(tactic| adapter_exact $proof:term) => `(tactic| exact $proof)

syntax (name := throwingCommand) "throwing_command" : command

macro_rules
  | `(throwing_command) => `(def unreachableFormatterFixture : Nat := 0)

@[formatter AdapterSyntax.throwingCommand]
meta def throwingCommandFormatter : Lean.PrettyPrinter.Formatter :=
  throwError "adapter fixture formatter failure"

end AdapterSyntax
