/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- The native grammar-layout adapter.

Lean's registered formatter remains the grammar authority. This module transforms its public
`Std.Format` algebra directly: native non-comment leaves are aligned with the selected source-covering
terminals and replaced by their original bytes, while groups, fills, nesting, alignment, and tags
remain native. Source-data syntax is replaced before formatter execution by a typed marker and restored
at that marker; this prevents a private formatter failure or normalization from becoming a source-text
fallback.

Two corrections sit on top of that, both collected from grammar shape and both refusing the command if
the document turns out not to have the node they name. A `BoundaryLayout` replaces the layout between
two named terminals with a space, a newline, or nothing. An `OffsideConstraint` adds a `nest` the
document never had, over exactly one source range, on the node its `ConstraintCarrier` names — the
`append` that carries the break before the range, or the `nest` the document wrapped the range in. Both
are documented at their declarations, including why the carrier is not a predicate and why a flat
boundary is not free.

Doc comments are syntax, not trivia, so they are ordinary terminals: their opening token and body align
and emit original bytes exactly where their owner spells them. Hoisting them to a command prefix moved
a field or constructor docstring off its owner and left the native separator behind, which is why no
prefix mechanism exists here.

An exact island whose payload spans lines carries its own absolute source columns. `Std.Format`
re-indents every newline inside a `text` leaf to the ambient indentation, and that indentation is
exactly the sum of the enclosing `nest` amounts plus the column the leaf is rendered at — `align` pads
output without changing it (`Init/Data/Format/Basic.lean`). The adapter therefore wraps a multiline
island in a `nest` that cancels both, and `Int.toNat` clamps the result to column zero. The sum
includes the constraint nests an ancestor has not applied yet, which the walk cannot have seen and
`containingConstraintNest` reads out of the spans instead.

The adapter has no core/extension gate and no command/term/tactic visitor. A failure is a typed refusal
with the root category, kind, range, resolution trace, native leaf index, and nearby source terminals.
-/

import Lean.Parser.StrInterpolation
import all LeanFmt.Formatter

namespace LeanFmt.Internal

namespace Formatter.NativeLayout

private structure Terminal where
  syntaxSpelling : String
  sourceSpelling : String
  range : SourceRange
  deriving Inhabited

private structure ExactIsland where
  marker : String
  range : SourceRange
  text : String
  /- Whether the payload is a comment. Lean ends a token's trailing trivia at the end of its line, so
  which side of a line break a comment falls on decides whether it is the previous token's trailing
  comment or the next token's leading one. That is the one layout question a comment's own bytes
  cannot answer, and it is the only reason this flag exists. -/
  comment : Bool := false
  deriving Inhabited

private structure InteriorComment where
  payload : String
  range : SourceRange
  placement : CommentPlacement
  kind : CommentKind
  boundary : Nat := 0
  deriving Inhabited

/- Which native node an indentation constraint is written on.

A constraint names a source range, and more than one node in the document spells exactly that range:
the `nest` the formatter put around it and the `append` that joins it to the break before it are both
candidates, and they mean different things. The `append` moves the break *and* what follows it, which
is what an offside sibling needs. The `nest` moves only what is inside it, which is what a wrong nest
needs cancelled.

Left to a single predicate this is not a choice at all -- the walk is post-order, so whichever node is
deeper claims the constraint, and for a guarded `let` that is the `nest`, which dedents the body
without moving the break above it and puts the siblings back inside the guard. So the constraint
carries its carrier and `finishConstraint` matches on it. A carrier that never appears leaves the
applied count short and refuses the command, so this cannot silently pick the wrong one. -/
private inductive ConstraintCarrier where
  | boundary
  | nest
  deriving BEq, Inhabited

private structure OffsideConstraint where
  range : SourceRange
  indentAdjustment : Int
  carrier : ConstraintCarrier
  deriving Inhabited

/- What the adapter puts at one boundary in place of whatever the native document laid out there.

A boundary is the layout between two terminals, and these are the three things it can be. Each is a
correction to Lean's own document, collected by grammar shape and applied by terminal index, so a rule
that needs one names the terminal and the spelling and nothing else.

The mechanism is one substitution; the constructors are its values. `flat` joins what the document
broke, `hard` breaks what it joined, and `elided` removes a separator the document spelled twice.

`flat` is not free and is not the default reading of "this should be on one line". `.text " "` cannot
break, so the renderer re-measures and breaks at the next soft line instead. When that next line is
inside the construct whose boundary was just moved, its continuation is indented from the enclosing
`nest` rather than from the column the boundary moved, and offside-sensitive syntax reparses. The
guarded `let`'s bar was reverted once for exactly that (`7e838a1`) and is joined today only because
`collectGuardBailouts` pairs the boundary with a flatten that leaves no soft line behind — a `flat`
alone would not be sound there. `hard` and `elided` do not have this failure mode: neither can make a
line longer. -/
private inductive BoundaryLayout where
  | flat
  | hard
  | elided
  deriving BEq, Inhabited

private def BoundaryLayout.format : BoundaryLayout → Std.Format
  | .flat => .text " "
  | .hard => .text "\n"
  | .elided => .nil

private structure TokenSpan where
  start : Nat
  stop : Nat
  deriving Inhabited, BEq

/-- Deterministic work performed while adapting one native formatter result. -/
structure Metrics where
  nativeNodes : Nat := 0
  tokenLeaves : Nat := 0
  commentLeaves : Nat := 0
  normalizedTokens : Nat := 0
  exactIslands : Nat := 0
  exactIslandBytes : Nat := 0
  offsideConstraints : Nat := 0
  commentConstraints : Nat := 0
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- One direct native-layout result before whole-module rendering and validation. -/
structure Document where
  document : Doc
  trace : FormatterTrace
  metrics : Metrics
  deriving Inhabited

private def sourceRange? (stx : Lean.Syntax) : Option SourceRange := do
  let range ← stx.getRange?
  return ⟨range.start.byteIdx, range.stop.byteIdx⟩

private def slice (source : String) (range : SourceRange) : String :=
  (String.fromUTF8? (source.toUTF8.extract range.start range.stop)).getD ""

private def isDocSyntax (kind : Lean.Name) : Bool :=
  kind == ``Lean.Parser.Command.docComment || kind == ``Lean.Parser.Command.moduleDoc

-- A comment has no interior layout. Lean's derived formatter spells a doc comment as its opening
-- token, a `Format.line`, and its body, so at a narrow width it would break a comment across the
-- separator its source never had. The whole comment is therefore one exact island covering both
-- terminals, and the marker replaces the body: the island's own bytes are the only rendering.
private def docSyntaxBody? (stx : Lean.Syntax) : Option Lean.Syntax := do
  guard (isDocSyntax stx.getKind)
  stx.getArgs[1]?

private partial def terminalsFrom (source : String) (stx : Lean.Syntax)
    (result : Array Terminal := #[]) : Array Terminal :=
  match stx with
  | .missing => result
  | .atom _ syntaxSpelling =>
    match sourceRange? stx with
    | some range =>
      let sourceSpelling := slice source range
      if sourceSpelling.isEmpty then result
      else result.push { syntaxSpelling, sourceSpelling, range }
    | none => result
  | .ident _ raw _ _ =>
    match sourceRange? stx with
    | some range =>
      let sourceSpelling := slice source range
      if sourceSpelling.isEmpty then result
      else result.push { syntaxSpelling := raw.toString, sourceSpelling, range }
    | none => result
  | .node _ kind children =>
    if kind == Lean.choiceKind then
      match children[0]? with
      | some selected => terminalsFrom source selected result
      | none => result
    else
      children.foldl (init := result) fun terminals child =>
        terminalsFrom source child terminals

/- Verify what `terminalsFrom` assumes.

`Lean.Syntax.reprint` (`Syntax.lean:400`) reprints *every* alternative of a `choice` node and refuses
when they disagree. `terminalsFrom` takes `children[0]?` and assumes agreement, and so do the three
other walks below that spell `children[0]?` for the same reason -- `selectedLeafRanges`,
`collectIndentedSequenceStarts`, and `collectOffsideConstraints`. That is four assumptions, not four
checks, on a node this repository records hitting 1 of 5 sampled mathlib modules. One gate at the entry
point makes the assumption true for all of them rather than repeating the comparison four times.

What has to agree is what the adapter consumes: each alternative's ordered terminal sequence, compared
on `(range, sourceSpelling)`. Those two are not independent -- `terminalsFrom` sets
`sourceSpelling := slice source range` -- so the comparison reduces to range-sequence equality, and
carrying the spelling along only makes the refusal message readable. That reduction is the point: for
leaves that carry original `SourceInfo`, equal range sequences are exactly what makes `reprint`'s
`lead ++ val ++ trail` agree, so this checks the same property `reprint` does.

`syntaxSpelling` deliberately does not participate. An `atom` and an `ident` over the same bytes spell
it differently and emit the same source, so comparing it would refuse a file that is fine.

Every alternative is descended into, not only the first, so a disagreement nested inside an unselected
alternative is still found. `reprint` does the same.

What this gate does *not* cover is a question about a leaf's *constructor* rather than its bytes: two
alternatives could in principle spell identical source with an atom on one side and an ident on the
other. No walk below asks that today -- `containsAtom` did, and went with the record-update rule that
used it -- and no such node has been observed, so it is recorded here rather than guarded. -/
private def choiceSpelling (source : String) (alternative : Lean.Syntax) :
    Array (SourceRange × String) :=
  (terminalsFrom source alternative).map fun terminal => (terminal.range, terminal.sourceSpelling)

private def renderChoiceSpelling (terminals : Array (SourceRange × String)) : String :=
  String.intercalate " " (terminals.toList.map fun (range, text) => s!"{range.start}:{repr text}")

private partial def choiceDisagreement? (source : String) (stx : Lean.Syntax) :
    Option (SourceRange × Nat × String × String) :=
  match stx with
  | .node _ kind children =>
    let here :=
      if kind == Lean.choiceKind then
        match children[0]? with
        | none => none
        | some first =>
          let expected := choiceSpelling source first
          match (children.extract 1 children.size).findIdx?
              (fun alternative => choiceSpelling source alternative != expected) with
          | some offset =>
            match children[offset + 1]? with
            | none => none
            | some actual =>
              some (sourceRange? stx |>.getD ⟨0, 0⟩, offset + 1,
                renderChoiceSpelling expected, renderChoiceSpelling (choiceSpelling source actual))
          | none => none
      else none
    match here with
    | some found => some found
    | none => children.findSome? (choiceDisagreement? source)
  | _ => none

/- The two interpolation kinds Lean defines: the interpolated string itself and its literal chunks.
Naming them is not the same as testing `kind.toString.contains "interpolatedStr"`, which this replaced:
that also matched every antiquotation kind derived from them, because an antiquotation kind is built by
appending to the kind it quotes. -/
private def interpolationKind (kind : Lean.Name) : Bool :=
  kind == Lean.interpolatedStrKind || kind == Lean.interpolatedStrLitKind

/- A *pseudo* antiquotation node, and only that. `Lean.Parser.mkAntiquot` builds the kind as
`kind ++ (if isPseudoKind then `pseudo else .anonymous) ++ `antiquot`, where `isPseudoKind` means the
kind is not checked at syntax `match`; this matches the two trailing components that spelling produces.

Ordinary antiquotations are deliberately excluded. Every antiquotation has a registered formatter
(`mkAntiquot.formatter`), so protecting one buys nothing -- and it costs: protection escalates to the
smallest enclosing node, which is replaced by a marker leaf, and a quotation whose typed child has
become a leaf no longer matches the grammar its formatter expects. Widening this predicate to all
antiquotations made `macro_rules | `(emit_custom $name) => ...` fail with `uncaught backtrack
exception`, because the `command` quotation was handed an atom where a command node belonged.

This is spelled structurally rather than as `kind.toString.contains ".pseudo.antiquot"`, which asked
the same question of the rendered name and so could also match a kind that merely contains that text. -/
private def antiquotationKind (kind : Lean.Name) : Bool :=
  match kind with
  | .str (.str _ "pseudo") "antiquot" => true
  | _ => false

private def sourceDataKind (kind : Lean.Name) : Bool :=
  kind == Lean.interpolatedStrKind || antiquotationKind kind

/- A quotation whose body was parsed by a parser named at runtime, which Lean's formatter cannot
recover. This is the second ordinary upstream bug the module works around.

`Lean.Parser.Term.dynamicQuot` -- `` `(cat| body) ``, `Lean/Parser/Term.lean:1033` -- parses `body` with
`parserOfStack 1`, which reads the parser's name off the syntax stack. At parse time that is the `ident`:
`parserOfStackFn` takes `stack.get! (stack.size - offset - 1)` and the stack top is the `"| "` atom
(`Lean/Parser/Extension.lean:772`). At format time `parserOfStack.formatter` takes
`parents.back!.getArg (idxs.back! - offset)` (`Lean/PrettyPrinter/Formatter.lean:319`), and `idxs.back!`
is the index of the argument being visited, so the same `offset` lands one slot short -- on the `"| "`
atom rather than the `ident`. The formatter then asks `formatterForKind` about an atom, whose kind is
`Name.mkSimple "|"`, and the command dies as `Unknown constant «|»`. Four of the seventy-two sampled
mathlib modules refused on exactly that.

Keying on this kind is keying on the *only* call site of `parserOfStack` in the toolchain, so no other
node can reach that formatter; it is not a shape added because it was seen to fail. The body's category
is chosen at parse time, so there is no grammar here whose layout lean-fmt could validate either. The
quotation is therefore one exact island, and its source bytes are its whole rendering. -/
private def dynamicQuotationKind (kind : Lean.Name) : Bool :=
  kind == ``Lean.Parser.Term.dynamicQuot

/- A marker stands in for protected syntax while the formatter runs, so it has to be a spelling the
formatter cannot confuse with a real token. `command` rejects a source that already spells one rather
than trusting the shape to be unusual; see `markerCollision?`. -/
private def markerFor (range : SourceRange) : String :=
  s!"leanFmtExact{range.start}x{range.stop}"

/- A placeholder replaces the syntax it protects, so it must keep that syntax's leaf constructor:
Lean's formatter for a literal token calls the atom printer and refuses an identifier with `not an
atom`. Only a protected interior node, which has no single spelling of its own, becomes an identifier. -/
private def placeholder (protected? : Lean.Syntax) (info : Lean.SourceInfo)
    (marker : String) : Lean.Syntax :=
  match protected? with
  | .atom .. => .atom info marker
  | _ => .ident info marker.toRawSubstring marker.toName []

private def stripTriviaInfo : Lean.SourceInfo → Lean.SourceInfo
  | .original leading position trailing endPos =>
    .original { leading with stopPos := leading.startPos } position
      { trailing with stopPos := trailing.startPos } endPos
  | info => info

private partial def withoutTrivia : Lean.Syntax → Lean.Syntax
  | .node info kind children =>
    .node (stripTriviaInfo info) kind (children.map withoutTrivia)
  | .atom info value => .atom (stripTriviaInfo info) value
  | .ident info raw value preresolved =>
    .ident (stripTriviaInfo info) raw value preresolved
  | .missing => .missing

private structure ProtectedSyntax where
  stx : Lean.Syntax
  islands : Array ExactIsland := #[]
  pendingEnvelope : Bool := false
  deriving Inhabited

private def exactPlaceholder (source : String) (stx : Lean.Syntax)
    (info : Lean.SourceInfo) : ProtectedSyntax :=
  match sourceRange? stx with
  | some range =>
    let marker := markerFor range
    {
      stx := placeholder stx info marker
      islands := #[{ marker, range, text := slice source range }] }
  | none => { stx }

private partial def protectSourceDataFrom (source : String) : Lean.Syntax → ProtectedSyntax
  | .missing => { stx := .missing }
  | .atom info spelling =>
    let stx := Lean.Syntax.atom info spelling
    match sourceRange? stx with
    | some range =>
      let text := slice source range
      if text.contains '\n' then
        exactPlaceholder source stx info
      else { stx }
    | none => { stx }
  | .ident info raw value preresolved =>
    let stx := Lean.Syntax.ident info raw value preresolved
    match sourceRange? stx with
    | some range =>
      let text := slice source range
      if text.contains '\n' then
        exactPlaceholder source stx info
      else { stx }
    | none => { stx }
  | .node info kind children =>
    let stx := Lean.Syntax.node info kind children
    if let some body := docSyntaxBody? stx then
      match sourceRange? stx with
      | some range =>
        let marker := markerFor range
        {
          stx := .node info kind (children.set! 1 (.atom body.getHeadInfo marker))
          islands := #[{ marker, range, text := slice source range, comment := true }] }
      | none => { stx }
    else if sourceDataKind kind then
      { stx, pendingEnvelope := true }
    else if dynamicQuotationKind kind then
      -- Protected here, not escalated: the quotation is a complete term, so a marker leaf standing in
      -- for it leaves the grammar around it intact and the island stays as small as the defect.
      exactPlaceholder source stx info
    else
      let (children, islands, pending) := children.foldl (init := (#[], #[], false))
        fun (rewritten, islands, pending) child =>
          let child := protectSourceDataFrom source child
          (rewritten.push child.stx, islands ++ child.islands,
            pending || child.pendingEnvelope)
      let rewritten := Lean.Syntax.node info kind children
      if pending then
        match sourceRange? rewritten with
        | some range =>
          let pendingRanges := children.filterMap sourceRange?
          let strictlyEncloses := pendingRanges.any fun child =>
            range.start < child.start || child.stop < range.stop
          let transparentEnvelope := kind == `null || kind == Lean.choiceKind ||
            interpolationKind kind
          if strictlyEncloses && !transparentEnvelope then exactPlaceholder source rewritten info
          else { stx := rewritten, islands, pendingEnvelope := true }
        | none => { stx := rewritten, islands, pendingEnvelope := true }
      else { stx := rewritten, islands }

private def protectSourceData (source : String) (stx : Lean.Syntax) :
    Lean.Syntax × Array ExactIsland :=
  let result := protectSourceDataFrom source stx
  if result.pendingEnvelope then
    let result := exactPlaceholder source result.stx result.stx.getHeadInfo
    (result.stx, result.islands)
  else
    (result.stx, result.islands)

private partial def guardedSequenceRanges (stx : Lean.Syntax)
    (ranges : Array SourceRange := #[]) : Array SourceRange :=
  if stx.isOfKind ``Lean.Parser.Term.doSeqIndent then
    match sourceRange? stx with
    | some range => ranges.push range
    | none => ranges
  else
    stx.getArgs.foldl (init := ranges) fun ranges child =>
      guardedSequenceRanges child ranges

private partial def guardedPipeRanges (stx : Lean.Syntax)
    (ranges : Array SourceRange := #[]) : Array SourceRange :=
  if stx.isOfKind ``Lean.Parser.Term.doSeqIndent then ranges
  else match stx with
    | .atom _ "|" =>
      match sourceRange? stx with
      | some range => ranges.push range
      | none => ranges
    | .node _ _ children =>
      children.foldl (init := ranges) fun ranges child =>
        guardedPipeRanges child ranges
    | _ => ranges

private partial def selectedLeafRanges (stx : Lean.Syntax)
    (ranges : Array SourceRange := #[]) : Array SourceRange :=
  match stx with
  | .atom .. | .ident .. =>
    match sourceRange? stx with
    | some range => ranges.push range
    | none => ranges
  | .node _ kind children =>
    if kind == Lean.choiceKind then
      match children[0]? with
      | some selected => selectedLeafRanges selected ranges
      | none => ranges
    else
      children.foldl (init := ranges) fun ranges child =>
        selectedLeafRanges child ranges
  | .missing => ranges

private partial def collectReturnTermStarts (stx : Lean.Syntax)
    (starts : Array Nat := #[]) : Array Nat :=
  let starts :=
    if stx.isOfKind ``Lean.Parser.Term.doReturn then
      match (selectedLeafRanges stx)[1]? with
      | some range => starts.push range.start
      | none => starts
    else starts
  stx.getArgs.foldl (init := starts) fun starts child =>
    collectReturnTermStarts child starts

/- Every `sepByIndent` list whose separators are written out begins on its own line.

`sepByIndent` (`Lean/Parser/Extra.lean:202-204`) is `withPosition (sepBy (checkColGe >> p) …)`, so the
column it measures every later item against is the column of the *first* item. Its formatter
(`:211-223`) spells that in one of two ways, and which one it picks is a property of the source:

- `hasNewlineSep` -- some separator slot is an empty null node, meaning the source separated two items
  by a line break rather than by the written separator. The formatter then emits `pushWhitespace "\n"`
  for each such slot and one `pushAlign (force := true)` before the list. The align pads to the current
  indent and every `"\n"` lands on it, so the first item and every later one share one column and the
  parser's reference column is satisfied by construction. Nothing to correct.
- otherwise -- every separator is written (`,` or `;`), the formatter emits none of that, and the list
  is laid out by the soft `line`s the enclosing document already has. Those `line`s break to the
  enclosing `nest`, which has no reason to equal the column the *first* item happens to land on. Break
  one and not the one before the first item, and a later item is dedented below the reference column.

The correction for the second case is one boundary: break before the first item, so that the first
item lands on the same `nest` every later break lands on. `hard` is what makes this sound rather than
merely likely -- it cannot lengthen a line, so unlike a `flat` join it cannot push a break somewhere
else and it needs no accompanying flatten. Everything inside the list still lays itself out.

But "has no reason to equal" is not "does not equal", and forcing the boundary where the two already
coincide is a gratuitous break. They coincide exactly when the first item's unbroken column *is* the
`nest` the separators break to, and only two shapes of carrier can pull them apart:

- A carrier that opens with a delimiter and wraps its list in that delimiter's own group. `structInst`
  is the one: `{ ` is `format.indent` columns wide, and `fill` breaks the line *before* a group it
  cannot fit rather than inside it, so `{` reaches the current indent before any comma breaks and the
  first field sits exactly on the `nest`. Verified by rendering an inline record at widths 100, 90, 80
  and 70 -- the fields stay aligned at every one. Content between the delimiter and the first item is
  what breaks it: `{ base with ` is wider than the indent, so the fields sit right of the `nest` and a
  later comma dedents below them. The test is therefore *whether a terminal intervenes*, not whether
  the intervening terminal is `with`.
- A carrier `ppAllowUngrouped` left outside any group of its own. `Term.byTactic` (`Term.lean:108`) is
  the only one that carries a `sepByIndent` list -- `categoryParser.formatter`
  (`Formatter.lean:302-310`) skips its `fill` wrapping, so `by` and its tactics are direct children of
  whatever `nest` encloses the declaration. The separators then break to *that* indent, which is
  unrelated to the column `by` happens to sit at, so the two never reliably coincide and the boundary
  is always needed. This is the same mechanism `collectUngroupedBodyStarts` above turns to the other
  purpose; the two are the joined `:= by` and the broken `by`-to-first-tactic halves of one line.

The delimiter-free sequences are the ungrouped case wherever they appear, not only under `by`, because
being delimiter-free is exactly what leaves them without a group. `whereDecls` and the two bracketed
sequences are the delimited case; no terminal can intervene in any of them, so the test says no and
they are walked anyway rather than assumed. The one carrier not walked is `structInstFields` spelled
after `where` (`Command.lean:174`) instead of inside `{ }`: `where` is its delimiter and the list is
the very next thing, so nothing can come between them and there is no shape for the test to find.

Which nodes carry such a list is a fact about Lean's grammar, not a list of shapes observed to fail.
These are the `sepByIndent`/`sepBy1Indent` call sites reachable from a Lean source file:
`structInstFields` (`Term.lean:354`, `Command.lean:174`, `Elab/StructInst.lean:42,58`),
`tacticSeq1Indented` and `tacticSeqBracketed` (`Term/Basic.lean:75,79`), `convSeq1Indented` and
`convSeqBracketed` (`Init/Conv.lean:25-26`), and `whereDecls` (`Term.lean:741-742`). In each the list
is the first `null` child, because every other child is an atom or follows it.

This replaces a rule that fired on `{ base with … }` alone and fired unconditionally. Both halves were
wrong. `with` was a proxy for the intervening terminal, and it missed the tactic sequence entirely;
firing unconditionally added a second break to lists the `align` had already positioned, which is how
a record update whose fields the source spelled on their own lines acquired a blank line above the
first field and left it indented one level past its siblings. -/
private def ungroupedSequenceKind (kind : Lean.Name) : Bool :=
  kind == ``Lean.Parser.Tactic.tacticSeq1Indented ||
    kind == ``Lean.Parser.Tactic.Conv.convSeq1Indented

private def delimitedSequenceKind (kind : Lean.Name) : Bool :=
  kind == ``Lean.Parser.Tactic.tacticSeqBracketed ||
    kind == ``Lean.Parser.Tactic.Conv.convSeqBracketed ||
    kind == ``Lean.Parser.Term.whereDecls

/- `sepByIndent.formatter`'s own test, transcribed: an odd slot holding an empty null node is a
separator the source spelled as a line break. The final slot is excluded there because a trailing
separator is skipped rather than emitted, and it is excluded here for the same reason. -/
private def hasNewlineSeparator (list : Lean.Syntax) : Bool :=
  let args := list.getArgs
  args.size != 0 && (List.range args.size).any fun index =>
    index % 2 == 1 && args[index]!.matchesNull 0 && index != args.size - 1

/- `structInstFields` is the list's own wrapper, so the delimiter and anything between it and the list
belong to the *parent*. Every other delimited carrier holds its own delimiter, and this walk sees the
node that holds the list either way -- so the terminals to count are the ones under `owner` that start
before the list does, and "more than the delimiter itself" is more than one of them. -/
private def delimiterIntervenes (owner list : Lean.Syntax) : Bool :=
  match (selectedLeafRanges list)[0]? with
  | some first => ((selectedLeafRanges owner).filter (·.start < first.start)).size > 1
  | none => false

private partial def collectIndentedSequenceStarts (stx : Lean.Syntax)
    (starts : Array Nat := #[]) : Array Nat :=
  match stx with
  | .node _ kind children =>
    -- `(owner, carrier)`: the node whose terminals include the opening delimiter, and the node that
    -- holds the list. They differ only for `structInst`, whose `{` is a sibling of the field list.
    let carrier? : Option (Lean.Syntax × Lean.Syntax) :=
      if kind == ``Lean.Parser.Term.structInst then
        (children.find? (·.isOfKind ``Lean.Parser.Term.structInstFields)).map fun fields =>
          (stx, fields)
      else if ungroupedSequenceKind kind || delimitedSequenceKind kind then some (stx, stx)
      else none
    let starts :=
      match carrier? with
      | some (owner, carrier) =>
        match carrier.getArgs.find? (·.isOfKind Lean.nullKind) with
        -- One item has no separator to break at the wrong column, so it needs no boundary; two do.
        | some list =>
          if list.getArgs.size >= 3 && !hasNewlineSeparator list &&
              (ungroupedSequenceKind kind || delimiterIntervenes owner list) then
            match (selectedLeafRanges list)[0]? with
            | some range => if starts.contains range.start then starts else starts.push range.start
            | none => starts
          else starts
        | none => starts
      | none => starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child =>
      collectIndentedSequenceStarts child starts
  | _ => starts

/- `:= by` keeps the `by` on the `:=` line.

`Term.byTactic` (`Term.lean:108`) is `ppAllowUngrouped >> "by " >> Tactic.tacticSeqIndentGt`, and that
mechanism works: `categoryParser.formatter` (`Formatter.lean:302-310`) skips its `fill` wrapping when
`isUngrouped`, so `ppHardLineUnlessUngrouped` (`Extra.lean:304-308`) emits a soft `line` rather than a
hard `"\n"`. The document holds `text" :=" line text"by"`.

What breaks it is one layer below, in `Std.Format` itself. `pushGroup`
(`Init/Data/Format/Basic.lean:243-249`) measures the group *and the enclosing remainder*, and a
multi-step tactic sequence carries an `align(true)` whose `spaceUptoLine` case (`:165-170`) contributes
padding at narrow widths instead of stopping the measurement. So the soft line breaks as a function of
the width rather than of the line being laid out: measured threshold 136 for a line that occupies 50
columns through `by`. `LeanFmt/Doc.lean` hands registered documents to `Std.Format.prettyM` on purpose,
so this adapter does not own that decision and must not reimplement the renderer to take it back. A
flat boundary at the `by` terminal is the whole repair.

Only `by`, not the other two parsers that declare `ppAllowUngrouped`. Measured: `fun` and a bare `do`
are already correct, so there is nothing to force. `by` is also the only one safe to force -- its
tactic sequence begins its own line, so joining `by` to `:=` adds exactly three columns and cannot
overflow, where forcing `fun` flat would pull an arbitrarily long body onto the `:=` line. The one cost
is `:= by rfl` at a width narrow enough that Lean would have broken it; that stays joined, three
columns over a soft target the source spellings can already exceed.

`:= Id.run do` is deliberately not matched. Its body's head is an application, so `ppAllowUngrouped`
never applied and the hard line is correct. -/
private partial def collectUngroupedBodyStarts (stx : Lean.Syntax)
    (starts : Array Nat := #[]) : Array Nat :=
  match stx with
  | .node _ kind children =>
    let starts :=
      if kind == ``Lean.Parser.Command.declValSimple then
        -- `declBody` (`Command.lean:137-161`) is `lookahead … >> termParser`, and `lookahead` pushes
        -- nothing, so the body term is this node's second child with no wrapper in between.
        match children[1]? with
        | some body =>
          if body.isOfKind ``Lean.Parser.Term.byTactic then
            match (selectedLeafRanges body)[0]? with
            | some range => starts.push range.start
            | none => starts
          else starts
        | none => starts
      else starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child =>
      collectUngroupedBodyStarts child starts
  | _ => starts

/- A guarded `let`'s bail-out, when the source already spells it on one line.

Lean's document spells this boundary as a literal `text" |" text"\n"`, a hard newline no width can
flatten, so `let some current := value | return 0` always breaks after the bar. The bar and its
bail-out are one construct: the bar reads as a guard only with the bail-out beside it.

`doLetElse` (`Lean/Parser/Do.lean:79-81`) spells two `doSeqIndent`s --
`(checkColGe >> " | " >> doSeqIndent) >> optional (checkColGe >> doSeqIndent)` -- the guard body and
the rest of the enclosing block, which is why `collectOffsideConstraints` finds two sequences past the
bar and takes the *last* for its constraint. The bail-out is the first. `pipes.back?` for the reason
that collector uses it: a pattern may spell alternatives with earlier bars, and only the last one is
the guard.

Joining alone is width-unsound and was reverted once (`7e838a1`). `.text " "` cannot break, so the
renderer re-measures and breaks at the next soft line, which is now *inside* the bail-out at an
indentation the enclosing `nest` chose rather than the bar's column -- and `many1Indent` saved the
bail-out's first token as the column every later item is measured against, so the continuation
reparsed as a sibling of the outer `do`. `Std.Format` has no shape that fixes this: `nest` is relative
to the current indent and `align` pads to it, so nothing in the algebra means "indent this subtree's
continuations to the column where it starts". The repair is instead to leave no soft line to break --
the boundary joins, and `flattenNative` removes every break inside the bail-out.

Only a bail-out the *source* already spells on one line is collected, and that one condition buys both
halves. It is what makes the flatten free of newline-emitting leaves: `sepByIndent.formatter`
(`Lean/Parser/Extra.lean:212-224`) is the sole producer of both `pushWhitespace "\n"` and
`pushAlign (force := true)` in the tree, and emits them only on its `hasNewlineSep` path, which is a
property of the source argument list. And it bounds the cost -- a line the source already fit on is a
line, not a paragraph. Measured 2026-07-24 over this repository's own `LeanFmt/`: 102 guarded `let`s
already sit on one line, median 60 columns and widest 99, every body a short bail-out
(`return false`, `none`, `continue`, `.error "unknown directive scope"`); 10 more spell the bail-out
on the next line and are not collected. The idiom bounds it: a guarded `let` exists to leave, and
leaving is short. -/
private partial def collectGuardBailouts (source : String) (stx : Lean.Syntax)
    (ranges : Array SourceRange := #[]) : Array SourceRange :=
  match stx with
  | .node _ kind children =>
    let ranges :=
      if kind == ``Lean.Parser.Term.doLetElse ||
          kind == ``Lean.Parser.Term.doLetExpr ||
          kind == ``Lean.Parser.Term.doLetMetaExpr ||
          kind == ``Lean.Parser.Term.doLetArrow then
        match (guardedPipeRanges stx).back? with
        | some pipe =>
          match ((guardedSequenceRanges stx).filter (pipe.stop <= ·.start))[0]? with
          | some range =>
            if (slice source range).contains '\n' then ranges else ranges.push range
          | none => ranges
        | none => ranges
      else ranges
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := ranges) fun ranges child =>
      collectGuardBailouts source child ranges
  | _ => ranges

/- The docstring of a constructor that has one.

`ctor` (`Command.lean:210-212`) is `atomic (optional docComment >> "\n| ") >> ppGroup …`, so the
docstring is the first child -- a `null` node, empty when the constructor has none -- and the `|` is
the second. The newline the constructor needs sits *inside* the `"\n| "` atom, after the docstring
that was supposed to follow it, which is the whole of D2: Lean emits the docstring where a separator
should be and the separator after it. -/
private def ctorDocComment? (stx : Lean.Syntax) : Option Lean.Syntax := do
  guard (stx.isOfKind ``Lean.Parser.Command.ctor)
  let doc ← stx.getArgs[0]?.bind fun optional => optional.getArgs[0]?
  guard (doc.isOfKind ``Lean.Parser.Command.docComment)
  return doc

/- A constructor docstring keeps its constructor's indentation, and one blank line goes away.

Lean's document is `text" where" nest-2[text"/--" line text"…-/" text"\n"] text"\n|" …`, which spells
the boundary between the docstring and its constructor twice and dedents the docstring by one level.
Rendered, that is a docstring at column zero followed by a blank line -- and reparsed, a docstring
that no longer sits on its constructor.

Both corrections are ordinary. The `elided` boundary at the `|` removes the first of the two newlines,
leaving the one inside the `"\n| "` atom, which carries the constructor's own indentation. The
constraint cancels the `nest -2` over exactly the docstring's range, so the line the island opens
lands at the same column as the `|` below it.

Eliding rather than flattening matters: `.text " "` here would leave a space at the end of the
docstring's line, and the `elided` spelling exists because a doubled separator is a different defect
from a badly placed one.

This half is the boundary; `collectOffsideConstraints` carries the other. The offset is the
docstring's own end, which `boundaryTable` resolves to the `|` -- the first terminal at or after it. -/
private partial def collectCtorDocStarts (stx : Lean.Syntax)
    (starts : Array Nat := #[]) : Array Nat :=
  match stx with
  | .node _ kind children =>
    let starts :=
      match ctorDocComment? stx with
      | some doc =>
        match sourceRange? doc with
        | some range => starts.push range.stop
        | none => starts
      | none => starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child => collectCtorDocStarts child starts
  | _ => starts

/- `indent` is `Std.Format.getIndent`, the `format.indent` option Lean's own `ppIndent`/`ppDedent`
read. A constraint here cancels one level of the indentation native layout introduced, so it is that
same quantity negated -- not the literal `-2` this used to spell. The default happens to be 2, which is
why the constant went unnoticed; a project that sets `format.indent` would have silently drifted.

The constructor-docstring branch cancels a `nest -2` rather than introducing one, so its adjustment is
that same quantity un-negated. Both are one level; nothing here knows how to ask for two. -/
private partial def collectOffsideConstraints (indent : Nat) (stx : Lean.Syntax)
    (constraints : Array OffsideConstraint := #[]) : Array OffsideConstraint :=
  match stx with
  | .node _ kind children =>
    let constraints :=
      if kind == ``Lean.Parser.Term.doLetElse ||
          kind == ``Lean.Parser.Term.doLetExpr ||
          kind == ``Lean.Parser.Term.doLetMetaExpr ||
          kind == ``Lean.Parser.Term.doLetArrow then
        let pipes := guardedPipeRanges stx
        let sequences := guardedSequenceRanges stx
        match pipes.back? with
        | some pipe =>
          let continuations := sequences.filter (pipe.stop <= ·.start)
          if 2 <= continuations.size then
            match continuations.back? with
            | some range =>
              constraints.push
                { range, indentAdjustment := -(indent : Int), carrier := .boundary }
            | none => constraints
          else constraints
        | none => constraints
      else match ctorDocComment? stx with
        | some doc =>
          match sourceRange? doc with
          | some range =>
            constraints.push { range, indentAdjustment := (indent : Int), carrier := .nest }
          | none => constraints
        | none => constraints
    -- As in the boundary collectors: one alternative of a `choice` spells the bytes, and collecting
    -- from all of them would name the same range once per alternative. A constraint is applied once,
    -- so the duplicate would leave the applied count short and refuse the command.
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := constraints) fun constraints child =>
      collectOffsideConstraints indent child constraints
  | _ => constraints

private def commentText (value : String) : Bool :=
  let trimmed := value.trimAscii.copy
  trimmed.startsWith "--" || trimmed.startsWith "/-"

private def layoutWhitespace (char : Char) : Bool :=
  char == ' ' || char == '\t' || char == '\n' || char == '\r'

private def splitPadding (value : String) : String × String :=
  let chars := value.toList
  let leading := chars.takeWhile layoutWhitespace
  let remainder := chars.drop leading.length
  let trailing := remainder.reverse.takeWhile layoutWhitespace |>.reverse
  (String.ofList leading, String.ofList trailing)

/- Put `payload` where a native leaf spelled something, keeping the leaf's own padding.

`splitPadding` already decides where the padding ends and the spelling begins, so the spelling is
whatever lies between. This replaced `value.replace trimmed payload`, a substring substitution that
searched the leaf for its own trimmed text: on a leaf whose padding repeats inside the spelling, or
whose spelling occurs twice, `String.replace` rewrites every occurrence rather than the one. -/
private def withPayload (value payload : String) : String :=
  let (leading, trailing) := splitPadding value
  leading ++ payload ++ trailing

/- Which markers the formatter kept. A marker replaces the syntax it protects, so a formatter that
drops or restructures that syntax drops the marker with it; the island then has to be placed at the
terminal it covers instead of at a leaf that never arrives. -/
private partial def spelledMarkers (format : Std.Format) (found : Array String := #[]) :
    Array String :=
  match format with
  | .text value =>
    let payload := value.trimAscii.copy
    if payload.isEmpty then found else found.push payload
  | .nest _ inner | .group inner _ | .tag _ inner => spelledMarkers inner found
  | .append left right => spelledMarkers right (spelledMarkers left found)
  | .nil | .line | .align _ => found

private def mergeSpan : Option TokenSpan → Option TokenSpan → Option TokenSpan
  | none, right => right
  | left, none => left
  | some left, some right => some ⟨min left.start right.start, max left.stop right.stop⟩

private structure TransformState where
  source : String
  terminals : Array Terminal
  comments : Array InteriorComment
  trailing : Array (TokenSpan × InteriorComment)
  islands : Array ExactIsland
  droppedIslands : Array String
  constraints : Array (OffsideConstraint × TokenSpan)
  boundaries : Array (Nat × BoundaryLayout)
  flattened : Array TokenSpan
  baseIndent : Nat
  terminalIndex : Nat := 0
  commentIndex : Nat := 0
  ambientNest : Int := 0
  appliedIslands : Array String := #[]
  appliedConstraints : Array Nat := #[]
  appliedBoundaries : Array Nat := #[]
  appliedTrailing : Array Nat := #[]
  appliedFlattened : Array Nat := #[]
  /- Whether the document emitted since the previous terminal is known to render as something other
  than the empty string. A command starts separated because its first terminal has no predecessor to
  merge with. -/
  separated : Bool := true
  /- Islands whose interior the formatter has started to spell. See `insideIsland`. -/
  enteredIslands : Array String := #[]
  recentNativeLeaves : Array String := #[]
  metrics : Metrics := {}

private structure Transformed where
  format : Std.Format
  span? : Option TokenSpan := none

private def nearbyTerminals (state : TransformState) : String :=
  let start := state.terminalIndex - min state.terminalIndex 2
  let stop := min state.terminals.size (state.terminalIndex + 3)
  String.intercalate ", " <| (state.terminals.extract start stop).toList.map fun terminal =>
    s!"{terminal.range.start}:{repr terminal.sourceSpelling}"

private def rememberNativeLeaf (leaves : Array String) (value : String) : Array String :=
  let leaves := leaves.push value
  if leaves.size <= 8 then leaves else leaves.extract (leaves.size - 8) leaves.size

/- Whether a document renders as the empty string at every width. `nil` and an empty `text` are the
only leaves that emit nothing; `line` renders as a space or a newline, and `align` is a layout node
whose output the width decides, so neither is provably empty. -/
private partial def provablyEmpty : Std.Format → Bool
  | .nil => true
  | .text value => value.isEmpty
  | .nest _ inner | .group inner _ | .tag _ inner => provablyEmpty inner
  | .append left right => provablyEmpty left && provablyEmpty right
  | .line | .align _ => false

/- A comment's own bytes, with the columns the source gave them.

`Format.text` re-indents every newline it contains, so a block comment spanning lines would have its
continuations pushed right by the ambient indentation while its opening moved with the layout -- and
the payload the contract compares is the whole slice, so that is a changed comment and a refusal.
`dedent` is the same cancelling `nest` an exact island gets, and for the same reason: a payload
carrying absolute source columns has to reach column zero. A single-line payload has no interior
newline for the indentation to reach, so it is left alone. -/
private def commentPayload (dedent : Int) (comment : InteriorComment) : Std.Format :=
  if comment.payload.contains '\n' then .nest dedent (.text comment.payload)
  else .text comment.payload

private def insertComments (dedent : Int) (comments : Array InteriorComment)
    (suffix : Std.Format) : Std.Format :=
  let (document, atLineStart) := comments.foldl (init := (.nil, false))
    fun (document, atLineStart) comment =>
      let payload := commentPayload dedent comment
      match comment.placement with
      | .trailing =>
        let boundary := if atLineStart then .nil else .text " "
        let document := .append document (.append boundary payload)
        if comment.kind == .line then (.append document (.text "\n"), true)
        else (document, false)
      | .leading | .dangling =>
        let boundary := if atLineStart then .nil else .text "\n"
        (.append document <| .append boundary <| .append payload (.text "\n"), true)
  if atLineStart then document
  -- The adapter owns *both* sides of a comment, not just the side facing the token behind it. `suffix`
  -- is the native boundary between the two tokens the comment sits between, and the native document
  -- holds no decision about a leaf it never emitted -- so where the grammar spells those tokens
  -- adjacent, as `[` and `5` in a list, `suffix` is empty and a block comment would close directly
  -- against the next token: `-/5`. That reparses as one token or not at all.
  --
  -- A line comment needs nothing here; it already ended the row and set `atLineStart`. Only the block
  -- case can end mid-row with nothing after it, and one space is enough -- `pushToken`'s discretionary
  -- space is the tokenizer's own answer to the same question, and this is the case it never sees.
  else if provablyEmpty suffix then .append document (.text " ")
  else .append document suffix

private partial def hasLineBoundary : Std.Format → Bool
  | .line | .align _ => true
  | .text value => value.contains '\n'
  | .nest _ inner | .group inner _ | .tag _ inner => hasLineBoundary inner
  | .append left right => hasLineBoundary left || hasLineBoundary right
  | .nil => false

/- The same document with every break removed, or the leaf that made that impossible.

This is `Std.Format`'s own flattening, spelled out because the renderer's lives inside `be` and is not
callable: `line` becomes `text " "`, an unforced `align` becomes nothing, and a `group` is only a
decision about breaks the subtree no longer has.

Two leaves survive flattening -- a forced `align`, which pads or breaks to the indent either way, and a
`text` carrying a newline, which `Format.text` re-indents rather than removes. Both are reported rather
than silently kept: a caller flattens because it is about to join this subtree onto a line, and a
subtree that still breaks after joining produces exactly the reparse the join was meant to prevent.

`nest` is kept. It is inert in a subtree that emits no newline, and dropping it would have to be
justified against exact islands, whose cancelling nests are computed against `ambientNest`. -/
private partial def flattenNative : Std.Format → Except String Std.Format
  | .nil => return .nil
  | .line => return .text " "
  | .align force => if force then throw "a forced alignment" else return .nil
  | .text value =>
    if value.contains '\n' then throw s!"the multi-line leaf {repr value}" else return .text value
  | .nest indent inner => return .nest indent (← flattenNative inner)
  | .append left right => return .append (← flattenNative left) (← flattenNative right)
  | .group inner _ => flattenNative inner
  | .tag tag inner => return .tag tag (← flattenNative inner)

private def finishConstraint (result : Transformed) (carrier? : Option ConstraintCarrier := none) :
    StateT TransformState (Except String) Transformed := do
  let some carrier := carrier? | return result
  let state ← get
  match result.span? with
  | none => return result
  | some span =>
    match state.constraints.findIdx? fun (constraint, expected) =>
        expected == span && constraint.carrier == carrier with
    | some index =>
      if state.appliedConstraints.contains index then return result
      let (constraint, _) := state.constraints[index]!
      set { state with
        appliedConstraints := state.appliedConstraints.push index
        metrics := { state.metrics with
          offsideConstraints := state.metrics.offsideConstraints + 1 } }
      return { result with format := .nest constraint.indentAdjustment result.format }
    | none => return result

/- Remove every break inside a span the facts marked as joinable.

Keyed by span and taken by the *deepest* node whose span matches, because the walk is post-order. That
is not incidental. An `append` of the span and the layout leaf after it carries the same span -- a
pure-layout leaf contributes none -- and flattening *that* would eat the separator the next sibling
needs. The deeper node claims the span first and every enclosing one declines.

No metric of its own. The boundary that joins the bail-out onto the bar's line already counted this
correction, and counting the second half again would report two rules where one fired. -/
private def finishFlatten (result : Transformed) :
    StateT TransformState (Except String) Transformed := do
  let state ← get
  let some span := result.span? | return result
  match state.flattened.findIdx? (· == span) with
  | none => return result
  | some index =>
    if state.appliedFlattened.contains index then return result
    match flattenNative result.format with
    | .error leaf =>
      throw s!"native formatter cannot join a guarded bail-out onto the bar's line: its document \
holds {leaf}, which flattening cannot remove"
    | .ok format =>
      set { state with appliedFlattened := state.appliedFlattened.push index }
      return { result with format }

/- Put a block's dangling comment back at the end of that block.

`finishConstraint`'s `.boundary` carrier already names the shape this needs: an `append` whose left is
the break before a span and whose right spells exactly that span. Here the span is the block's last
statement, so appending a break and the payload after the right side puts the comment one break
further along the same item list the statement is in — at the statement's own column, and outside the
group that decides the statement's own layout.

The break is a `text "\n"`, the same leaf the document's own item separator is, and not a `line`. A
`line` is discretionary and the enclosing group is a `fill`, which flattens item by item: a comment
short enough to fit rendered as a *space* after the statement, and reparsed as its trailing trivia
rather than the block's dangling trivia. `text "\n"` re-indents to the current level, which at this
point is the level the sibling separators were emitted at.

Nothing follows the payload. This runs only for a comment past the command's last token, so nothing in
the command's document follows it and the module boundary supplies the break.

There is no fallback. A block whose document holds no such break is a block this cannot place a
comment in, and the alternative to refusing is emitting the comment at some other column — where
reparsing hands it to a different owner and the comment gate refuses anyway, later and with a worse
message. -/
private def finishTrailing (left right : Transformed) :
    StateT TransformState (Except String) (Option Std.Format) := do
  let state ← get
  let some span := right.span? | return none
  unless left.span?.isNone && hasLineBoundary left.format do return none
  match state.trailing.findIdx? fun (expected, _) => expected == span with
  | none => return none
  | some index =>
    if state.appliedTrailing.contains index then return none
    let (_, comment) := state.trailing[index]!
    set { state with
      appliedTrailing := state.appliedTrailing.push index
      metrics := { state.metrics with
        commentLeaves := state.metrics.commentLeaves + 1
        commentConstraints := state.metrics.commentConstraints + 1 } }
    return some (.append right.format (.append (.text "\n") (.text comment.payload)))

/- Every span-keyed correction a finished node can carry, in the order they compose, so that adding a
node kind to the walk cannot silently skip one. A constraint's `nest` is inert inside a subtree that no
longer breaks, so the order matters only in that it is fixed. -/
private def finishNode (result : Transformed) (carrier? : Option ConstraintCarrier := none) :
    StateT TransformState (Except String) Transformed := do
  finishFlatten (← finishConstraint result carrier?)

/- The unapplied island covering the terminal the transform is waiting for, if any. An island consumes
every terminal it covers at once, so this stays fixed at the island's first covered terminal for as
long as the formatter is still spelling that island's leaves. -/
private def islandAt (state : TransformState) : Option ExactIsland :=
  match state.terminals[state.terminalIndex]? with
  | none => none
  | some terminal =>
    state.islands.find? fun island =>
      !state.appliedIslands.contains island.marker &&
        island.range.start <= terminal.range.start && terminal.range.stop <= island.range.stop

/- An exact island's bytes are its whole rendering, so native layout emitted *between* the terminals it
covers is inside a region the source owns and must not be emitted.

The boundary *before* the island is not: it separates the island from the token ahead of it, and is the
adapter's to keep. The terminal index alone cannot tell those two cases apart, because it does not
advance until the island is applied. `enteredIslands` is what separates them -- an island is entered by
the first native leaf that spells one of its covered terminals, so a boundary is suppressed only once
the formatter has started spelling that island's interior. Suppressing the boundary ahead of an island
instead is what ran `=>` into the quotation after it. -/
private def insideIsland (state : TransformState) : Bool :=
  match islandAt state with
  | none => false
  | some island => state.enteredIslands.contains island.marker

/- Whether the source began a line with the terminal at `index`.

A comment is the previous token's trailing trivia exactly when it sits on that token's line, and the
next token's leading trivia otherwise; Lean's tokenizer ends trailing trivia at the newline. So a
comment that the source put on its own line has to keep starting one, or reparsing the output hands it
to a different owner with a different placement -- which is what the `comments` validation gate
compares. A comment that shared its owner's line has no such constraint: staying adjacent is what
keeps it trailing.

This is only consulted where the document native layout produced since the previous terminal is
provably empty, which is the one case where the output is certainly on the previous token's line. -/
private def beganLine (state : TransformState) (index : Nat) : Bool :=
  if index == 0 then false else
    match state.terminals[index - 1]?, state.terminals[index]? with
    | some previous, some next =>
      (slice state.source ⟨previous.range.stop, next.range.start⟩).contains '\n'
    | _, _ => false

/- How far the constraints that will wrap this span move it, in columns.

`ambientNest` is the native document's own nest depth, which is what the walk carries. A constraint
introduces a `nest` the native document never had, at an ancestor -- and post-order finishes that
ancestor *after* this subtree is built, so the walk cannot have seen it yet. The spans are known
before the walk starts, so a node can ask for them by containment instead of waiting.

Every collected constraint is applied or `transform` refuses the command, so a constraint whose span
contains this one is indentation this subtree will certainly sit inside.

Only exact islands need this, and only because their bytes carry absolute source columns that a
cancelling `nest` has to reach. Without it a constructor docstring spanning more than one line came
out with its first line moved and its continuations left behind. -/
private def containingConstraintNest (state : TransformState) (span : TokenSpan) : Int :=
  state.constraints.foldl (init := 0) fun total (constraint, expected) =>
    if expected.start <= span.start && span.stop <= expected.stop then
      total + constraint.indentAdjustment
    else total

private def constrainBoundary (format : Std.Format) :
    StateT TransformState (Except String) Std.Format := do
  let state ← get
  if insideIsland state then return .nil
  let mut format := format
  -- The first boundary leaf at this terminal, and only the first: the document can lay out more than
  -- one leaf between two terminals, and a correction that fired at each of them would spell itself
  -- twice. Eliding a doubled newline depends on exactly this -- it removes the first of the two.
  if let some (_, layout) := state.boundaries.find? fun (index, _) => index == state.terminalIndex then
    unless state.appliedBoundaries.contains state.terminalIndex do
      set { state with
        appliedBoundaries := state.appliedBoundaries.push state.terminalIndex
        metrics := { state.metrics with
          offsideConstraints := state.metrics.offsideConstraints + 1 } }
      format := layout.format
  let state ← get
  let start := state.commentIndex
  let mut stop := start
  while h : stop < state.comments.size do
    if state.comments[stop].boundary == state.terminalIndex then stop := stop + 1
    else break
  if start < stop then
    let comments := state.comments.extract start stop
    set { state with
      commentIndex := stop
      metrics := { state.metrics with
        commentLeaves := state.metrics.commentLeaves + comments.size
        commentConstraints := state.metrics.commentConstraints + comments.size } }
    let span : TokenSpan := ⟨state.terminalIndex, state.terminalIndex⟩
    format := insertComments
      (-(state.baseIndent + state.ambientNest + containingConstraintNest state span))
      comments format
  modify fun state => { state with separated := state.separated || !provablyEmpty format }
  return format

private def consumeIsland (value : String) (island : ExactIsland) :
    StateT TransformState (Except String) Transformed := do
  let state ← get
  let start := state.terminalIndex
  let mut stop := start
  while stop < state.terminals.size &&
      state.terminals[stop]!.range.start < island.range.stop do
    let terminal := state.terminals[stop]!
    unless island.range.start <= terminal.range.start &&
        terminal.range.stop <= island.range.stop do
      throw s!"exact island {island.range.start}:{island.range.stop} cuts terminal \
{terminal.range.start}:{terminal.range.stop}"
    stop := stop + 1
  if start == stop then
    throw s!"exact island {island.range.start}:{island.range.stop} contains no terminal at index \
{start}/{state.terminals.size}; nearby: {nearbyTerminals state}; recent native leaves: \
{repr state.recentNativeLeaves}"
  let (leading, _) := splitPadding value
  let startsLine :=
    island.comment && !state.separated && leading.isEmpty && beganLine state start
  set { state with
    terminalIndex := stop
    separated := false
    appliedIslands := state.appliedIslands.push island.marker
    metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1
      tokenLeaves := state.metrics.tokenLeaves + 1
      exactIslands := state.metrics.exactIslands + 1
      exactIslandBytes := state.metrics.exactIslandBytes + island.text.utf8ByteSize } }
  let state ← get
  let payload := Std.Format.text (withPayload value island.text)
  -- A single-line payload has no interior newline for the ambient indentation to reach.
  let payload := if island.text.contains '\n' then
      .nest (-(state.baseIndent + state.ambientNest +
        containingConstraintNest state ⟨start, stop⟩)) payload
    else payload
  let payload := if startsLine then .append (.text "\n") payload else payload
  finishNode { format := payload, span? := some ⟨start, stop⟩ }

private def transformOrdinaryText (value : String) :
    StateT TransformState (Except String) Transformed := do
  let state ← get
  if value.trimAscii.isEmpty then
    set { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    finishNode { format := ← constrainBoundary (.text value) }
  else if let some island := islandAt state then
    -- This leaf spells a terminal the island covers, so the island's own bytes already carry it.
    -- Recording the entry is what lets `insideIsland` suppress the boundaries that follow it.
    set { state with
      enteredIslands :=
        if state.enteredIslands.contains island.marker then state.enteredIslands
        else state.enteredIslands.push island.marker
      metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
    return { format := .nil }
  else
    let some terminal := state.terminals[state.terminalIndex]?
      | if commentText value then
          throw s!"comment-free native syntax emitted an interior comment leaf {repr value}"
        else
          throw s!"native formatter emitted extra text leaf {repr value} after \
{state.terminalIndex} terminals; nearby: {nearbyTerminals state}"
    -- `withoutTrivia` removes every comment the formatter could re-emit from `SourceInfo`, so a
    -- comment leaf is admissible only where the source spells a doc comment as syntax.
    if commentText value && !commentText terminal.sourceSpelling then
      throw s!"comment-free native syntax emitted an interior comment leaf {repr value}"
    let nativePayload := value.trimAscii.copy
    let normalized := nativePayload != terminal.syntaxSpelling &&
      nativePayload != terminal.sourceSpelling
    let (leading, trailing) := splitPadding value
    let boundary ← constrainBoundary (.text leading)
    let state ← get
    set { state with
      terminalIndex := state.terminalIndex + 1
      separated := !trailing.isEmpty
      metrics := { state.metrics with
        nativeNodes := state.metrics.nativeNodes + 1
        tokenLeaves := state.metrics.tokenLeaves + 1
        normalizedTokens := state.metrics.normalizedTokens + if normalized then 1 else 0 } }
    finishNode {
      format := .append boundary (.append (.text terminal.sourceSpelling) (.text trailing))
      span? := some ⟨state.terminalIndex, state.terminalIndex + 1⟩ }

private def transformText (value : String) :
    StateT TransformState (Except String) Transformed := do
  let state ← get
  set { state with recentNativeLeaves := rememberNativeLeaf state.recentNativeLeaves value }
  let state ← get
  match state.islands.find? fun island => value.trimAscii.copy == island.marker with
  | some island => consumeIsland value island
  | none =>
    -- Only an island the formatter dropped is placed ahead of its own marker. Placing an island the
    -- formatter *will* spell consumes the terminals that marker is still about to claim, which then
    -- reports the island as containing no terminal.
    let pending? := state.terminals[state.terminalIndex]?.bind fun terminal =>
      state.islands.find? fun island =>
        state.droppedIslands.contains island.marker &&
          !state.appliedIslands.contains island.marker &&
          island.range.start == terminal.range.start
    match pending? with
    | some exact =>
      -- The formatter emitted no leaf for this island, so the native document also holds no decision
      -- about what precedes it -- not even whether anything separates it from the previous token.
      -- `dbg_trace s!"flag: {flag}"` formats to `grp[nest2[T"dbg_trace"]]` with no marker and no
      -- `line`, because `pushToken` sees an empty `leadWord` and drops the token's own trailing space.
      -- Re-inserting the bytes without a separator spells `dbg_traces!"flag: {flag}"`.
      --
      -- The source answers it at byte level: whitespace between the previous terminal and the island
      -- start means the two tokens were separated, and nothing else about that whitespace is layout
      -- this adapter may keep. So the evidence is a boolean and the output is a `Format.line`, whose
      -- width the renderer owns exactly as it owns every other break.
      let sourceGap :=
        if state.terminalIndex == 0 then ""
        else match state.terminals[state.terminalIndex - 1]? with
          | some previous => slice state.source ⟨previous.range.stop, exact.range.start⟩
          | none => ""
      let separate := !state.separated && !sourceGap.isEmpty
      let island ← consumeIsland exact.marker exact
      let island := if separate then { island with format := .append .line island.format } else island
      let current ← transformOrdinaryText value
      finishNode {
        format := .append island.format current.format
        span? := mergeSpan island.span? current.span? }
    | none =>
      transformOrdinaryText value

private partial def transformNative : Std.Format →
    StateT TransformState (Except String) Transformed
  | .nil => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    finishNode { format := .nil }
  | .line => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    finishNode { format := ← constrainBoundary .line }
  -- An `align` is a boundary: it is layout the document put between two terminals, and a comment that
  -- belongs in that gap belongs *here*. It used to be the one boundary leaf that did not go through
  -- `constrainBoundary`, so a comment landing in this gap was carried to the next leaf that did --
  -- the following terminal's own leading padding, which is inside that terminal's `nest`. The comment
  -- then rendered one level too deep and took the terminal with it, while the sibling items stayed on
  -- the align's column, which is `sepByIndent`'s reference column: the block ended at the first
  -- sibling. `constrainBoundary` subsumes the island and `separated` handling this case used to spell.
  | .align force => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    finishNode { format := ← constrainBoundary (.align force) }
  | .text value => transformText value
  | .nest indent inner => do
    modify fun state => { state with
      ambientNest := state.ambientNest + indent
      metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
    let inner ← transformNative inner
    modify fun state => { state with ambientNest := state.ambientNest - indent }
    finishNode { inner with format := .nest indent inner.format } (carrier? := some .nest)
  | .append left right => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    let left ← transformNative left
    let right ← transformNative right
    let right := { right with format := (← finishTrailing left right).getD right.format }
    finishNode {
      format := .append left.format right.format
      span? := mergeSpan left.span? right.span? }
      (carrier? := if left.span?.isNone && hasLineBoundary left.format then some .boundary else none)
  | .group inner behavior => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    let inner ← transformNative inner
    finishNode { inner with format := .group inner.format behavior }
  | .tag tag inner => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    let inner ← transformNative inner
    finishNode { inner with format := .tag tag inner.format }

private def spanForRange (terminals : Array Terminal) (range : SourceRange) : TokenSpan :=
  let start := terminals.findIdx? (range.start <= ·.range.start) |>.getD terminals.size
  let stop := terminals.findIdx? (range.stop <= ·.range.start) |>.getD terminals.size
  ⟨start, stop⟩

/- Which terminal a collected source offset names: the first one at or after it.

Every rule collects source offsets, because a grammar shape is what it can see; `constrainBoundary`
works in terminal indices, because that is what the walk carries. This is the one place the two meet.

Collectors run independently, so more than one can name the same terminal. `constrainBoundary` applies
a boundary once, so a repeated index would leave the applied count permanently short of the collected
one and turn every such command into a refusal. Two rules asking for the *same* spelling there is a
duplicate and collapses; two rules asking for different spellings is a disagreement about the same
gap, which no order of this table resolves -- so it is refused rather than decided by which collector
the call site happens to list first. Neither has been observed; the second is the one that would
otherwise be silent. -/
private def boundaryTable (terminals : Array Terminal) (starts : Array (Nat × BoundaryLayout)) :
    Except String (Array (Nat × BoundaryLayout)) :=
  starts.foldlM (init := #[]) fun table (start, layout) =>
    match terminals.findIdx? (start <= ·.range.start) with
    | some index =>
      match table.find? fun (existing, _) => existing == index with
      | some (_, existing) =>
        if existing == layout then .ok table
        else .error s!"two boundary rules disagree at terminal {index}"
      | none => .ok (table.push (index, layout))
    | none => .ok table

private def transform (source : String) (terminals : Array Terminal)
    (comments : Array InteriorComment) (blockDangling : Array (SourceRange × InteriorComment))
    (islands : Array ExactIsland) (constraints : Array OffsideConstraint)
    (boundaryStarts : Array (Nat × BoundaryLayout)) (joined : Array SourceRange) (baseIndent : Nat)
    (native : Std.Format) : Except String (Std.Format × Metrics) := do
  let constraints := constraints.map fun constraint =>
    (constraint, spanForRange terminals constraint.range)
  let boundaries ← boundaryTable terminals boundaryStarts
  let flattened := joined.map (spanForRange terminals)
  let trailing := blockDangling.map fun (range, comment) => (spanForRange terminals range, comment)
  let comments := comments.map fun comment =>
    { comment with
      boundary := terminals.findIdx? (comment.range.start < ·.range.start) |>.getD terminals.size }
  let spelled := spelledMarkers native
  let droppedIslands := islands.filterMap fun island =>
    if spelled.contains island.marker then none else some island.marker
  let initial : TransformState := {
    source, terminals, comments, trailing, islands, droppedIslands, constraints, boundaries,
    flattened, baseIndent }
  let (result, state) ← (transformNative native).run initial
  if state.terminalIndex != terminals.size then
    throw s!"native formatter consumed {state.terminalIndex}/{terminals.size} terminals; \
nearby: {nearbyTerminals state}; recent native leaves: {repr state.recentNativeLeaves}"
  if state.commentIndex != comments.size then
    let nextRange := comments[state.commentIndex]?.map fun comment => comment.range
    throw s!"native formatter inserted {state.commentIndex}/{comments.size} interior comments; \
next expected range: {repr nextRange}; recent native leaves: \
{repr state.recentNativeLeaves}"
  if state.appliedIslands.size != islands.size then
    throw s!"native formatter applied {state.appliedIslands.size}/{islands.size} exact islands"
  if state.appliedConstraints.size != constraints.size then
    throw s!"native formatter applied {state.appliedConstraints.size}/{constraints.size} \
offside constraints"
  if state.appliedBoundaries.size != boundaries.size then
    throw s!"native formatter applied {state.appliedBoundaries.size}/{boundaries.size} \
boundaries"
  if state.appliedFlattened.size != flattened.size then
    throw s!"native formatter joined {state.appliedFlattened.size}/{flattened.size} guarded \
bail-outs; the document holds no node spelling exactly one of them"
  if state.appliedTrailing.size != trailing.size then
    throw s!"native formatter placed {state.appliedTrailing.size}/{trailing.size} block-dangling \
comments; the block's document holds no break to hang one on"
  return (result.format, state.metrics)

private def rootRange (stx : Lean.Syntax) : SourceRange :=
  sourceRange? stx |>.getD ⟨0, 0⟩

private def interiorComments (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Array InteriorComment :=
  let range := rootRange stx
  let leading := Comments.subtreeAt ownership stx .leading
  let trailing := Comments.subtreeAt ownership stx .trailing
  let dangling := Comments.subtreeAt ownership stx .dangling
  Comments.subtree ownership stx |>.filterMap fun comment =>
    if range.start <= comment.range.start && comment.range.stop <= range.stop then
      if comment.kind == .doc then none
      else
        let placement := if trailing.contains comment then .trailing
          else if dangling.contains comment then .dangling
          else if leading.contains comment then .leading
          else .leading
        some {
          payload := Comments.payload ownership comment
          range := comment.range
          placement := placement
          kind := comment.kind }
    else none

/- The comments `interiorComments` cannot take, with the block that owns each.

A comment dangling at the end of a block sits past the command's own last token, so the range filter
above drops it and it renders wherever the *next* command's leading trivia renders — column zero,
outside the block it was written in. That is the whole of D3, and the two halves are one range test
apart: `interiorComments` keeps what is inside the command, this keeps what a block inside the command
owns from beyond it. Nothing is in both. -/
private def blockDanglingComments (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Array (SourceRange × InteriorComment) :=
  let range := rootRange stx
  Comments.blockDangling ownership stx |>.filterMap fun (owner, comment) =>
    if comment.kind == .doc || comment.range.stop <= range.stop then none
    else some (owner, {
      payload := Comments.payload ownership comment
      range := comment.range
      placement := .dangling
      kind := comment.kind })

private partial def nativeSize : Std.Format → Nat
  | .nest _ inner | .group inner _ | .tag _ inner => 1 + nativeSize inner
  | .append left right => 1 + nativeSize left + nativeSize right
  | _ => 1

/-- Format one actual command through Lean's live registry, preserving source payloads and applying
only the structurally measured boundary and offside corrections collected below. `baseIndent` is the
column the resulting registered leaf is rendered at; an exact island's dedent must cancel it. -/
def command (source : String) (ownership : CommentOwnership) (stx : Lean.Syntax)
    (baseIndent : Nat := 0) : Lean.CoreM (Except FormatterFailure Document) := do
  let trace ← Formatter.trace ownership .command stx
  -- The same `format.indent` Lean's own `ppIndent`/`ppDedent` read, so a constraint that cancels one
  -- level of native indentation cancels exactly the amount native layout introduced.
  let formatIndent := Lean.Std.Format.getIndent (← Lean.getOptions)
  let stripped := Formatter.withoutBoundaryTrivia stx
  let terminals := terminalsFrom source stripped
  -- `terminals` above, and the three other walks that spell `children[0]?`, each pick one alternative
  -- of a `choice` node and assume the rest spell the same bytes. `Syntax.reprint` verifies that
  -- instead of assuming it, and this is where lean-fmt does the same: one check on `stripped`, which
  -- is the tree all four walk, makes the assumption true for all four.
  if let some (range, alternative, expected, actual) := choiceDisagreement? source stripped then
    return .error {
      category := .command
      kind := stx.getKind
      range
      trace
      detail := s!"choice node at {range.start}:{range.stop} spells different source in its \
alternatives: alternative 0 is {expected}, alternative {alternative} is {actual}" }
  let comments := interiorComments ownership stx
  let blockDangling := blockDanglingComments ownership stx
  let constraints := collectOffsideConstraints formatIndent stripped
  -- One table, one line per rule, and the spelling each rule asks for is right here rather than in the
  -- collector's name. A collector answers "where", `BoundaryLayout` answers "what".
  -- Both halves of the guarded-`let` join come from one collected range: the boundary joins the
  -- bail-out to the bar's line, and `transform` flattens the same span so the join leaves no break
  -- behind to land at the wrong column.
  let joined := collectGuardBailouts source stripped
  let boundaryStarts : Array (Nat × BoundaryLayout) :=
    (collectUngroupedBodyStarts stripped (collectReturnTermStarts stripped)).map
        (·, BoundaryLayout.flat) ++
      (collectIndentedSequenceStarts stripped).map (·, BoundaryLayout.hard) ++
      (collectCtorDocStarts stripped).map (·, BoundaryLayout.elided) ++
      joined.map (·.start, BoundaryLayout.flat)
  let commentFree := withoutTrivia stripped
  let (formattedSyntax, islands) := protectSourceData source commentFree
  -- A marker is matched by its spelling when the formatter hands the leaf back, so a source that
  -- already spells one would be indistinguishable from the placeholder standing in for protected
  -- syntax. The shape is unlikely, not impossible, and "unlikely" is not a guarantee: refuse instead.
  if let some marker := islands.find? fun island => terminals.any fun terminal =>
      terminal.sourceSpelling == island.marker then
    return .error {
      category := .command
      kind := stx.getKind
      range := rootRange stx
      trace
      detail := s!"source spells the exact-island marker {repr marker.marker}, which the formatter \
cannot tell from the placeholder that protects {marker.range.start}:{marker.range.stop}" }
  try
    let native ← Lean.PrettyPrinter.formatCommand formattedSyntax
    match transform source terminals comments blockDangling islands constraints boundaryStarts
        joined baseIndent native with
    | .ok (native, metrics) =>
      return .ok { document := Doc.registered native, trace, metrics }
    | .error detail =>
      return .error {
        category := .command
        kind := stx.getKind
        range := rootRange stx
        trace
        detail }
  catch exception =>
    let detail ← exception.toMessageData.toString
    return .error {
      category := .command
      kind := stx.getKind
      range := rootRange stx
      trace
      detail }

end Formatter.NativeLayout

end LeanFmt.Internal
