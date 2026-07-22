/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Offside term ownership over actual block nodes.

Lean's tactic and `do` registries already interpret their actual sequence/item trees and enforce the
parser's relative-column constraints. This module owns the block dispatch boundary without converting
those trees to source lines. In particular, an enclosing structural declaration may embed one opaque
block document instead of preserving the complete command. Prompt 14 adds custom comment documents;
there is no source-column delta fallback here. -/

import Lean.Parser.Tactic
import Lean.Parser.Term
import all LeanFmt.Formatter

namespace LeanFmt.Internal.Formatter.Block

/-- Return the actual block node's live registry document when `stx` establishes an offside term
scope. The supplied result prevents a duplicate registry traversal in the term dispatcher. -/
def formatTerm? (stx : Lean.Syntax)
    (registered : Except FormatterFailure RegisteredDocument) :
    Option (Except FormatterFailure RegisteredDocument) :=
  if stx.isOfKind ``Lean.Parser.Term.byTactic || stx.isOfKind ``Lean.Parser.Term.do ||
      stx.isOfKind ``Lean.Parser.Term.match || stx.isOfKind ``Lean.Parser.Term.whereDecls then
    some registered
  else none

end LeanFmt.Internal.Formatter.Block
