module

public meta import Lean.Elab.Tactic.Basic

/-!
A file whose parser leaves a byte on no leaf at all.

`hygieneInfo` (`Lean/Parser/Basic.lean:1335-1357`) rewrites an already-pushed leaf's tail info to
steal that leaf's trailing whitespace. The rewritten leaf sits below the shrink point, so when the
attempt that ran it is abandoned `ParserState.restore` rewinds the stack and the position without
undoing the write, and the stolen space belongs to neither leaf. Writing an antiquotation is what
abandons the attempt; the `<|>` below is not the cause, and a lone `hygieneInfo` behind one strands
the byte alike (`docs/upstream-defects.md` §11).

Below, the space between `stranded_have` and `$n` in the quotation is that byte. The lossless
projection used to refuse the whole file for it ("leading trivia does not tile N-N+1"), which is
what `Mathlib/Tactic/Have.lean` and `Mathlib/Tactic/Replace.lean` hit through mathlib's
`optBinderIdent`. Nothing about the shape is exotic: this is the whole of what it takes.

Keep the quotation on one line and keep the space in it. Both are the defect.
-/

public meta section

namespace StrandedTrivia
open Lean Elab.Tactic Parser

/-- Mathlib's `optBinderIdent`, reduced to the branch that matters. -/
def optBinderIdent : Parser := leading_parser
  (ppSpace >> Term.binderIdent) <|> withResetCache hygieneInfo

syntax (name := strandedHave) "stranded_have" optBinderIdent : tactic

elab_rules : tactic
  | `(tactic| stranded_have $n:optBinderIdent) => do
    logInfo m!"{n.raw}"

end StrandedTrivia
