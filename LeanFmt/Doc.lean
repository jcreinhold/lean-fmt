/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.LosslessSource
import all LeanFmt.NativeFormat

/-! A formatting document and its bounded renderer, native-compatible.

The document algebra has two tiers. The **native fragment** — `empty`, `text`, `nativeText`,
`line`, `cat`, `nest`, `group`, `fill`, `align`, `tag` — expresses every `Std.Format`
constructor, and renders with the semantics of the vendored machine in `LeanFmt/NativeFormat.lean`
(the compatibility contract is `notes/02-native-contract.md` in the layout-redesign stack): an
allOrNone group decides once against its body *and the enclosing remainder*, a `fill` group
re-decides per break with one column charged for the candidate space, an `align` pads to the
current indent or breaks at it, a `nest` is signed, a `tag` is invisible to fit, and a
newline-bearing `nativeText` re-indents its continuations and re-groups the remainder of its
group. Columns count codepoints, matching `Std.Format`; source and output ranges count UTF-8
bytes.

The **annotation tier** — `comment`, `hard`, `blank`, `verbatim`, `mark`, `registered`, and the
one layout relation native cannot express, `anchor` — carries lean-fmt's own semantics, which
never alter a native decision: a comment is zero-width to fit, `hard`/`blank`/`verbatim` are hard
stops (and stay broken — the native re-grouping after a hard event applies to `nativeText` only,
which is what native `text` lowers to), a `mark` composes like a `tag`, and a `registered` leaf
stays an opaque fit boundary interpreted through the vendored machine.

`anchor body` captures the column at which `body` begins — an already-emitted, backward-only
column — and renders `body` with its base indent re-set to that column: breaks inside `body`
land where the row started, not at the ambient indent. It is invisible to fit (measurement
passes through it), and nested anchors use the innermost capture. An `anchor` whose body begins
with a break captured nothing and is a development error, not a source fallback.

The renderer is the vendored machine's work list: groups of `(indent, document, open-tags)`
items, each group carrying a flatten decision and a flatten behavior. Every document caches the
width up to its first forced break in flat and broken modes, plus a `contextual` bit that is set
exactly where the cached measure is not the whole story — an `align`, whose native measure
charges phantom columns against the decision column, or a `registered` leaf. The caches are
composed at every item-list node, so a group decision on a context-free suffix is constant time,
and a fill's per-break re-decision or the re-grouping after a native hard line wraps the *same*
items in a freshly decided group without re-measuring them. A contextual suffix is walked item by
item with the native measure. This keeps renderer work linear in document nodes plus marks on the
context-free documents the adversarial rows exercise, while native measures stay exact where they
can be observed. A `group`'s decision is the native one except for the `pinned-comments`
override: a group that would break because its code alone overflows still flattens when the line
carries a pinned comment, because splitting there would detach a tooling directive from the
construct it annotates. -/

namespace LeanFmt.Internal

private structure LineMeasure where
  width : Nat
  boundary : Bool
  /-- The machine's `foundFlattenedHardLine`: a hard line this measure would flatten if its group
  flattened. Set only on measures taken flat — a broken measure stops *at* the hard line instead —
  except through an unexpanded `group`/`fill` node, whose interior the machine always measures
  flat. A group decision denies the flatten when its candidate's own measure carries this, for
  both flatten behaviors. -/
  flattenedHard : Bool
  /-- The first comment text between here and the next forced break, if any. Renderers match it
  against the pinned phrases when a group decision is made; one entry suffices because a line
  comment is always the last comment on its line, and stacked block comments are the rare case the
  first entry already represents. -/
  comment? : Option String := none
  /-- Set where the cached measure is not the native measure: an `align` (whose measure depends on
  the decision column) or a `registered` leaf (opaque). A context-free suffix decides in constant
  time; a contextual one is walked with the native measure. -/
  contextual : Bool := false

namespace LineMeasure

def empty : LineMeasure :=
  ⟨0, false, false, none, false⟩

/-- Compose two adjacent measures. A hard stop on the left ends the walk, so the right side —
contextual or not — is unreachable; otherwise contextuality propagates. -/
def append (left right : LineMeasure) : LineMeasure :=
  if left.boundary then left
  else
    ⟨left.width + right.width, right.boundary, left.flattenedHard || right.flattenedHard,
      left.comment? <|> right.comment?, left.contextual || right.contextual⟩

end LineMeasure

/-- One source line of a reflowable comment block: a `prose` line joins the paragraph around it
and packs against the render column; a `keep` line — an empty comment line or a list item —
splits the paragraph and always keeps its bytes. The payload is the full source line, marker
included. The pack decision itself is the renderer's: it owns the column, the margin, and the
pinned phrases, so a block whose bytes depend on them is spelled nowhere else. -/
inductive FillLine where
  | prose (payload : String)
  | keep (payload : String)
  deriving Inhabited, BEq, Repr

/-- The full source line a fill line carries. -/
def FillLine.payload : FillLine → String
  | .prose value => value
  | .keep value => value

mutual
private inductive DocKind where
  | empty
  | text (value : String)
  | nativeText (value : String)
  | comment (value : String)
  | line (flat : String)
  | hard
  | blank
  | verbatim (value : String)
  | cat (left right : Doc)
  | nest (indent : Int) (body : Doc)
  | group (body : Doc)
  | fill (body : Doc)
  | align (force : Bool)
  | tag (tag : Nat) (body : Doc)
  | anchor (body : Doc)
  | mark (source : SourceRange) (body : Doc)
  | registered (format : Std.Format)
  | fillWords (lines : Array FillLine)
/-- A formatting document. Construct values through the operations in `Doc`; the cached measures
  and well-formedness bit are not caller-settable, deliberately. -/
inductive Doc where
  | private mk (kind : DocKind) (flat broken : LineMeasure) (nodes : Nat) (valid : Bool)
end

namespace Doc

private def kind : Doc → DocKind
  | .mk value .. => value

private def flatMeasure : Doc → LineMeasure
  | .mk _ value .. => value

private def brokenMeasure : Doc → LineMeasure
  | .mk _ _ value .. => value

/-- Number of custom document nodes. One registered formatter result is one opaque node. -/
def size : Doc → Nat
  | .mk _ _ _ value _ => value

/-- Whether all single-line literals are single-line and every source range is ordered. Mark scopes
are balanced by construction because a mark owns its complete subdocument. -/
def wellFormed : Doc → Bool
  | .mk _ _ _ _ value => value

/-- Column width in codepoints, the unit used by Lean's formatter. -/
def width (value : String) : Nat :=
  value.length

private def spansLines (value : String) : Bool :=
  value.contains '\n'

private def firstLine (value : String) : String :=
  match (value.splitOn "\n")[0]? with
  | some line => line
  | none => value

private def lastLine (value : String) : String :=
  match (value.splitOn "\n").getLast? with
  | some line => line
  | none => value

private def literalMeasure (value : String) : LineMeasure :=
  if spansLines value then ⟨width (firstLine value), true, true, none, false⟩
  else ⟨width value, false, false, none, false⟩

/-- The broken-mode column of a literal: it stops at the newline, so nothing is flattened over it
and `flattenedHard` stays clear. -/
private def literalBrokenMeasure (value : String) : LineMeasure :=
  ⟨width (firstLine value), spansLines value, false, none, false⟩

/-- The empty document. -/
def empty : Doc :=
  .mk .empty .empty .empty 1 true

/-- Literal single-line text. A newline makes the resulting document ill-formed; a newline-bearing
literal with native re-indentation is `nativeText`. -/
def text (value : String) : Doc :=
  .mk (.text value) (literalMeasure value) (literalBrokenMeasure value) 1 (!spansLines value)

/-- Newline-bearing literal text with native semantics: each embedded newline breaks to the item's
current indent and re-groups the remainder of the enclosing group. This is what native
`Std.Format.text` lowers to; `verbatim` is the annotation-tier literal that owns its columns. -/
def nativeText (value : String) : Doc :=
  .mk (.nativeText value) (literalMeasure value) (literalBrokenMeasure value) 1 true

/-- A single-line comment payload. Renders exactly like `text`, but carries a zero fit measure and
discloses its text, so no group decision is driven by a comment's width while a pinned comment can
still hold its line flat. -/
def comment (value : String) : Doc :=
  .mk (.comment value) ⟨0, false, false, some value, false⟩ ⟨0, false, false, some value, false⟩ 1
    (!spansLines value)

/-- The text a `--` line carries after its marker: one leading space is part of the spelling,
not the prose. Shared by the fill-words render and the validator's reflow-invariant contract. -/
def commentLineText (payload : String) : String :=
  let text := (payload.drop 2).toString
  if text.startsWith " " then (text.drop 1).toString else text

/-- The words one line of prose carries, runs of spaces and tabs collapsed. -/
def commentWords (text : String) : Array String :=
  ((text.map fun c => if c == '\t' then ' ' else c).splitOn " ").filter
      (fun s => !s.isEmpty) |>.toArray

/-- A standalone `--` comment block whose prose paragraphs the renderer may repack against the
column the block lands on. Zero-width to fit like `comment` — no group decision is driven by a
comment's bytes, packed or not — and the first payload is disclosed for the pinned hold-flat.
Well-formed when every line is a single-line `--` payload. -/
def fillWords (lines : Array FillLine) : Doc :=
  let measure : LineMeasure := ⟨0, false, false, lines[0]?.map (·.payload), false⟩
  .mk (.fillWords lines) measure measure 1
    (!lines.isEmpty &&
      lines.all fun line => !spansLines line.payload && line.payload.startsWith "--")

/-- A break opportunity with its exact flat spelling. A newline in the flat spelling is rejected.
The native `Std.Format.line` is `line " "`. -/
def line (flat : String) : Doc :=
  .mk (.line flat) (literalMeasure flat) ⟨0, true, false, none, false⟩ 1 (!spansLines flat)

/-- An unconditional newline at the current indentation. Annotation-tier: the enclosing group
stays broken (native re-grouping belongs to `nativeText`, which is what native `text` lowers to). -/
def hard : Doc :=
  .mk .hard ⟨0, true, true, none, false⟩ ⟨0, true, false, none, false⟩ 1 true

/-- One empty line followed by the current indentation. Unlike two adjacent `hard` nodes, this does
not materialize indentation whitespace on the empty line. -/
def blank : Doc :=
  .mk .blank ⟨0, true, true, none, false⟩ ⟨0, true, false, none, false⟩ 1 true

/-- Literal text that may span lines. Interior lines are never re-indented. -/
def verbatim (value : String) : Doc :=
  .mk (.verbatim value) (literalMeasure value) (literalBrokenMeasure value) 1 true

/-- Concatenate two documents. -/
def cat (left right : Doc) : Doc :=
  .mk (.cat left right) (left.flatMeasure.append right.flatMeasure)
    (left.brokenMeasure.append right.brokenMeasure) (1 + left.size + right.size)
    (left.wellFormed && right.wellFormed)

/-- Increase indentation after a break inside `body`. Signed, matching the native machine: a
negative nest subtracts, and emission clamps the running indent with `Int.toNat`. -/
def nest (indent : Int) (body : Doc) : Doc :=
  .mk (.nest indent body) body.flatMeasure body.brokenMeasure (1 + body.size) body.wellFormed

/-- Keep `body` flat when its current line fits, otherwise enable its breaks. The native
allOrNone group: one decision against the body and the enclosing remainder. -/
def group (body : Doc) : Doc :=
  .mk (.group body) body.flatMeasure body.flatMeasure (1 + body.size) body.wellFormed

/-- The native fill group: the body starts flat when the segment up to its first break fits, and
each break re-decides the remainder with one column charged for the candidate space. As an
unexpanded item in another group's measure it is flat like every native group; the broken
measure of a fill candidate comes from its items, not this node. -/
def fill (body : Doc) : Doc :=
  .mk (.fill body) body.flatMeasure body.flatMeasure (1 + body.size) body.wellFormed

/-- The native `align`: pad to the current indent, or break to it when already at or past it.
`force = false` renders as nothing inside a flattened group. Its measure depends on the decision
column, so it is the one contextual leaf. -/
def align (force : Bool) : Doc :=
  .mk (.align force) ⟨0, false, false, none, true⟩ ⟨0, false, false, none, true⟩ 1 true

/-- A native tag: invisible to fit, invisible in the default output, recorded as tag events for a
tag-aware consumer. -/
def tag (tag : Nat) (body : Doc) : Doc :=
  .mk (.tag tag body) body.flatMeasure body.brokenMeasure (1 + body.size) body.wellFormed

/-- An anchor body whose first emission is a break captured nothing: the development error the
contract names. The left spine decides; `empty` is transparent to it. -/
private partial def beginsWithBreak (document : Doc) : Bool :=
  match document.kind with
  | .line _ | .hard | .blank => true
  | .nativeText value => value.startsWith "\n"
  | .cat left right => beginsWithBreak left || (isEmptyDoc left && beginsWithBreak right)
  | .nest _ body | .group body | .fill body | .tag _ body | .anchor body | .mark _ body =>
    beginsWithBreak body
  | _ => false
where isEmptyDoc (document : Doc) : Bool :=
    match document.kind with
    | .empty => true
    | .cat left right => isEmptyDoc left && isEmptyDoc right
    | .nest _ body | .tag _ body | .mark _ body => isEmptyDoc body
    | _ => false

/-- Capture the column at which `body` begins and render `body` with its base indent re-set to
that column: breaks inside `body` land where the row started. Backward-only (the column is always
already emitted), invisible to fit, innermost-wins. A body whose first emission is a break is a
development error. -/
def anchor (body : Doc) : Doc :=
  let flag := !beginsWithBreak body && body.wellFormed
  .mk (.anchor body) body.flatMeasure body.brokenMeasure (1 + body.size) flag

/-- Associate the complete rendering of `body` with a normalized-source byte range. -/
def mark (source : SourceRange) (body : Doc) : Doc :=
  .mk (.mark source body) body.flatMeasure body.brokenMeasure (1 + body.size)
    (source.start <= source.stop && body.wellFormed)

/-- Embed one formatter-registry result without converting its native tree. The leaf is interpreted
at render time through the vendored machine and forms a fit boundary for surrounding custom
groups. -/
def registered (format : Std.Format) : Doc :=
  .mk (.registered format) ⟨0, true, true, none, true⟩ ⟨0, true, false, none, true⟩ 1 true

end Doc

instance : Append Doc where append := Doc.cat

instance : Inhabited Doc where default := Doc.empty

/-- One source-map entry. Both ranges use UTF-8 byte offsets. -/
structure Mark where
  source : SourceRange
  output : SourceRange
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- Deterministic renderer work counters. Native events count incremental outputs, newlines, and tag
events observed while interpreting opaque `Std.Format` leaves and native `tag` nodes. -/
structure RenderMetrics where
  documentNodes : Nat
  workSteps : Nat
  nativeEvents : Nat
  deriving Inhabited, BEq, Repr

/-- Complete result of one render. -/
structure Rendered where
  text : String
  sourceMap : Array Mark
  metrics : RenderMetrics
  deriving Inhabited, BEq, Repr

private inductive Mode where
  | flat
  | broken

/-- One work entry: a document with its current indent and open-tag count, or a source-map close
sentinel. -/
private inductive WorkEntry where
  | document (doc : Doc) (indent : Int) (activeTags : Nat)
  | closeMark (source : SourceRange) (outputStart : Nat)

private def WorkEntry.measure : Mode → WorkEntry → LineMeasure
  | _, .closeMark .. => .empty
  | .flat, .document doc .. => doc.flatMeasure
  | .broken, .document doc .. => doc.brokenMeasure

/-- A list of work entries caching both cumulative mode measures at every node. Regrouping a fill
or re-grouping after a hard line wraps the *same* entries in a new group without re-measuring
them; the group's decision reads the column its mode names. -/
private inductive Items where
  | nil
  | cons (entry : WorkEntry) (flat broken : LineMeasure) (rest : Items)

namespace Items

private def cumulative : Mode → Items → LineMeasure
  | _, .nil => .empty
  | .flat, .cons _ value _ _ => value
  | .broken, .cons _ _ value _ => value

private def push (entry : WorkEntry) (rest : Items) : Items :=
  let flat := (WorkEntry.measure .flat entry).append (cumulative .flat rest)
  let broken := (WorkEntry.measure .broken entry).append (cumulative .broken rest)
  .cons entry flat broken rest

private def ofList (entries : List WorkEntry) : Items :=
  entries.foldr push .nil

end Items

/-- Whether a group's entries may flatten: the vendored machine's `FlattenAllowability`.
`disallow` is the root group, which never flattens and never re-groups. -/
private inductive FlattenAllowability where
  | allow (fits : Bool)
  | disallow

private def FlattenAllowability.shouldFlatten : FlattenAllowability → Bool
  | .allow true => true
  | _ => false

/-- One work group: a flatten decision, a flatten behavior (`fill` or allOrNone), and its
remaining entries. -/
private structure WorkGroup where
  fla : FlattenAllowability
  fill : Bool
  items : Items

/-- The mode a group's entries are measured in for the cumulative caches: its current decision. -/
private def WorkGroup.mode (group : WorkGroup) : Mode :=
  if group.fla.shouldFlatten then .flat else .broken

private def WorkGroup.contribution (group : WorkGroup) : LineMeasure :=
  group.items.cumulative group.mode

/-- The work list: groups whose every node caches the cumulative suffix measure in the group's
own decision mode, rebuilt in constant time as entries are consumed. -/
private inductive Work where
  | empty
  | more (group : WorkGroup) (measure : LineMeasure) (rest : Work)

namespace Work

def measure : Work → LineMeasure
  | .empty => .empty
  | .more _ value _ => value

/-- Re-pack a group with its entries and the running suffix: constant time because both measures
are cached. -/
private def pack (group : WorkGroup) (rest : Work) : Work :=
  .more group (group.contribution.append rest.measure) rest

end Work

private structure RenderState where
  output : String := ""
  column : Nat := 0
  outputBytes : Nat := 0
  marks : Array Mark := #[]
  workSteps : Nat := 0
  nativeEvents : Nat := 0

private def appendLiteral (state : RenderState) (value : String) : RenderState :=
  let column :=
    if Doc.spansLines value then Doc.width (Doc.lastLine value) else state.column + Doc.width value
  { state with
    output := state.output ++ value
    column
    outputBytes := state.outputBytes + value.utf8ByteSize }

private def appendNewline (state : RenderState) (indent : Nat) : RenderState :=
  let value := "\n".pushn ' ' indent
  { state with
    output := state.output ++ value
    column := indent
    outputBytes := state.outputBytes + value.utf8ByteSize }

private instance : Std.Format.MonadPrettyFormat (StateM RenderState)
    where
  pushOutput value :=
    modify fun state => { appendLiteral state value with nativeEvents := state.nativeEvents + 1 }
  pushNewline indent :=
    modify fun state => { appendNewline state indent with nativeEvents := state.nativeEvents + 1 }
  currColumn := return (← get).column
  startTag _ := modify fun state => { state with nativeEvents := state.nativeEvents + 1 }
  endTags count := modify fun state => { state with nativeEvents := state.nativeEvents + count }

/-- The vendored machine's `spaceUptoLine` over one document, for the suffixes the cache cannot
answer: an `align` charges the pad it would need against the row it would start on, and stops the
walk where it would break. `m` is the machine's align allowance; `flatten` the measuring mode. -/
private partial def measureContextual : Doc → Bool → Int → Nat → NativeFormat.SpaceResult
  | doc, flatten, m, w =>
    match doc.kind with
    | .empty => { }
    | .comment _ => { }
    | .fillWords .. => { }
    | .hard | .blank => { foundLine := true }
    | .registered _ => { foundLine := true }
    | .line _ => if flatten then { space := 1 } else { foundLine := true }
    | .align force =>
      if flatten && !force then { }
      else if w < m then { space := (m - w).toNat } else { foundLine := true }
    | .text value | .nativeText value | .verbatim value =>
      let first := Doc.firstLine value
      { foundLine := Doc.spansLines value,
        foundFlattenedHardLine := flatten && Doc.spansLines value, space := Doc.width first }
    | .cat left right =>
      NativeFormat.merge w (measureContextual left flatten m w) (measureContextual right flatten m)
    | .nest n body => measureContextual body flatten (m - n) w
    | .group body => measureContextual body true m w
    | .fill body => measureContextual body true m w
    | .tag _ body => measureContextual body flatten m w
    | .anchor body => measureContextual body flatten m w
    | .mark _ body => measureContextual body flatten m w

/-- The vendored machine's `spaceUptoLine'` over the work list, for a contextual suffix. Per
entry the allowance is the machine's `w + col - indent`; the walk stops at the first hard stop. -/
private partial def measureEntries (decisionColumn : Nat) (w : Nat) (flatten : Bool) :
    Items → NativeFormat.SpaceResult
  | .nil => { }
  | .cons entry _ _ rest =>
    match entry with
    | .closeMark .. => measureEntries decisionColumn w flatten rest
    | .document doc indent _ =>
      let itemResult : NativeFormat.SpaceResult :=
        if !doc.flatMeasure.contextual then
          let measure := if flatten then doc.flatMeasure else doc.brokenMeasure
          { foundLine := measure.boundary, foundFlattenedHardLine := measure.flattenedHard,
            space := measure.width }
        else measureContextual doc flatten (w + decisionColumn - indent) w
      NativeFormat.merge w itemResult fun w' => measureEntries decisionColumn w' flatten rest

private partial def measureWork (decisionColumn : Nat) (w : Nat) : Work → NativeFormat.SpaceResult
  | .empty => { }
  | .more group _ rest =>
    NativeFormat.merge w (measureEntries decisionColumn w group.fla.shouldFlatten group.items)
      fun w' => measureWork decisionColumn w' rest

/-- Push a group for decision: the vendored machine's `pushGroup`. The candidate measures its
entries flat for allOrNone and broken (up to the first break) for fill, merged with the whole
enclosing remainder. A flattened hard line anywhere in the candidate denies the fit, for both
behaviors: an allOrNone candidate is measured flat, so any interior hard line is flattened; a
fill candidate is measured broken, but an unexpanded `group`/`fill` item inside it is measured
flat — a hard line in *its* interior is flattened too, and denies the fill's flatten just the
same (`Mathlib/Logic/Equiv/Fin/Rotate.lean`'s `haveI := …;` sequence is the measured case). A
pinned comment holds the row flat regardless. Returns the work list with the decided group on
top. -/
private def pushGroup (fill : Bool) (items : Items) (rest : Work) (width : Nat) (pinned : Bool) :
    StateM RenderState Work := do
  let column := (← get).column
  let candidateMode : Mode := if fill then .broken else .flat
  let candidateMeasure := items.cumulative candidateMode
  let cumulative := candidateMeasure.append rest.measure
  let fits :=
    if !cumulative.contextual then
      !candidateMeasure.flattenedHard && cumulative.width ≤ width - column
    else
      let available := width - column
      let r := measureEntries column available (!fill) items
      let r' := NativeFormat.merge available r fun w' => measureWork column w' rest
      !r.foundFlattenedHardLine && r'.space ≤ available
  let group : WorkGroup := { fla := .allow (fits || pinned), fill, items }
  return Work.pack group rest

/-- Below this much room for prose, repacking makes a comment less readable than the overflow it
fixes, so the block keeps its bytes. -/
private def minFillBudget : Nat :=
  20

/-- Pack words greedily into lines of at most `budget` columns of prose, each spelled `-- …`. A
word longer than the budget stands on its own line, unbroken -- a URL is not hyphenated. -/
private def packWords (budget : Nat) (words : Array String) : Array String :=
  let (lines, cur) :=
    words.foldl (init := ((#[], "") : Array String × String)) fun (lines, cur) word =>
      if cur.isEmpty then if word.length <= budget then (lines, word) else (lines.push word, "")
      else
        if cur.length + 1 + word.length <= budget then (lines, cur ++ " " ++ word)
        else
          if word.length <= budget then (lines.push cur, word) else ((lines.push cur).push word, "")
  let lines := if cur.isEmpty then lines else lines.push cur
  lines.map ("-- " ++ ·)

/-- The payload lines one `fillWords` block renders at `column`: the source bytes when reflow is
off, the margin left of the column is below `minFillBudget`, or any line is pinned; otherwise
each paragraph of unpinned `prose` lines packs greedily, a paragraph that already fits keeps its
bytes, and `keep` lines split paragraphs and stand verbatim. The pack is word-preserving by
construction and is checked: a mismatch falls back to the source lines, which is what the block
would have spelled anyway. -/
private def renderFillLines (width : Nat) (pinnedPhrases : Array String) (reflow : Bool)
    (column : Nat) (lines : Array FillLine) : Array String :=
  let verbatim := lines.map (·.payload)
  if !reflow then verbatim
  else
    let budget := width - column
    if budget < minFillBudget then verbatim
    else
      let flush (out paragraph : Array String) : Array String :=
        if paragraph.isEmpty then out
        else
          if paragraph.all (·.length <= budget) then out ++ paragraph
          else
            let words :=
              paragraph.foldl (init := #[]) fun collected line =>
                collected ++ Doc.commentWords (Doc.commentLineText line)
            let packed := packWords (budget - 3) words
            let repacked :=
              packed.foldl (init := #[]) fun collected line =>
                collected ++ Doc.commentWords (Doc.commentLineText line)
            if repacked == words then out ++ packed else out ++ paragraph
      let (out, paragraph) :=
        lines.foldl (init := ((#[], #[]) : Array String × Array String))
          fun (out, paragraph) line =>
          match line with
          | .prose payload =>
            if pinnedPhrases.any (payload.contains ·) then
              (flush out paragraph |>.push payload, #[])
            else (out, paragraph.push payload)
          | .keep payload => (flush out paragraph |>.push payload, #[])
      flush out paragraph

private partial def renderWork (width : Nat) (pinnedPhrases : Array String)
    (reflowComments : Bool) : Work → StateM RenderState Unit
  | .empty => pure ()
  | .more group _ rest =>
    match group.items with
    | .nil => renderWork width pinnedPhrases reflowComments rest
    | .cons entry _ _ items =>
      let resume (is' : Items) : StateM RenderState Unit :=
        renderWork width pinnedPhrases reflowComments (Work.pack { group with items := is' } rest)
      let resumeWork (work : Work) : StateM RenderState Unit :=
        renderWork width pinnedPhrases reflowComments work
      match entry with
      | .closeMark source outputStart => do
        modify fun state =>
            { state with
              workSteps := state.workSteps + 1,
              marks := state.marks.push { source, output := ⟨outputStart, state.outputBytes⟩ } }
        resume items
      | .document doc indent activeTags => do
        modify fun state => { state with workSteps := state.workSteps + 1 }
        let endTags : StateM RenderState Unit :=
          modify fun state => { state with nativeEvents := state.nativeEvents + activeTags }
        match doc.kind with
        | .empty =>
          endTags
          resume items
        | .text value | .comment value | .verbatim value =>
          modify (appendLiteral · value)
          endTags
          resume items
        | .fillWords fillLines =>
          do
            -- The block's continuation rows land where its first row began: the entry column is
            -- the block's own, whatever nest carried the row there.
            let column := (← get).column
            let emitted := renderFillLines width pinnedPhrases reflowComments column fillLines
            let mut first := true
            for value in emitted do
              if first then
                first := false
              else
                modify (appendNewline · column)
              modify (appendLiteral · value)
            endTags
            resume items
        | .nativeText value =>
          match value.splitOn "\n" with
          | [_] =>
            modify (appendLiteral · value)
            endTags
            resume items
          | head :: tailParts =>
            -- Native multiline text: emit up to the first newline, break to the entry's indent,
            -- and re-queue the remainder as this group's next item — the tail is part of the
            -- re-grouping's fit candidate, which is why the queue cannot be skipped. The root
            -- group (`disallow`) never re-groups. Tags close when the tail completes, as in the
            -- machine.
            let tail := "\n".intercalate tailParts
            modify (appendLiteral · head)
            modify fun state => { appendNewline state indent.toNat with }
            let items' := items.push (.document (.nativeText tail) indent activeTags)
            match group.fla with
            | .disallow =>
              resume items'
            | _ =>
              resumeWork (← pushGroup group.fill items' rest width false)
          | [] =>
            endTags
            resume items
        | .cat left right =>
          resume (items.push (.document right indent activeTags) |>.push (.document left indent 0))
        | .nest extra body =>
          resume (items.push (.document body (indent + extra) activeTags))
        | .mark source body =>
          let outputStart := (← get).outputBytes
          resume
              (items.push (.closeMark source outputStart) |>.push
                (.document body indent activeTags))
        | .tag _ body =>
          modify fun state => { state with nativeEvents := state.nativeEvents + 1 }
          resume (items.push (.document body indent (activeTags + 1)))
        | .anchor body =>
          -- Backward-only capture: the entry column is the column of the next emitted byte. The
          -- body's base indent is re-set to it; measurement never sees the change.
          if Doc.beginsWithBreak body then
            panic! "anchor body begins with a break: the entry column captured nothing"
          else
            let column := (← get).column
            resume (items.push (.document body column activeTags))
        | .hard =>
          modify (appendNewline · indent.toNat)
          endTags
          resume items
        | .blank =>
          modify fun state =>
              let value := "\n\n".pushn ' ' indent.toNat
              { state with
                output := state.output ++ value
                column := indent.toNat
                outputBytes := state.outputBytes + value.utf8ByteSize }
          endTags
          resume items
        | .line flat =>
          if !group.fill then
            if group.fla.shouldFlatten then
              modify (appendLiteral · flat)
            else
              modify (appendNewline · indent.toNat)
            endTags
            resume items
          else
            -- Native fill: one column is charged for the candidate space; the remainder re-groups
            -- either way.
            if group.fla.shouldFlatten then
              -- The lookahead charges one column for the space it would emit.
              let candidate ← pushGroup true items rest (width - 1) false
              let flattenNext :=
                match candidate with
                | .empty => false
                | .more group' _ _ => group'.fla.shouldFlatten
              if flattenNext then
                modify (appendLiteral · flat)
                endTags
                resumeWork candidate
              else
                modify (appendNewline · indent.toNat)
                endTags
                resumeWork (← pushGroup true items rest width false)
            else
              modify (appendNewline · indent.toNat)
              endTags
              resumeWork (← pushGroup true items rest width false)
        | .align force =>
          if group.fla.shouldFlatten && !force then
            endTags
            resume items
          else
            let column := (← get).column
            if column < indent then
              modify (appendLiteral · ("".pushn ' ' (indent - column).toNat))
            else
              modify (appendNewline · indent.toNat)
            endTags
            resume items
        | .group body =>
          if group.fla.shouldFlatten then
            resume (items.push (.document body indent activeTags))
          else
            let pinned :=
              (items.cumulative .flat).comment?.any fun comment =>
                pinnedPhrases.any fun phrase => comment.contains phrase
            let pushed ←
              pushGroup false (Items.ofList [.document body indent activeTags])
                  (Work.pack { group with items } rest) width pinned
            resumeWork pushed
        | .fill body =>
          if group.fla.shouldFlatten then
            resume (items.push (.document body indent activeTags))
          else
            let pushed ←
              pushGroup true (Items.ofList [.document body indent activeTags])
                  (Work.pack { group with items } rest) width false
            resumeWork pushed
        | .registered format =>
          NativeFormat.renderM format width indent.toNat
          endTags
          resume items

/-- Render a document at `width`, returning text, byte source maps, and deterministic work counts.
`pinnedPhrases` are the `pinned-comments` configuration: a comment containing one holds its line
flat, and a fill-words block carrying one keeps its bytes. `reflowComments` is the
`reflow-comments` configuration: a fill-words block's prose paragraphs repack against the column
the block lands on. `indent` and `column` are the native machine's entry state: the wrap indent
for later rows and the column the first row's fit measurement starts at. -/
def renderDetailed (width : Nat) (document : Doc) (pinnedPhrases : Array String := #[])
    (reflowComments : Bool := false) (indent : Nat := 0) (column : Nat := 0) : Rendered :=
  let root : WorkGroup :=
    { fla := .disallow, fill := false, items := Items.ofList [.document document indent 0] }
  let initial := Work.pack root .empty
  let state := (renderWork width pinnedPhrases reflowComments initial).run { column } |>.2
  { text := state.output
    sourceMap := state.marks
    metrics :=
      { documentNodes := document.size
        workSteps := state.workSteps
        nativeEvents := state.nativeEvents } }

/-- Render text and byte source maps. -/
def render (width : Nat) (document : Doc) (pinnedPhrases : Array String := #[])
    (reflowComments : Bool := false) : String × Array Mark :=
  let rendered := renderDetailed width document pinnedPhrases reflowComments
  (rendered.text, rendered.sourceMap)

/-- Render only text. -/
def renderText (width : Nat) (document : Doc) (pinnedPhrases : Array String := #[])
    (reflowComments : Bool := false) : String :=
  (renderDetailed width document pinnedPhrases reflowComments).text

end LeanFmt.Internal
