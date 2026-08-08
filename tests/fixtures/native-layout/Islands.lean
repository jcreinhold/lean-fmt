/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Typed exact islands. Each case is a syntax or range class whose payload is source data rather than
layout: a token whose bytes span lines, an interpolated string, and a quotation with an antiquotation.

The multiline cases are the ones that pin the dedent. `Std.Format` re-indents every newline inside a
text leaf to the ambient indentation, so a payload carrying its own absolute columns has to cancel
that indentation to reach column zero. Growing this list by spelling rather than by class is what the
route audit rejected.

A change may replace the island mechanism; it may not move a payload byte. -/

public section

namespace NativeLayoutIslands

/- A string literal whose bytes span lines, with trailing spaces before the newline and a continuation
line that is indented in the source. Both are payload, not layout. -/
def multiline : String := "alpha
  beta
gamma"

/- The same payload one nesting level deeper, so the ambient indentation the dedent must cancel is
nonzero. -/
def nestedMultiline : Nat → String :=
  fun _ => "first
  second"

/-- A doc comment whose body spans lines.
Its second line owns its own column. -/
def documentedMultiline : Nat := 0

/- Interpolation is parsed source data: its holes are syntax and its chunks are bytes. -/
def interpolated (name : String) : String := s!"hello {name} and {name}"

/- A quotation containing an antiquotation. Formatting the quoted syntax is not the same operation as
formatting the quotation. -/
def quoted (value : Nat) : Lean.Syntax → Lean.MacroM Lean.Syntax := fun _ => `($(Lean.quote value))

/- A quotation holding two antiquotations at different depths, so protecting it escalates twice: the
inner one replaces a subtree with a marker leaf, and the outer one then has to measure a node one of
whose children no longer carries a position. Measuring the rewritten node instead of the original
truncates the island to the last surviving leaf, and it no longer covers the terminals its own marker
stands for. -/
def nestedEscalation (stx : Lean.Syntax) : Lean.MacroM Lean.Syntax :=
  match stx with
  | `($(_) fun $_:ident ↦ $body) => return body
  | _ => return stx

/- A *dynamic* quotation, whose body's parser is named by the identifier before the bar. That name is
read off the syntax stack, and Lean's formatter reads one slot short of where its parser wrote it, so
the formatter asks for a formatter registered under the bar and the command dies as
`Unknown constant «|»`. The class is the sole call site of `parserOfStack`, and its body is in a
category picked at parse time, so the quotation is one island. -/
def dynamicallyQuoted : Lean.MacroM Lean.Syntax := do
  let binders ← `(Lean.explicitBinders| (x : Nat))
  return binders

/- A `command` quotation. As far as the grammar is concerned the quoted `#eval` really is a command,
and every boundary rule reads the grammar -- so the nested-command rule collects it and asks for a
boundary that sets column zero. Those bytes belong to the island, which spells them itself and lets no
boundary through, and a collected boundary that is never applied refuses the command:
`Mathlib/Util/ParseCommand.lean` reported `applied 0/2 boundaries` for the two `command` quotations in
its `elab_rules`. A boundary that falls strictly inside an island is dropped once, for every rule.
-/
def quotedCommand (value : Lean.Term) : Lean.MacroM Lean.Syntax :=
  `(command| #eval $value)

/- The two sides, which is one question asked of every antiquotation: will anything in scope
format this node, or will the lookup fall through to its kind?

Below, `$_` heads an application and `$as:term` sits inside a splice group. Both carry a *category's*
pseudo kind, and a category is not a declaration, so when `categoryFormatterCore`'s own antiquotation
formatter declines them the fall-through asks `runForNodeKind` for `term.pseudo.antiquot` and gets
`Unknown constant`. They have to be protected. `$_:ident` in `nestedEscalation` above is the same
failure spelled with a token's kind in a category slot -- `funBinder` admits `ident`, and the printer
asks the category first.

`$name` in the quotation on the last line is the opposite case and the one that keeps the rule honest:
`declId` is a declared parser, its own formatter accepts `declId.antiquot`, and protecting it hands
`Command.quot` a leaf where a command belongs -- `uncaught backtrack exception`, which is how a
predicate that matched every antiquotation was caught. The base naming a constant is the whole
discriminator. -/
def spliceGroup : Lean.Syntax → Lean.MacroM Lean.Syntax
  | `(term| $_ $pat $val) => `($pat $val)
  | stx => return stx

def declarationQuotation (name : Lean.Ident) : Lean.MacroM Lean.Syntax :=
  `(def $name : Nat := 1)


/- The splice family, whose kinds name no formatter at all: `$[p]suffix` parses as
`sepBy.antiquot_scope` and `$x,*` as `sepBy.antiquot_suffix_splice` (`Lean/Parser/Basic.lean:1856-1878`),
and nothing in the toolchain dispatches on either — `withAntiquot.formatter` accepts `p.antiquot`
exactly, and the parser compiler generates no splice case. Every dispatch falls through to
`formatterForKind` and dies as `Unknown constant sepBy.antiquot_scope`, which is how a macro body
spelling `$[...];*` used to refuse its whole file. Unlike `declId.antiquot`, no declared parser's own
formatter accepts these, so the predicate protects the kinds with no base test. -/
macro "seq_intro" "[" h:term,* "]" : tactic => `(tactic| ($[have := $h];*))

def suffixSplice (xs : Array Lean.Term) : Lean.MacroM Lean.Syntax :=
  `(#[$xs,*])

structure BacktrackSent where

structure BacktrackTheo where
  mk ::

def BacktrackSent.Realize : Type → BacktrackSent → Prop := fun _ _ => True

class BacktrackTheo.Model (M : Type) (T : BacktrackTheo) : Prop where

infixl:51 " ⊨⊨ " => BacktrackSent.Realize
infixl:51 " ⊨⊨ " => BacktrackTheo.Model

/- A binder whose whole type is an application of a doubly-declared infix: the notation's two
declarations leave the application under a `choice`, and formatting the `class` side backtracks
uncaught -- upstream's `format: uncaught backtrack exception` (`Formatter.lean:655`), mathlib's
`⊨` (`Mathlib/ModelTheory/Semantics.lean:634,736`) in miniature. No alternative the adapter can
spell reparses to the elaborated tree, so the command degrades to its source bytes verbatim and
the rest of the file formats. The deliberately odd spacing below is the pin: it survives only
because the command is verbatim. -/
theorem backtrackBinder (M : Type) (T : BacktrackTheo) (hM : M   ⊨⊨
        T) : True := trivial

theorem formatsAroundBacktrack (n : Nat) : n + 0 = n := Nat.add_zero n

end NativeLayoutIslands

