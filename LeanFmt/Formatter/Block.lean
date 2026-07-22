/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Offside term ownership over actual block nodes.

Lean's tactic and `do` registries already interpret their actual sequence/item trees and enforce the
parser's relative-column constraints. This module owns the block dispatch boundary without converting
those trees to source lines. Because the enclosing declaration establishes the block's base column,
that declaration stays in the live command registry whenever it contains an offside scope. There is
no source-column delta fallback here. -/

import Lean.Parser.Tactic
import Lean.Parser.Term
import all LeanFmt.Formatter

namespace LeanFmt.Internal.Formatter.Block

/-- Whether a subtree establishes an offside term scope. An enclosing formatter may use this to keep
the scope together with the syntactic shell that determines its base column. -/
partial def contains (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Term.byTactic || stx.isOfKind ``Lean.Parser.Term.do ||
    stx.isOfKind ``Lean.Parser.Term.match || stx.isOfKind ``Lean.Parser.Term.whereDecls ||
    stx.getArgs.any contains

/-- Return the actual block node's live registry document when `stx` establishes an offside term
scope. The supplied result prevents a duplicate registry traversal in the term dispatcher. -/
def formatTerm? (stx : Lean.Syntax)
    (registered : Except FormatterFailure RegisteredDocument) :
    Option (Except FormatterFailure RegisteredDocument) :=
  if contains stx && (stx.isOfKind ``Lean.Parser.Term.byTactic ||
      stx.isOfKind ``Lean.Parser.Term.do || stx.isOfKind ``Lean.Parser.Term.match ||
      stx.isOfKind ``Lean.Parser.Term.whereDecls) then
    some registered
  else none

end LeanFmt.Internal.Formatter.Block
