/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- A width-independent formatting document and its bounded renderer.

The document has one flat/broken choice: `group`. A break carries its flat spelling, so separators
such as `"; "` can disappear when a construct opens. There is no generic alternative, alignment, or
best-fitting search.

The custom renderer is linear in document nodes plus emitted bytes. Each document caches the width
up to its first forced break in flat and broken modes. The work stack caches the same summary for its
suffix, so deciding a group is constant-time even for adversarial zero-width siblings. This avoids
the repeated suffix walk used by the former renderer. Opaque leaves use Lean's own bounded work-list
renderer and expose its output events separately from custom work counts.

Registered Lean formatter output remains opaque. `registered` stores one `Std.Format` and interprets
it incrementally at the active width and column through `Std.Format.prettyM`; it neither clones the
native tree nor renders it before width selection. A registered leaf is a fit boundary for enclosing
custom groups. Core rules therefore compose it as a leaf, rather than putting it inside a custom
group whose decision would require inspecting Lean's private layout tree.

Columns count codepoints, matching `Std.Format`; source and output ranges count UTF-8 bytes. -/

import all LeanFmt.LosslessSource

namespace LeanFmt.Internal

private structure LineMeasure where
  width : Nat
  boundary : Bool

namespace LineMeasure

def empty : LineMeasure := ⟨0, false⟩

def append (left right : LineMeasure) : LineMeasure :=
  if left.boundary then left else ⟨left.width + right.width, right.boundary⟩

end LineMeasure

mutual
  private inductive DocKind where
    | empty
    | text (value : String)
    | line (flat : String)
    | hard
    | verbatim (value : String)
    | cat (left right : Doc)
    | nest (indent : Nat) (body : Doc)
    | group (body : Doc)
    | mark (source : SourceRange) (body : Doc)
    | registered (format : Std.Format)

  /-- A formatting document. Construct values through the operations in `Doc`; its cached measures
  and well-formedness bit are intentionally not caller-settable. -/
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
def width (value : String) : Nat := value.length

private def spansLines (value : String) : Bool := value.contains '\n'

private def firstLine (value : String) : String :=
  match (value.splitOn "\n")[0]? with
  | some line => line
  | none => value

private def lastLine (value : String) : String :=
  match (value.splitOn "\n").getLast? with
  | some line => line
  | none => value

private def literalMeasure (value : String) : LineMeasure :=
  if spansLines value then ⟨width (firstLine value), true⟩ else ⟨width value, false⟩

/-- The empty document. -/
def empty : Doc := .mk .empty .empty .empty 1 true

/-- Literal single-line text. A newline makes the resulting document ill-formed. -/
def text (value : String) : Doc :=
  let measure := literalMeasure value
  .mk (.text value) measure measure 1 (!spansLines value)

/-- A break opportunity with its exact flat spelling. A newline in the flat spelling is rejected. -/
def line (flat : String) : Doc :=
  .mk (.line flat) (literalMeasure flat) ⟨0, true⟩ 1 (!spansLines flat)

/-- An unconditional newline at the current indentation. -/
def hard : Doc := .mk .hard ⟨0, true⟩ ⟨0, true⟩ 1 true

/-- Literal text that may span lines. Interior lines are never re-indented. -/
def verbatim (value : String) : Doc :=
  let measure := literalMeasure value
  .mk (.verbatim value) measure measure 1 true

/-- Concatenate two documents. -/
def cat (left right : Doc) : Doc :=
  .mk (.cat left right)
    (left.flatMeasure.append right.flatMeasure)
    (left.brokenMeasure.append right.brokenMeasure)
    (1 + left.size + right.size)
    (left.wellFormed && right.wellFormed)

/-- Increase indentation after a break inside `body`. -/
def nest (indent : Nat) (body : Doc) : Doc :=
  .mk (.nest indent body) body.flatMeasure body.brokenMeasure (1 + body.size) body.wellFormed

/-- Keep `body` flat when its current line fits, otherwise enable its breaks. -/
def group (body : Doc) : Doc :=
  .mk (.group body) body.flatMeasure body.flatMeasure (1 + body.size) body.wellFormed

/-- Associate the complete rendering of `body` with a normalized-source byte range. -/
def mark (source : SourceRange) (body : Doc) : Doc :=
  .mk (.mark source body) body.flatMeasure body.brokenMeasure (1 + body.size)
    (source.start <= source.stop && body.wellFormed)

/-- Embed one formatter-registry result without converting its native tree. The leaf is interpreted
at render time and forms a fit boundary for surrounding custom groups. -/
def registered (format : Std.Format) : Doc :=
  .mk (.registered format) ⟨0, true⟩ ⟨0, true⟩ 1 true

end Doc

instance : Append Doc where
  append := Doc.cat

instance : Inhabited Doc where
  default := Doc.empty

/-- One source-map entry. Both ranges use UTF-8 byte offsets. -/
structure Mark where
  source : SourceRange
  output : SourceRange
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- Deterministic renderer work counters. Native events count incremental outputs, newlines, and tag
events observed while interpreting opaque `Std.Format` leaves. -/
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

private inductive Command where
  | document (indent : Nat) (mode : Mode) (document : Doc)
  | closeMark (source : SourceRange) (outputStart : Nat)

private def Command.measure : Command → LineMeasure
  | .closeMark .. => .empty
  | .document _ mode doc =>
    match mode with
    | .flat => doc.flatMeasure
    | .broken => doc.brokenMeasure

private inductive Work where
  | empty
  | more (command : Command) (measure : LineMeasure) (rest : Work)

namespace Work

def measure : Work → LineMeasure
  | .empty => .empty
  | .more _ value _ => value

def push (command : Command) (rest : Work) : Work :=
  .more command (command.measure.append rest.measure) rest

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

private instance : Std.Format.MonadPrettyFormat (StateM RenderState) where
  pushOutput value := modify fun state =>
    { appendLiteral state value with nativeEvents := state.nativeEvents + 1 }
  pushNewline indent := modify fun state =>
    { appendNewline state indent with nativeEvents := state.nativeEvents + 1 }
  currColumn := return (← get).column
  startTag _ := modify fun state => { state with nativeEvents := state.nativeEvents + 1 }
  endTags count := modify fun state => { state with nativeEvents := state.nativeEvents + count }

private partial def renderWork (width : Nat) : Work → StateM RenderState Unit
  | .empty => pure ()
  | .more command _ rest => do
    modify fun state => { state with workSteps := state.workSteps + 1 }
    match command with
    | .closeMark source outputStart =>
      let state ← get
      set { state with marks := state.marks.push {
        source
        output := ⟨outputStart, state.outputBytes⟩ } }
      renderWork width rest
    | .document indent mode document =>
      match document.kind with
      | .empty => renderWork width rest
      | .text value =>
        modify (appendLiteral · value)
        renderWork width rest
      | .verbatim value =>
        modify (appendLiteral · value)
        renderWork width rest
      | .cat left right =>
        renderWork width <| rest.push (.document indent mode right)
          |>.push (.document indent mode left)
      | .nest extra body =>
        renderWork width <| rest.push (.document (indent + extra) mode body)
      | .mark source body =>
        let outputStart := (← get).outputBytes
        renderWork width <| rest.push (.closeMark source outputStart)
          |>.push (.document indent mode body)
      | .hard =>
        modify (appendNewline · indent)
        renderWork width rest
      | .line flat =>
        match mode with
        | .flat => modify (appendLiteral · flat)
        | .broken => modify (appendNewline · indent)
        renderWork width rest
      | .group body =>
        match mode with
        | .flat => renderWork width <| rest.push (.document indent .flat body)
        | .broken =>
          let candidate := rest.push (.document indent .flat body)
          let column := (← get).column
          let available := width - column
          let selected :=
            if column <= width && !body.flatMeasure.boundary && candidate.measure.width <= available then
              Mode.flat
            else
              Mode.broken
          renderWork width <| rest.push (.document indent selected body)
      | .registered format =>
        Std.Format.prettyM format width indent
        renderWork width rest

/-- Render a document at `width`, returning text, byte source maps, and deterministic work counts. -/
def renderDetailed (width : Nat) (document : Doc) : Rendered :=
  let initial := Work.empty.push (.document 0 .broken document)
  let state := (renderWork width initial).run {} |>.2
  {
    text := state.output
    sourceMap := state.marks
    metrics := {
      documentNodes := document.size
      workSteps := state.workSteps
      nativeEvents := state.nativeEvents } }

/-- Render text and byte source maps. -/
def render (width : Nat) (document : Doc) : String × Array Mark :=
  let rendered := renderDetailed width document
  (rendered.text, rendered.sourceMap)

/-- Render only text. -/
def renderText (width : Nat) (document : Doc) : String :=
  (renderDetailed width document).text

end LeanFmt.Internal
