/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.Formatter

/-! Pure admission checks for a whole-module formatting draft.

The comparator consumes two lossless projections: the source's, and the candidate's from an
independent reading of the rendered bytes. Locations and whitespace lengths may change; node
kind/parent order, token ownership and spelling, header structure/token spelling, comment
payload/logical ownership, and terminal tail may not.

How the caller obtained the second projection — a second frontend, or a reparse under the first
run's parser contexts — arrives as `ValidationEvidence` and is recorded, never inferred. Keeping
this module pure makes the comparison independently testable and keeps it from acquiring frontend
authority. -/

namespace LeanFmt.Internal

inductive ValidationGate where
  | sourceMap
  | header
  | terminal
  | structure
  | tokens
  | comments
  | diagnostics
  | formatter
  | idempotence
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- What a gate checks, in the words someone using the formatter would use.

A message that reaches a user must call this rather than `Repr`. Under the private-by-default
module system `reprStr` on this type renders the mangled constructor name -- users were reading
`_private.LeanFmt.Validator.0.LeanFmt.Internal.ValidationGate.formatter` -- which names an
implementation detail they cannot act on and cannot look up. -/
def ValidationGate.describe : ValidationGate → String
  | .sourceMap => "source positions"
  | .header => "the import header"
  | .terminal => "the end of the file"
  | .structure => "the code's structure"
  | .tokens => "the tokens"
  | .comments => "the comments"
  | .diagnostics => "the compiler's messages"
  | .formatter => "the layout"
  | .idempotence => "formatting the result a second time"

structure ValidationFailure where
  gate : ValidationGate
  detail : String
  /-- Where in the *source* the failure came from, as normalized byte offsets, ascending and
  deduplicated. A caller that knows how source bytes are divided among commands uses these to blame
  the commands instead of the file.

  This module locates the divergence already -- every detail above names an index or a line -- so
  reporting the offsets costs nothing here and saves the caller from re-deriving a comparison it
  does not own. Empty where the gate has no site at all: the header, the terminal tail, and the
  source map, which is the whole tiling rather than a place in it.

  **Plural because a gate can find several, and reporting one made the caller pay per site.** The
  caller degrades a blamed command to its own bytes and validates again, and those rounds are
  bounded at two. A draft whose second render moved three commands was three rounds away from
  converging, so the file refused -- for want of two numbers this comparison had already computed
  and thrown away. -/
  sources : Array Nat := #[]
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- The site to name in a message, which is the first one found. -/
def ValidationFailure.source? (failure : ValidationFailure) : Option Nat :=
  failure.sources[0]?

/-- How much candidate validation a publishing `format` run owes its result. `.exact` is the
default and every non-`format` mode's only value: the candidate is structurally reparsed and then
admitted by a second render plus `Validator.admit`, with a full candidate frontend as the reparse's
escalation. `.structural` is the authorized `format --no-validate` exception: the candidate's
structural reparse still runs and still refuses, but the second render, `admit`, and the escalation
are skipped, and the bypass applies only where the module's syntax frontier was admitted (a
skeleton read over compiled evidence). The policy chooses evidence, never bytes: the rendered
candidate is the same deterministic function of source and configuration under either value. -/
inductive ValidationPolicy where
  | exact
  | structural
  deriving Inhabited, BEq, Repr

structure ValidationMetrics where
  frontendRuns : Nat
  renders : Nat
  structuralComparisons : Nat
  idempotencePasses : Nat
  /-- Commands the candidate's parse confirmed against the original's, one by one. Zero when a
  second frontend elaborated the candidate instead. -/
  reparsedCommands : Nat := 0
  /-- The layout was published on the structural candidate reparse alone (`format --no-validate`
  over an admitted syntax frontier): the second render, `Validator.admit`, and the candidate
  frontend escalation never ran. Always false on the default exact path. -/
  bypassed : Bool := false
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- How the caller obtained the second projection. `admit` records it rather than inferring it: the
comparison is the same either way, and this module stays free of any notion of a frontend.

`frontendRuns` is 2 when a second Lean frontend elaborated the candidate, 1 when the candidate was
reparsed under the first run's own parser contexts. `reparsedCommands` counts what that reparse
confirmed. -/
structure ValidationEvidence where
  frontendRuns : Nat
  reparsedCommands : Nat := 0

/-- A layout admitted after a fresh reading of the candidate and a byte-identical second formatting
pass. -/
structure CanonicalLayout where
  text : String
  sourceMap : Array Mark
  metrics : FormatMetrics
  validation : ValidationMetrics
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

namespace Validator

private def fail (gate : ValidationGate) (detail : String) (sources : Array Nat := #[]) :
    Except ValidationFailure α :=
  .error { gate, detail, sources }

private def slice (bytes : ByteArray) (start stop : Nat) : ByteArray :=
  bytes.extract (min start bytes.size) (min stop bytes.size)

private def kindOfNode (source : LosslessSource) (index : Nat) : String :=
  match source.nodes[index]? with
  | some node => source.kinds[node.kind]?.getD "<invalid-kind>"
  | none => "<invalid-node>"

/-- Check that a draft's marks form complete, ordered, non-overlapping source/output tilings. -/
def validateMap (draft : FormatDraft) : Except ValidationFailure Unit := do
  let mut sourceCursor := 0
  let mut outputCursor := 0
  for index in [0:draft.sourceMap.size] do
    let mark := draft.sourceMap[index]!
    unless mark.source.start <= mark.source.stop && mark.output.start <= mark.output.stop do
      return ← fail .sourceMap s!"map unit {index} has an inverted range"
    unless mark.source.start == sourceCursor do
      let relation :=
        if mark.source.start < sourceCursor then "overlaps or is out of order" else "leaves a gap"
      return ← fail .sourceMap s!"source map unit {index} {relation} at {sourceCursor}"
    unless mark.output.start == outputCursor do
      let relation :=
        if mark.output.start < outputCursor then "overlaps or is out of order" else "leaves a gap"
      return ← fail .sourceMap s!"output map unit {index} {relation} at {outputCursor}"
    sourceCursor := mark.source.stop
    outputCursor := mark.output.stop
  unless sourceCursor == draft.sourceBytes do
    return ← fail .sourceMap s!"source map stops at {sourceCursor}, expected {draft.sourceBytes}"
  unless outputCursor == draft.text.utf8ByteSize do
    return ←
        fail .sourceMap s!"output map stops at {outputCursor}, expected {draft.text.utf8ByteSize}"

/- A byte offset as `line:column`, both one-based and counted in characters, so a detail reads the
way the compiler's own diagnostics do. -/
private def position (text : String) (offset : Nat) : String :=
  let lines := (String.Pos.Raw.extract text ⟨0⟩ ⟨min offset text.utf8ByteSize⟩).splitOn "\n"
  s!"{lines.length}:{(lines.getLast?.map (·.length)).getD 0 + 1}"

/- Where two node enumerations first disagree, over the prefix they share.

A count mismatch is the one structural failure that cannot name its own node -- every later index is
shifted -- so this finds the divergence that shifted them. Use `nodeDivergenceSource?` to turn the
index into a position; the node's own range is often empty. -/
private def firstDivergentNode? (before after : LosslessSource) : Option Nat :=
  let shared := min before.nodes.size after.nodes.size
  (List.range shared).find? fun index =>
    kindOfNode before index != kindOfNode after index ||
      before.nodes[index]!.parent != after.nodes[index]!.parent

/- The source position that names a node divergence.

The divergence is usually an optional slot, which is empty and carries no range, so the node's own
`range.start` is `0` and names nothing -- neither a reader's file nor a command index. The
enumeration is ordered, so the nearest node at or before it that does carry a range is the site in
the *source*, which is the file a reader has open and the coordinate system the retry attributes in.

Every reader of a node divergence goes through here on purpose. The message and the attribution
disagreeing about where a divergence is has already cost one defect: the message anchored correctly
while the attribution took the empty slot, so the file refused with a position printed in it that
nothing had acted on. -/
private def nodeDivergenceSource? (before : LosslessSource) (index : Nat) : Option Nat :=
  ((List.range (index + 1)).reverse.find? fun candidate =>
        (before.nodes[candidate]?).any fun node => node.range.start != node.range.stop).bind
    fun candidate => (before.nodes[candidate]?).map (·.range.start)

/- Where two token enumerations first disagree over their shared prefix, by owner or by spelling.
The count-mismatch counterpart of `firstDivergentNode?`. A token always carries a real range, so
unlike a node its index maps straight to a source offset. -/
private def firstDivergentToken? (beforeText : String) (before : LosslessSource)
    (afterText : String) (after : LosslessSource) : Option Nat :=
  let beforeBytes := beforeText.toUTF8
  let afterBytes := afterText.toUTF8
  let shared := min before.tokens.size after.tokens.size
  (List.range shared).find? fun index =>
    let left := before.tokens[index]!
    let right := after.tokens[index]!
    left.node != right.node ||
      slice beforeBytes left.start left.stop != slice afterBytes right.start right.stop

/-- The first comment contract entry the two drafts disagree on, over their shared prefix. The
caller maps the index onto the source's comments; this module holds no comment positions. -/
def firstDivergentComment? (before after : Array CommentContractEntry) : Option Nat :=
  (List.range (min before.size after.size)).find? fun index => before[index]! != after[index]!

/- The node divergence as a phrase to append to a count mismatch. Diagnostic only: the gate has
already refused. -/
private def firstNodeDivergence (beforeText : String) (before : LosslessSource) (afterText : String)
    (after : LosslessSource) : String :=
  match firstDivergentNode? before after with
  | some index =>
    let candidate := after.nodes[index]!
    let location := position afterText candidate.range.start
    let anchor :=
      match nodeDivergenceSource? before index with
      | some offset => s!"; after {position beforeText offset} in source"
      | none => ""
    s!"; node {index} is {kindOfNode before index} before and \
      {kindOfNode after index} at {location} after{anchor}"
  | none => "; the enumerations agree up to the shorter one's end"

/-- Compare the enumerated normalized structure. The first mismatch identifies its node/token path. -/
def compare (beforeText : String) (before : LosslessSource) (afterText : String)
    (after : LosslessSource) : Except ValidationFailure Unit := do
  let beforeBytes := beforeText.toUTF8
  let afterBytes := afterText.toUTF8
  unless
    slice beforeBytes before.terminalStop beforeBytes.size ==
      slice afterBytes after.terminalStop afterBytes.size do
    return ← fail .terminal "terminal command or verbatim tail changed"
  unless before.nodes.size == after.nodes.size do
    return ←
        fail .structure
            s!"node count changed: {before.nodes.size} -> {after.nodes.size}\
      {firstNodeDivergence beforeText before afterText after}"
            ((firstDivergentNode? before after).bind (nodeDivergenceSource? before ·)).toArray
  for index in [0:before.nodes.size] do
    let left := before.nodes[index]!
    let right := after.nodes[index]!
    let leftKind := kindOfNode before index
    let rightKind := kindOfNode after index
    unless leftKind == rightKind && left.parent == right.parent do
      return ←
          fail .structure
              s!"node {index} changed kind/parent: {leftKind}/{left.parent} -> {rightKind}/{right.parent}"
              (nodeDivergenceSource? before index).toArray
  unless before.tokens.size == after.tokens.size do
    return ←
        fail .tokens s!"token count changed: {before.tokens.size} -> {after.tokens.size}"
            ((firstDivergentToken? beforeText before afterText after).map
                (before.tokens[·]!.start)).toArray
  for index in [0:before.tokens.size] do
    let left := before.tokens[index]!
    let right := after.tokens[index]!
    unless left.node == right.node do
      return ←
          fail .structure s!"token {index} changed owner {left.node} -> {right.node}" #[left.start]
    let leftText := slice beforeBytes left.start left.stop
    let rightText := slice afterBytes right.start right.stop
    unless leftText == rightText do
      return ←
          fail .tokens s!"token {index} ({kindOfNode before left.node}) changed spelling"
              #[left.start]

/-- The contract as a reflow-invariant word sequence: a standalone leading `--` prose line
contributes its words one at a time, anything else its whole entry. With `reflow-comments` on,
the layout may repack such a block's lines, which changes payload spellings and line counts but
never the word sequence -- so two contracts comparable here differ only by a reflow the
configuration authorized. Non-prose lines (empty, list items) and every other kind stay whole,
because the reflow keeps them verbatim and in order. -/
def reflowInvariantContract (entries : Array CommentContractEntry) : Array String :=
  entries.foldl (init := #[]) fun tokens entry =>
    let prose :=
      entry.kind == .line && entry.placement == .leading && entry.payload.startsWith "--" &&
        (Comments.commentLineText entry.payload).trimAscii.copy.isEmpty == false
    if prose && !entry.suppressed then
      tokens ++ (Comments.commentWords (Comments.commentLineText entry.payload)).map ("w:" ++ ·)
    else
      tokens.push
        s!"{repr entry.kind}/{repr entry.placement}/{entry.ownerKind}/{entry.ownerPath}/\
          {entry.suppressed}/{entry.payload}"

/- The source offsets behind a set of divergent output rows, ascending and deduplicated.

The rows are in the *rendered* draft, and the draft's own map is the only thing that says which
source bytes produced them. The map tiles the output, so the mark covering a row's first byte is
unique, and one source offset per mark is all a caller can act on -- twenty moved rows inside one
command are one command to degrade.

Both sequences ascend, so this is the same merge `Comments.assignAll` walks and not a lookup per
row: a draft that moved wholesale diverges on every row it has, and a scan of the map for each of
them would be quadratic in the size of the file at exactly the moment the file is already failing. -/
private def idempotenceSources (marks : Array Mark) (rows : List String) (divergent : List Nat) :
    Array Nat :=
  Id.run do
    let rowStarts :=
      (rows.foldl (init := (#[0], 0)) fun (starts, cursor) row =>
          let next := cursor + row.utf8ByteSize + 1
          (starts.push next, next)).1
    let mut sources := #[]
    let mut cursor := 0
    for index in divergent do
      let some offset := rowStarts[index]? | continue
      while cursor < marks.size && marks[cursor]!.output.stop <= offset do
        cursor := cursor + 1
      let some mark := marks[cursor]? | break
      if mark.output.start <= offset && sources.back? != some mark.source.start then
        sources := sources.push mark.source.start
    return sources

/-- Admit the first draft using a freshly parsed/formatted second draft. -/
def admit (beforeText : String) (before : LosslessSource) (first : FormatDraft)
    (after : LosslessSource) (second : FormatDraft) (evidence : ValidationEvidence)
    (reflowComments : Bool := false) : Except ValidationFailure CanonicalLayout := do
  validateMap first
  validateMap second
  compare beforeText before first.text after
  unless first.headerContract == second.headerContract do
    return ← fail .header "module/header/import structure or token spelling changed"
  let commentsMatch :=
    if reflowComments then
      reflowInvariantContract first.commentContract ==
        reflowInvariantContract second.commentContract
    else first.commentContract == second.commentContract
  unless commentsMatch do
    if first.commentContract.size != second.commentContract.size then
      return ←
          fail .comments
              s!"comment contract count changed: \
        {first.commentContract.size} -> {second.commentContract.size}"
    for index in [0:first.commentContract.size] do
      let left := first.commentContract[index]!
      let right := second.commentContract[index]!
      unless left == right do
        return ← fail .comments s!"comment {index} changed: {repr left} -> {repr right}"
    return ← fail .comments "comment kind, payload, order, or logical owner path changed"
  unless second.text == first.text do
    -- A byte count alone says the second pass moved something and nothing about what. Every one of
    -- these has to be minimized by hand out of a whole module otherwise, so the failure names the
    -- line the two passes first disagree on and spells both -- and blames *every* row that moved,
    -- not just that one, because the caller degrades one command per round against a bound of two
    -- rounds.
    let firstLines := first.text.splitOn "\n"
    let secondLines := second.text.splitOn "\n"
    let divergent :=
      (List.range (min firstLines.length secondLines.length)).filter fun index =>
        firstLines[index]! != secondLines[index]!
    let divergence :=
      match divergent with
      | [] => s!"; line counts {firstLines.length} -> {secondLines.length}"
      | index :: rest =>
        let others := if rest.isEmpty then "" else s!" and {rest.length} more row(s)"
        s!" at line {index + 1}{others}: {repr firstLines[index]!} -> {repr secondLines[index]!}"
    return ←
        fail .idempotence s!"formatting the reparsed candidate changed bytes{divergence}"
            (idempotenceSources first.sourceMap firstLines divergent)
  return {
      text := first.text
      sourceMap := first.sourceMap
      metrics := { first.metrics with frontendRuns := evidence.frontendRuns }
      validation :=
        { frontendRuns := evidence.frontendRuns
          renders := 2
          structuralComparisons := 1
          idempotencePasses := 1
          reparsedCommands := evidence.reparsedCommands } }

end Validator

end LeanFmt.Internal
