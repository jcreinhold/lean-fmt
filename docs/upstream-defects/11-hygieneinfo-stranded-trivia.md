# 11. `hygieneInfo` strands the whitespace it steals when its node is discarded

Not a pretty-printer defect — a parser defect. `hygieneInfoFn` moves the preceding token's trailing whitespace onto a
node it builds, and when the parse attempt that ran it is abandoned, the rewrite outlives the node: the moved whitespace
belongs to no leaf, and the syntax tree is no longer a linear cover of the file's bytes. Writing an antiquotation is
enough to abandon the attempt.

**Upstream:** `hygieneInfoFn` (`src/Lean/Parser/Basic.lean:1335-1357`) places its node immediately after the preceding
token and moves that token's trailing whitespace onto itself: it rewrites the leaf below it on the stack to carry an
*empty* trailing substring and keeps the real one for the node it builds (`:1347-1353`). The comment there says why — so
that combinators like `ws` are unaffected by a neighbouring `hygieneInfo`. But `ParserState.restore`
(`src/Lean/Parser/Types.lean:351-352`) shrinks the stack and resets the position; the rewritten leaf sits *below* the
shrink point, so its emptied trailing survives the rewind. Mathlib reaches this through `optBinderIdent`, which is how
`Mathlib/Tactic/Have.lean` and `Mathlib/Tactic/Replace.lean` hit it, but that parser's own `<|>` is not the cause: a
lone `hygieneInfo` behind an antiquotation strands the byte just the same.

## Reproduce

Not a formatting probe — parse a term and check that the leaves cover it:

```lean
import Lean
open Lean Elab Parser

def optBinderIdent : Parser := leading_parser
  (ppSpace >> Term.binderIdent) <|> withResetCache hygieneInfo

syntax (name := strandedHave) "stranded_have" optBinderIdent : tactic

def onlyHygiene : Parser := leading_parser withResetCache hygieneInfo

syntax (name := onlyHave) "only_have" onlyHygiene : tactic

def noHygiene : Parser := leading_parser ppSpace >> Term.binderIdent

syntax (name := plainHave) "plain_have" noHygiene : tactic

partial def spans : Syntax → Array (String × Nat × Nat × Nat)
  | .node _ _ args => args.flatMap spans
  | .atom (.original l p t _) v =>
    #[(v.quote, l.startPos.byteIdx, p.byteIdx, t.stopPos.byteIdx)]
  | .ident (.original l p t _) r .. =>
    #[(toString r, l.startPos.byteIdx, p.byteIdx, t.stopPos.byteIdx)]
  | _ => #[]

def report (s : String) : CoreM Unit := do
  match runParserCategory (← getEnv) `term s with
  | .error message => IO.println s!"parse error: {message}"
  | .ok stx =>
    let mut cursor := 0
    for (v, leadStart, pos, trailStop) in spans stx do
      if leadStart > cursor then
        IO.println s!"  HOLE {cursor}-{leadStart}: \
          {(String.fromUTF8? (s.toUTF8.extract cursor leadStart)).getD "?" |>.quote} \
          before {v} at {pos}"
      cursor := max cursor trailStop
    IO.println s!"  covered to {cursor} of {s.utf8ByteSize}"

#eval show CoreM Unit from do
  report "`(tactic| stranded_have $n:optBinderIdent)" -- HOLE 23-24: " " before "$"
  report "`(tactic| stranded_have h)"                 -- covered to 26 of 26
  report "`(tactic| only_have $n:onlyHygiene)"        -- HOLE 19-20: " " before "$"
  report "`(tactic| only_have)"                       -- covered to 20 of 20
  report "`(tactic| plain_have $n:noHygiene)"         -- covered to 34 of 34
```

Rows three and four are the pair that isolates it: the same parser, with no alternative anyone wrote, strands a byte
when its node is discarded and none when the node is kept. Row five is the control — the identical shape with no
`hygieneInfo` in it covers its source.

**A correction this file is recording.** `LeanFmt/LosslessSource.lean` and `tests/fixtures/check/StrandedTrivia.lean`
both said a `takeLongest` discarding the hygieneInfo node was what did it. Row three refutes that: `onlyHygiene` has one
branch and strands the byte anyway. What combinator abandons the attempt behind an antiquotation was not pinned here —
only that discarding is what matters and that a second user-written branch is not needed for it. Both records now say
that instead.

## What it costs lean-fmt

Nothing now, and it cost eight mathlib files before. `leadingStart` (`LeanFmt/LosslessSource.lean`) derives a leading
run's content from contiguity — from the previous positioned leaf's trailing stop — rather than from the `leading`
substring the parser recorded, which closes the hole. `Token.leading`'s contract already said contiguity determines
where a leading run begins, so this makes the contract true rather than merely intended, and it is the mechanism §10
then had to teach about leaves that spell nothing.

## Pinned by

`tests/fixtures/check/StrandedTrivia.lean` reduces it to a file, and the `lossless` suite's `stranded-trivia` case
asserts both halves: the projection covers the byte, and the independent oracle — which re-tiles the parser's
attribution verbatim — still reports it missing. That disagreement is the defect, stated from both sides. No
`Probe.lean` row — nothing here is formatted.
