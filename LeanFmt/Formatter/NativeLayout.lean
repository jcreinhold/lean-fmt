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

private def isDocComment (value : String) : Bool :=
  value.startsWith "/--" || value.startsWith "/-!"

private partial def terminalsFrom (source : String) (stx : Lean.Syntax)
    (result : Array Terminal := #[]) : Array Terminal :=
  match stx with
  | .missing => result
  | .atom _ syntaxSpelling =>
    match sourceRange? stx with
    | some range =>
      let sourceSpelling := slice source range
      if sourceSpelling.isEmpty || isDocComment sourceSpelling then result
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
    if kind == ``Lean.Parser.Command.docComment ||
        kind == ``Lean.Parser.Command.moduleDoc then result
    else if kind == Lean.choiceKind then
      match children[0]? with
      | some selected => terminalsFrom source selected result
      | none => result
    else
      children.foldl (init := result) fun terminals child =>
        terminalsFrom source child terminals

private def sourceDataKind (kind : Lean.Name) : Bool :=
  kind == Lean.interpolatedStrKind || kind.toString.contains ".pseudo.antiquot"

private def markerFor (range : SourceRange) : String :=
  s!"leanFmtExact{range.start}x{range.stop}"

private def placeholder (info : Lean.SourceInfo) (marker : String) : Lean.Syntax :=
  .ident info marker.toRawSubstring marker.toName []

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
      stx := placeholder info marker
      islands := #[{ marker, range, text := slice source range }] }
  | none => { stx }

private partial def protectSourceDataFrom (source : String) : Lean.Syntax → ProtectedSyntax
  | .missing => { stx := .missing }
  | .atom info spelling =>
    let stx := Lean.Syntax.atom info spelling
    match sourceRange? stx with
    | some range =>
      let text := slice source range
      if text.contains '\n' && !isDocComment text then
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
    if kind == ``Lean.Parser.Command.docComment ||
        kind == ``Lean.Parser.Command.moduleDoc then
      { stx }
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
            kind.toString.contains "interpolatedStr"
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

private partial def docIslandsFrom (source : String) (stx : Lean.Syntax)
    (islands : Array ExactIsland := #[]) : Array ExactIsland :=
  if stx.isOfKind ``Lean.Parser.Command.docComment ||
      stx.isOfKind ``Lean.Parser.Command.moduleDoc then
    match sourceRange? stx with
    | some range =>
      islands.push {
        marker := markerFor range
        range
        text := (slice source range).trimAscii.copy }
    | none => islands
  else
    stx.getArgs.foldl (init := islands) fun islands child =>
      docIslandsFrom source child islands

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

private partial def collectOffsideConstraints (stx : Lean.Syntax)
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
            | some range => constraints.push { range, indentAdjustment := -2 }
            | none => constraints
          else constraints
        | none => constraints
      else constraints
    children.foldl (init := constraints) fun constraints child =>
      collectOffsideConstraints child constraints
  | _ => constraints

private def commentText (value : String) : Bool :=
  let trimmed := value.trimAscii.copy
  trimmed.startsWith "--" || trimmed.startsWith "/-"

private def replacePayload (value payload : String) : String :=
  let trimmed := value.trimAscii.copy
  if trimmed.isEmpty then value else value.replace trimmed payload

private def layoutWhitespace (char : Char) : Bool :=
  char == ' ' || char == '\t' || char == '\n' || char == '\r'

private def splitPadding (value : String) : String × String :=
  let chars := value.toList
  let leading := chars.takeWhile layoutWhitespace
  let remainder := chars.drop leading.length
  let trailing := remainder.reverse.takeWhile layoutWhitespace |>.reverse
  (String.ofList leading, String.ofList trailing)

private def findBytesFrom (haystack needle : ByteArray) (start : Nat) : Option Nat := Id.run do
  if needle.isEmpty then return some (min start haystack.size)
  if haystack.size < needle.size || haystack.size - needle.size < start then return none
  for index in [start:haystack.size - needle.size + 1] do
    if haystack.extract index (index + needle.size) == needle then return some index
  return none

/- A native comment leaf may hold several consecutive source comments. Match exact payload bytes in
order rather than equating one `Std.Format.text` leaf with one comment assignment. Returning the leaf
unchanged is safe precisely because every consumed payload occurs byte-for-byte in it. -/
private def matchedCommentStop (value : String) (comments : Array String) (start : Nat) : Nat :=
  Id.run do
    let bytes := value.toUTF8
    let mut index := start
    let mut cursor := 0
    while index < comments.size do
      let payload := comments[index]!.toUTF8
      match findBytesFrom bytes payload cursor with
      | some found =>
        cursor := found + payload.size
        index := index + 1
      | none => break
    return index

private def mergeSpan : Option TokenSpan → Option TokenSpan → Option TokenSpan
  | none, right => right
  | left, none => left
  | some left, some right => some ⟨min left.start right.start, max left.stop right.stop⟩

private structure TransformState where
  source : String
  terminals : Array Terminal
  comments : Array InteriorComment
  islands : Array ExactIsland
  constraints : Array (OffsideConstraint × TokenSpan)
  flatBoundaries : Array Nat
  hardBoundaries : Array Nat
  terminalIndex : Nat := 0
  commentIndex : Nat := 0
  skippingDocSyntax : Bool := false
  appliedIslands : Array String := #[]
  appliedConstraints : Array Nat := #[]
  appliedFlatBoundaries : Array Nat := #[]
  appliedHardBoundaries : Array Nat := #[]
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
  if atLineStart then document else .append document suffix

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

private def constrainBoundary (format : Std.Format) :
    StateT TransformState (Except String) Std.Format := do
  let state ← get
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
    return insertComments comments format
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
    throw s!"exact island {island.range.start}:{island.range.stop} contains no terminal"
  set { state with
    terminalIndex := stop
    appliedIslands := state.appliedIslands.push island.marker
    metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1
      tokenLeaves := state.metrics.tokenLeaves + 1
      exactIslands := state.metrics.exactIslands + 1
      exactIslandBytes := state.metrics.exactIslandBytes + island.text.utf8ByteSize } }
  finishConstraint {
    format := .text (replacePayload value island.text)
    span? := some ⟨start, stop⟩ }

private partial def transformOrdinaryText (value : String) :
    StateT TransformState (Except String) Transformed := do
  let state ← get
  if state.skippingDocSyntax then
    if value.trimAscii.isEmpty then
      set { state with metrics := { state.metrics with
        nativeNodes := state.metrics.nativeNodes + 1 } }
      finishConstraint { format := .nil }
    else
      let nativePayload := value.trimAscii.copy
      match state.terminals[state.terminalIndex]? with
      | some terminal =>
        if nativePayload == terminal.syntaxSpelling ||
            nativePayload == terminal.sourceSpelling then
          set { state with skippingDocSyntax := false }
          transformOrdinaryText nativePayload
        else
          set { state with metrics := { state.metrics with
            nativeNodes := state.metrics.nativeNodes + 1 } }
          finishConstraint { format := .nil }
      | none =>
        set { state with metrics := { state.metrics with
          nativeNodes := state.metrics.nativeNodes + 1 } }
        finishConstraint { format := .nil }
  else if value.trimAscii.isEmpty then
    set { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    finishConstraint { format := ← constrainBoundary (.text value) }
  else if commentText value then
    if isDocComment value.trimAscii.copy then
      set { state with
        skippingDocSyntax := true
        metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
      finishConstraint { format := .nil }
    else
      throw s!"comment-free native syntax emitted an interior comment leaf {repr value}"
  else
    let some terminal := state.terminals[state.terminalIndex]?
      | throw s!"native formatter emitted extra text leaf {repr value} after \
{state.terminalIndex} terminals; nearby: {nearbyTerminals state}"
    let nativePayload := value.trimAscii.copy
    let normalized := nativePayload != terminal.syntaxSpelling &&
      nativePayload != terminal.sourceSpelling
    let (leading, trailing) := splitPadding value
    let boundary ← constrainBoundary (.text leading)
    let state ← get
    set { state with
      terminalIndex := state.terminalIndex + 1
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
    let pending? := state.terminals[state.terminalIndex]?.bind fun terminal =>
      state.islands.find? fun island =>
        !state.appliedIslands.contains island.marker &&
          island.range.start == terminal.range.start
    match pending? with
    | some exact =>
      let state ← get
      let gap := match state.terminals[state.terminalIndex - 1]? with
        | some previous => slice state.source ⟨previous.range.stop, exact.range.start⟩
        | none => ""
      let gap := if gap.contains '\n' then gap else if gap.isEmpty then "" else " "
      let island ← consumeIsland exact.marker exact
      let island := if gap.isEmpty then island else
        { island with format := .append (.text gap) island.format }
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
    finishConstraint { format := .align force }
  | .text value => transformText value
  | .nest indent inner => do
    modify fun state => { state with metrics := { state.metrics with
      nativeNodes := state.metrics.nativeNodes + 1 } }
    let inner ← transformNative inner
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

private def transform (source : String) (terminals : Array Terminal)
    (comments : Array InteriorComment)
    (islands : Array ExactIsland) (constraints : Array OffsideConstraint)
    (returnTermStarts recordUpdateFieldStarts : Array Nat)
    (native : Std.Format) : Except String (Std.Format × Metrics) := do
  let constraints := constraints.map fun constraint =>
    (constraint, spanForRange terminals constraint.range)
  let flatBoundaries := returnTermStarts.filterMap fun start =>
    terminals.findIdx? (start <= ·.range.start)
  let hardBoundaries := recordUpdateFieldStarts.filterMap fun start =>
    terminals.findIdx? (start <= ·.range.start)
  let comments := comments.map fun comment =>
    { comment with
      boundary := terminals.findIdx? (comment.range.start < ·.range.start) |>.getD terminals.size }
  let initial : TransformState := {
    source, terminals, comments, islands, constraints, flatBoundaries, hardBoundaries }
  let (result, state) ← (transformNative native).run initial
  if state.terminalIndex != terminals.size then
    throw s!"native formatter consumed {state.terminalIndex}/{terminals.size} terminals; \
nearby: {nearbyTerminals state}; recent native leaves: {repr state.recentNativeLeaves}"
  if state.commentIndex != comments.size then
    let nextRange := comments[state.commentIndex]?.map fun comment => comment.range
    throw s!"native formatter inserted {state.commentIndex}/{comments.size} interior comments; \
next expected range: {repr nextRange}; recent native leaves: \
{repr state.recentNativeLeaves}"
  if state.skippingDocSyntax then
    throw "native formatter ended inside suppressed doc syntax"
  if state.appliedIslands.size != islands.size then
    throw s!"native formatter applied {state.appliedIslands.size}/{islands.size} exact islands"
  if state.appliedConstraints.size != constraints.size then
    throw s!"native formatter applied {state.appliedConstraints.size}/{constraints.size} \
offside constraints"
  if state.appliedFlatBoundaries.size != flatBoundaries.size then
    throw s!"native formatter applied {state.appliedFlatBoundaries.size}/{flatBoundaries.size} \
return-term constraints"
  if state.appliedHardBoundaries.size != hardBoundaries.size then
    throw s!"native formatter applied {state.appliedHardBoundaries.size}/{hardBoundaries.size} \
record-update field constraints"
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

private def exactDocument (text : String) : Doc :=
  if text.contains '\n' then Doc.verbatim text else Doc.text text

private def docPrefix (islands : Array ExactIsland) : Option Doc :=
  islands.foldl (init := none) fun document? island =>
    let next := exactDocument island.text
    some <| match document? with
      | some document => document ++ Doc.hard ++ next
      | none => next

private def addDocMetrics (metrics : Metrics) (islands : Array ExactIsland) : Metrics :=
  { metrics with
    commentLeaves := metrics.commentLeaves + islands.size
    exactIslands := metrics.exactIslands + islands.size
    exactIslandBytes := metrics.exactIslandBytes +
      islands.foldl (init := 0) fun bytes island => bytes + island.text.utf8ByteSize }

/-- Format one actual command through Lean's live registry, preserving source payloads and applying
only the structurally measured guarded-`let` continuation constraint. -/
def command (source : String) (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure Document) := do
  let trace ← Formatter.trace ownership .command stx
  let stripped := Formatter.withoutBoundaryTrivia stx
  let terminals := terminalsFrom source stripped
  let comments := interiorComments ownership stx
  let docIslands := docIslandsFrom source stripped
  let constraints := collectOffsideConstraints stripped
  let returnTermStarts := collectReturnTermStarts stripped
  let recordUpdateFieldStarts := collectRecordUpdateFieldStarts stripped
  let commentFree := withoutTrivia stripped
  let (formattedSyntax, islands) := protectSourceData source commentFree
  try
    let native ← Lean.PrettyPrinter.formatCommand formattedSyntax
    if stx.isOfKind ``Lean.Parser.Command.moduleDoc then
      let some document := docPrefix docIslands
        | return .error {
            category := .command
            kind := stx.getKind
            range := rootRange stx
            trace
            detail := "module-doc command has no exact doc island" }
      let metrics := addDocMetrics { nativeNodes := nativeSize native } docIslands
      return .ok { document, trace, metrics }
    else
      match transform source terminals comments islands constraints returnTermStarts
          recordUpdateFieldStarts native with
      | .ok (native, metrics) =>
        let metrics := addDocMetrics metrics docIslands
        let document := match docPrefix docIslands with
          | some leadingDocs => leadingDocs ++ Doc.hard ++ Doc.registered native
          | none => Doc.registered native
        return .ok { document, trace, metrics }
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
