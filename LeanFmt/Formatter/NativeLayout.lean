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
fallback. The one offside constraint repairs the parser-significant continuation of guarded `let` by
dedenting the native subtree that spells that structural child.

Doc comments are syntax, not trivia, so they are ordinary terminals: their opening token and body align
and emit original bytes exactly where their owner spells them. Hoisting them to a command prefix moved
a field or constructor docstring off its owner and left the native separator behind, which is why no
prefix mechanism exists here.

An exact island whose payload spans lines carries its own absolute source columns. `Std.Format`
re-indents every newline inside a `text` leaf to the ambient indentation, and that indentation is
exactly the sum of the enclosing `nest` amounts plus the column the leaf is rendered at — `align` pads
output without changing it (`Init/Data/Format/Basic.lean`). The adapter therefore wraps a multiline
island in a `nest` that cancels both, and `Int.toNat` clamps the result to column zero.

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

private structure OffsideConstraint where
  range : SourceRange
  indentAdjustment : Int
  deriving Inhabited

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
`containsAtom`, and `collectRecordUpdateFieldStarts`. That is four assumptions, not four checks, on a
node this repository records hitting 1 of 5 sampled mathlib modules. One gate at the entry point makes
the assumption true for all of them rather than repeating the comparison four times.

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

What this gate does *not* cover is `containsAtom`'s question, which is about a leaf's constructor
rather than its bytes: two alternatives could in principle spell identical source with an atom on one
side and an ident on the other. No such node has been observed, and the parser does not build one, so
it is recorded here rather than guarded. -/
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

private partial def containsAtom (expected : String) : Lean.Syntax → Bool
  | .atom _ value => value == expected
  | .node _ kind children =>
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.any (containsAtom expected)
  | _ => false

/- In `{ base with fields }`, `sepByIndent` requires a broken field sequence to begin on its own line.
Lean's native document can otherwise keep the first field after `with` while breaking a later comma,
dedenting that later field below the parser's reference column. This constraint forces only the
delimiter-to-first-field boundary; the native field document still controls every inner break. -/
private partial def collectRecordUpdateFieldStarts (stx : Lean.Syntax)
    (starts : Array Nat := #[]) : Array Nat :=
  match stx with
  | .node _ kind children =>
    let starts :=
      if kind == ``Lean.Parser.Term.structInst then
        match children.findIdx? (·.isOfKind ``Lean.Parser.Term.structInstFields) with
        | some fieldsIndex =>
          let updatePrefix := children.extract 0 fieldsIndex
          if updatePrefix.any (containsAtom "with") then
            match (selectedLeafRanges children[fieldsIndex]!)[0]? with
            | some range => if starts.contains range.start then starts else starts.push range.start
            | none => starts
          else starts
        | none => starts
      else starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child =>
      collectRecordUpdateFieldStarts child starts
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

/- `indent` is `Std.Format.getIndent`, the `format.indent` option Lean's own `ppIndent`/`ppDedent`
read. A constraint here cancels one level of the indentation native layout introduced, so it is that
same quantity negated -- not the literal `-2` this used to spell. The default happens to be 2, which is
why the constant went unnoticed; a project that sets `format.indent` would have silently drifted. -/
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
            | some range => constraints.push { range, indentAdjustment := -(indent : Int) }
            | none => constraints
          else constraints
        | none => constraints
      else constraints
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
  islands : Array ExactIsland
  droppedIslands : Array String
  constraints : Array (OffsideConstraint × TokenSpan)
  flatBoundaries : Array Nat
  hardBoundaries : Array Nat
  baseIndent : Nat
  terminalIndex : Nat := 0
  commentIndex : Nat := 0
  ambientNest : Int := 0
  appliedIslands : Array String := #[]
  appliedConstraints : Array Nat := #[]
  appliedFlatBoundaries : Array Nat := #[]
  appliedHardBoundaries : Array Nat := #[]
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

private def insertComments (comments : Array InteriorComment) (suffix : Std.Format) : Std.Format :=
  let (document, atLineStart) := comments.foldl (init := (.nil, false))
    fun (document, atLineStart) comment =>
      match comment.placement with
      | .trailing =>
        let boundary := if atLineStart then .nil else .text " "
        let document := .append document (.append boundary (.text comment.payload))
        if comment.kind == .line then (.append document (.text "\n"), true)
        else (document, false)
      | .leading | .dangling =>
        let boundary := if atLineStart then .nil else .text "\n"
        (.append document <| .append boundary <| .append (.text comment.payload) (.text "\n"), true)
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

private def finishConstraint (result : Transformed) (eligible := false) :
    StateT TransformState (Except String) Transformed := do
  unless eligible do return result
  let state ← get
  match result.span? with
  | none => return result
  | some span =>
    match state.constraints.findIdx? fun (_, expected) =>
        expected == span with
    | some index =>
      if state.appliedConstraints.contains index then return result
      let (constraint, _) := state.constraints[index]!
      set { state with
        appliedConstraints := state.appliedConstraints.push index
        metrics := { state.metrics with
          offsideConstraints := state.metrics.offsideConstraints + 1 } }
      return { result with format := .nest constraint.indentAdjustment result.format }
    | none => return result

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

private def constrainBoundary (format : Std.Format) :
    StateT TransformState (Except String) Std.Format := do
  let state ← get
  if insideIsland state then return .nil
  let mut format := format
  if state.hardBoundaries.contains state.terminalIndex &&
      !state.appliedHardBoundaries.contains state.terminalIndex then
    set { state with
      appliedHardBoundaries := state.appliedHardBoundaries.push state.terminalIndex
      metrics := { state.metrics with
        offsideConstraints := state.metrics.offsideConstraints + 1 } }
    format := .text "\n"
  else if state.flatBoundaries.contains state.terminalIndex &&
      !state.appliedFlatBoundaries.contains state.terminalIndex then
    set { state with
      appliedFlatBoundaries := state.appliedFlatBoundaries.push state.terminalIndex
      metrics := { state.metrics with
        offsideConstraints := state.metrics.offsideConstraints + 1 } }
    format := .text " "
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
    format := insertComments comments format
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
      .nest (-(state.baseIndent + state.ambientNest)) payload
    else payload
  let payload := if startsLine then .append (.text "\n") payload else payload
  finishConstraint { format := payload, span? := some ⟨start, stop⟩ }

private def transformOrdinaryText (value : String) :
    StateT TransformState (Except String) Transformed := do
  let state ← get
  if value.trimAscii.isEmpty then
    set { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    finishConstraint { format := ← constrainBoundary (.text value) }
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
    finishConstraint {
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
      finishConstraint {
        format := .append island.format current.format
        span? := mergeSpan island.span? current.span? }
    | none =>
      transformOrdinaryText value

private partial def transformNative : Std.Format →
    StateT TransformState (Except String) Transformed
  | .nil => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    finishConstraint { format := .nil }
  | .line => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    finishConstraint { format := ← constrainBoundary .line }
  | .align force => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    if insideIsland (← get) then return { format := .nil }
    modify fun state => { state with separated := true }
    finishConstraint { format := .align force }
  | .text value => transformText value
  | .nest indent inner => do
    modify fun state => { state with
      ambientNest := state.ambientNest + indent
      metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
    let inner ← transformNative inner
    modify fun state => { state with ambientNest := state.ambientNest - indent }
    finishConstraint { inner with format := .nest indent inner.format }
  | .append left right => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    let left ← transformNative left
    let right ← transformNative right
    finishConstraint {
      format := .append left.format right.format
      span? := mergeSpan left.span? right.span? }
      (eligible := left.span?.isNone && hasLineBoundary left.format)
  | .group inner behavior => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    let inner ← transformNative inner
    finishConstraint { inner with format := .group inner.format behavior }
  | .tag tag inner => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    let inner ← transformNative inner
    finishConstraint { inner with format := .tag tag inner.format }

private def spanForRange (terminals : Array Terminal) (range : SourceRange) : TokenSpan :=
  let start := terminals.findIdx? (range.start <= ·.range.start) |>.getD terminals.size
  let stop := terminals.findIdx? (range.stop <= ·.range.start) |>.getD terminals.size
  ⟨start, stop⟩

/- Which terminal a collected source offset constrains: the first one at or after it.

Boundaries are collected by grammar shape and applied by kind, so more than one collector can name the
same terminal. `constrainBoundary` applies a boundary once, so a repeated index would leave the applied
count permanently short of the collected one and turn every such command into a refusal. -/
private def boundaryIndices (terminals : Array Terminal) (starts : Array Nat) : Array Nat :=
  starts.foldl (init := #[]) fun indices start =>
    match terminals.findIdx? (start <= ·.range.start) with
    | some index => if indices.contains index then indices else indices.push index
    | none => indices

private def transform (source : String) (terminals : Array Terminal)
    (comments : Array InteriorComment)
    (islands : Array ExactIsland) (constraints : Array OffsideConstraint)
    (flatStarts hardStarts : Array Nat) (baseIndent : Nat)
    (native : Std.Format) : Except String (Std.Format × Metrics) := do
  let constraints := constraints.map fun constraint =>
    (constraint, spanForRange terminals constraint.range)
  let flatBoundaries := boundaryIndices terminals flatStarts
  let hardBoundaries := boundaryIndices terminals hardStarts
  let comments := comments.map fun comment =>
    { comment with
      boundary := terminals.findIdx? (comment.range.start < ·.range.start) |>.getD terminals.size }
  let spelled := spelledMarkers native
  let droppedIslands := islands.filterMap fun island =>
    if spelled.contains island.marker then none else some island.marker
  let initial : TransformState := {
    source, terminals, comments, islands, droppedIslands, constraints, flatBoundaries,
    hardBoundaries, baseIndent }
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
  if state.appliedFlatBoundaries.size != flatBoundaries.size then
    throw s!"native formatter applied {state.appliedFlatBoundaries.size}/{flatBoundaries.size} \
flat boundaries"
  if state.appliedHardBoundaries.size != hardBoundaries.size then
    throw s!"native formatter applied {state.appliedHardBoundaries.size}/{hardBoundaries.size} \
hard boundaries"
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

private partial def nativeSize : Std.Format → Nat
  | .nest _ inner | .group inner _ | .tag _ inner => 1 + nativeSize inner
  | .append left right => 1 + nativeSize left + nativeSize right
  | _ => 1

/-- Format one actual command through Lean's live registry, preserving source payloads and applying
only the structurally measured guarded-`let` continuation constraint. `baseIndent` is the column the
resulting registered leaf is rendered at; an exact island's dedent must cancel it. -/
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
  let constraints := collectOffsideConstraints formatIndent stripped
  let flatStarts := collectUngroupedBodyStarts stripped (collectReturnTermStarts stripped)
  let hardStarts := collectRecordUpdateFieldStarts stripped
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
    match transform source terminals comments islands constraints flatStarts
        hardStarts baseIndent native with
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
