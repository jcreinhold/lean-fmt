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

declare_syntax_cat adapter_item
syntax (name := adapterItem) ident : adapter_item
syntax (name := adapterItemTerm) "item_term(" adapter_item ")" : term

macro_rules
  | `(item_term($name:ident)) => `($name)

syntax (name := throwingCommand) "throwing_command" : command

macro_rules
  | `(throwing_command) => `(def unreachableFormatterFixture : Nat := 0)

@[formatter AdapterSyntax.throwingCommand]
meta def throwingCommandFormatter : Lean.PrettyPrinter.Formatter :=
  throwError "adapter fixture formatter failure"

syntax (name := invalidCommand) "invalid_command" : command

macro_rules
  | `(invalid_command) => `(def invalidFormatterFixture : Nat := 0)

/-- An intentionally unsafe extension formatter: it consumes the accepted token but emits a
different, incomplete command. Exact admission must reject its output after reparsing. -/
@[formatter AdapterSyntax.invalidCommand]
meta def invalidCommandFormatter : Lean.PrettyPrinter.Formatter := do
  Lean.PrettyPrinter.Formatter.visitArgs do
    let stx ← Lean.Syntax.MonadTraverser.getCur
    let Lean.Syntax.atom info _ := stx | throwError "invalid formatter fixture expected an atom"
    Lean.PrettyPrinter.Formatter.pushToken info "def" false
    Lean.Syntax.MonadTraverser.goLeft

syntax (name := extraTokenCommand) "extra_token_command" : command

macro_rules
  | `(extra_token_command) => `(def extraTokenFormatterFixture : Nat := 0)

@[formatter AdapterSyntax.extraTokenCommand]
meta def extraTokenCommandFormatter : Lean.PrettyPrinter.Formatter := do
  Lean.PrettyPrinter.Formatter.visitArgs do
    let stx ← Lean.Syntax.MonadTraverser.getCur
    let Lean.Syntax.atom info _ := stx | throwError "extra-token formatter expected an atom"
    Lean.PrettyPrinter.Formatter.pushToken info "extra" false
    Lean.PrettyPrinter.Formatter.pushToken info "tokens" false
    Lean.Syntax.MonadTraverser.goLeft

end AdapterSyntax
