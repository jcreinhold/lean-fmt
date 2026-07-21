module

/- Which token owns each comment.

The roadmap requires these rules be "derived from the lossless source model" rather than invented, and
`RLS-SPEC` already settled the hard half: comments are not tree nodes, they live in the `leading` and
`trailing` runs of `Token`. That leaves one question, and `RLC-SPEC` measured the answer on the
shipping toolchain rather than reading it off a docstring.

**The parser does not split trivia, so this module must.** `Lean.Syntax.updateLeading`
(`Lean/Syntax.lean:304`) is documented to split a token's trailing run at the first newline via
`chooseNiceTrailStop` "so that e.g. comments are associated to the (intuitively) correct token", and
its own docstring states "after parsing, all `SourceInfo.leading` fields are empty". It has **no
caller in the 4.32 tree**. Measuring the leaves of a parsed module confirms it: leading runs are
empty, comments appear only in trailing runs, and the parser is trailing-greedy. One trailing run
routinely holds a trailing comment, a blank line, and the next declaration's leading comments
together. So the split is ours, and this module adopts `chooseNiceTrailStop`'s rule — split at the
first newline — with one correction that preservation forces; see `splitPoint`.

`leading` is handled anyway rather than assumed empty. The projection permits a non-empty leading run,
and a rule that is only correct because of a fact measured on one toolchain should not also be
*unable* to express the other case. -/

import all LeanFmt.LosslessSource

namespace LeanFmt.Internal

/-- A comment, located in the normalized source. `kind` is `lineComment` or `blockComment`; whitespace
trivia is not a comment and never appears here. -/
structure Comment where
  kind : TriviaKind
  range : SourceRange
  deriving Inhabited, BEq, Repr

/-- The comments owned by one token.

`leading` comments sit on their own lines before the token; `trailing` comments sit on the token's own
line, after it. Blank-line runs fall in the leading region, which is where a formatter wants them:
they precede the declaration they separate. -/
structure TokenComments where
  leading : Array Comment := #[]
  trailing : Array Comment := #[]
  deriving Inhabited, BEq, Repr

/-- Every comment in a module, each assigned to exactly one owner.

Two fields name regions the layout engine **cannot** attach. Naming them is the point — a token model
has no third place to hide a comment, and a formatter that discovers these late has already lost them:

* `header` — `[0, headerStop)`, the module header. Not attachable, and its comments are not even in
  this projection: the trivia tiling *begins* at `headerStop`, so there is nothing here to enumerate.
  That is why it names a region rather than comments. A module linter never receives the header.
  Measured: one header leaf carries both the module docstring and the first declaration's leading
  comment.
* `trailer` — after the last token's split point, out to `terminalStop`. These are the genuinely
  *dangling* comments: the first-newline rule assigns them to "the next token", and at end of file
  there is none. AST formatters meet this case inside empty constructs and invent a "dangling"
  category for it; in a token model it arises once, at the end, and it is structural, not a
  heuristic.

`tokens` is index-aligned with `LosslessSource.tokens`. -/
structure Attachment where
  header : SourceRange := ⟨0, 0⟩
  tokens : Array TokenComments := #[]
  trailer : Array Comment := #[]
  deriving Inhabited, BEq, Repr

namespace Attachment

/-- Every comment this attachment owns, in source order. The header region is left out: the trivia
tiling starts after it, so it holds no attachable comment. -/
def all (a : Attachment) : Array Comment := Id.run do
  let mut out := #[]
  for tc in a.tokens do
    out := out ++ tc.leading ++ tc.trailing
  return out ++ a.trailer

end Attachment

namespace Comments

private def isComment : TriviaKind → Bool
  | .lineComment | .blockComment => true
  | .whitespace => false

/-- Byte offset of the first `'\n'` in `[start, stop)`, or `stop` if there is none. -/
private partial def firstNewline (source : String) (start stop : Nat) : Nat :=
  let rec loop (p : String.Pos.Raw) : Nat :=
    if p.byteIdx >= stop then stop
    else if p.get source == '\n' then p.byteIdx
    else loop (p.next source)
  loop ⟨start⟩

/-- Where a token's trailing run stops belonging to that token.

This is `chooseNiceTrailStop` with one correction. Lean computes `trail.posOf '\n'` — a raw character
scan with no idea what it is scanning. A **block comment may contain newlines**, so on
`def x := /- multi⏎line -/ 0` that scan splits *inside* the comment. Lean survives it because it only
moves a substring boundary and `leading ++ trailing` still reconstructs the text. This module does
not: it attaches whole comments by range, so a comment straddling the split would belong to neither
side and be lost. "Preserve every comment exactly once" is a roadmap stop rule, not a preference.

So the split is the first newline **outside any comment** — equivalently, the first newline inside a
`whitespace` trivia. That is not a heuristic: a line comment cannot contain a newline (`LosslessSource.scanTrivia` records "`--` runs to, but does not include, the newline;
`whitespace` takes the newline itself"), so the only comment a raw scan can tear is a block one, and
the projection already tells us which trivia is which. A multi-line block comment therefore stays whole
and belongs to the token whose line it starts on.

The newline itself is not on the trailing side; it opens the next token's leading region. -/
private def splitPoint (source : String) (run : Array Trivia) (start stop : Nat) : Nat := Id.run do
  let mut cursor := start
  for trivia in run do
    if trivia.kind == .whitespace then
      let newline := firstNewline source cursor trivia.stop
      if newline < trivia.stop then
        return newline
    cursor := trivia.stop
  return stop

/-- Comments of one trivia run lying within `[lo, hi)`.

The run tiles `[start, ...)` in order and stores only stops, so each trivia's start is its
predecessor's stop. `lo`/`hi` clip the run rather than partition it, because the split point can fall
inside a whitespace trivia — `"\n\n"` is one trivia — and, by `splitPoint`, never inside a comment. -/
private def commentsIn (run : Array Trivia) (start lo hi : Nat) : Array Comment := Id.run do
  let mut out := #[]
  let mut cursor := start
  for trivia in run do
    if isComment trivia.kind && cursor >= lo && trivia.stop <= hi then
      out := out.push { kind := trivia.kind, range := ⟨cursor, trivia.stop⟩ }
    cursor := trivia.stop
  return out

/-- Assign every comment in `source` to exactly one owner.

`normalized` must be the string `source` was projected from; `LosslessSource.validFor` checks that.
Per token: its **trailing** comments are those before its split point, on its own line; the **next**
token's **leading** comments are everything from there to that token's start — which spans the tail of
this token's trailing run *and* the next token's own leading run, since the two tile one contiguous
region between the tokens.

The result partitions the comment trivia of `[headerStop, terminalStop)`: every comment is owned once,
by exactly one of `tokens[i].leading`, `tokens[i].trailing`, or `trailer`. `Comments.partitions`
checks it, and `structurallyValid` already guarantees the tiling this relies on. -/
def attach (source : LosslessSource) (normalized : String) : Attachment := Id.run do
  let toks := source.tokens
  let mut tokens : Array TokenComments := #[]
  -- The previous token's split point: where the current token's leading region opens.
  let mut carry := source.headerStop
  for i in [0:toks.size] do
    let token := toks[i]!
    -- Leading spans two runs: what the previous token disowned past its split, then this token's own
    -- leading run. Both are empty on 4.32, and neither is assumed to be.
    let previousTrailingStop := if i = 0 then source.headerStop else toks[i - 1]!.trailingStop
    let mut leading := #[]
    if i > 0 then
      let previous := toks[i - 1]!
      leading := commentsIn previous.trailing previous.stop carry previousTrailingStop
    leading := leading ++ commentsIn token.leading previousTrailingStop previousTrailingStop token.start
    let split := splitPoint normalized token.trailing token.stop token.trailingStop
    tokens := tokens.push {
      leading
      trailing := commentsIn token.trailing token.stop token.stop split }
    carry := split
  -- Whatever the last token disowned has no next token to claim it. `structurallyValid` guarantees
  -- the last trailing stop is `terminalStop`, so this is exactly `[carry, terminalStop)`.
  let trailer := match toks.back? with
    | none => #[]
    | some last => commentsIn last.trailing last.stop carry last.trailingStop
  return { header := ⟨0, source.headerStop⟩, tokens, trailer }

/-- Every comment the projection records, in source order, regardless of ownership.

This is deliberately computed a different way from `attach` — straight off the runs, with no split and
no regions — so that `partitions` compares two independent walks rather than one walk against itself. -/
def allTrivia (source : LosslessSource) : Array Comment := Id.run do
  let mut out := #[]
  let mut cursor := source.headerStop
  for token in source.tokens do
    out := out ++ commentsIn token.leading cursor cursor token.start
    out := out ++ commentsIn token.trailing token.stop token.stop token.trailingStop
    cursor := token.trailingStop
  return out

/-- Does `attach` own every recorded comment exactly once, and invent none?

This is the roadmap's "preserve every comment exactly once" reduced to a decidable check. It is
meaningful rather than circular because `structurallyValid` independently guarantees that the trivia
runs tile `[headerStop, terminalStop)` exactly once: attachment is a partition of that tiling, so
agreeing with `allTrivia` as an ordered sequence means no comment was dropped, duplicated, or moved. -/
def partitions (source : LosslessSource) (normalized : String) : Bool :=
  (attach source normalized).all == allTrivia source

end Comments

end LeanFmt.Internal
