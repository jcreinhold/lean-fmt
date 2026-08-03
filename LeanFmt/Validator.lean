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

structure ValidationFailure where
  gate : ValidationGate
  detail : String
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

structure ValidationMetrics where
  frontendRuns : Nat
  renders : Nat
  structuralComparisons : Nat
  idempotencePasses : Nat
  /-- Commands the candidate's parse confirmed against the original's, one by one. Zero when a
  second frontend elaborated the candidate instead. -/
  reparsedCommands : Nat := 0
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

private def fail (gate : ValidationGate) (detail : String) : Except ValidationFailure α :=
  .error { gate, detail }

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
  for index in [0:draft.sourceMap.size]do
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

/- Where two node enumerations first disagree, as a phrase to append to a count mismatch.

A count is the one structural failure that cannot name its own node -- every later index is shifted,
so the ordered walk below reports only the first divergence, which is the one that shifted them. It
is diagnostic only: the gate has already refused. -/
private def firstNodeDivergence (before : LosslessSource) (afterText : String)
    (after : LosslessSource) : String :=
  let shared := min before.nodes.size after.nodes.size
  match
    (List.range shared).find? fun index =>
      kindOfNode before index != kindOfNode after index ||
        before.nodes[index]!.parent != after.nodes[index]!.parent with
  | some index =>
    let candidate := after.nodes[index]!
    let location := position afterText candidate.range.start
    s!"; node {index} is {kindOfNode before index} before and \
      {kindOfNode after index} at {location} after"
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
      {firstNodeDivergence before afterText after}"
  for index in [0:before.nodes.size]do
    let left := before.nodes[index]!
    let right := after.nodes[index]!
    let leftKind := kindOfNode before index
    let rightKind := kindOfNode after index
    unless leftKind == rightKind && left.parent == right.parent do
      return ←
          fail .structure
              s!"node {index} changed kind/parent: {leftKind}/{left.parent} -> {rightKind}/{right.parent}"
  unless before.tokens.size == after.tokens.size do
    return ← fail .tokens s!"token count changed: {before.tokens.size} -> {after.tokens.size}"
  for index in [0:before.tokens.size]do
    let left := before.tokens[index]!
    let right := after.tokens[index]!
    unless left.node == right.node do
      return ← fail .structure s!"token {index} changed owner {left.node} -> {right.node}"
    let leftText := slice beforeBytes left.start left.stop
    let rightText := slice afterBytes right.start right.stop
    unless leftText == rightText do
      return ← fail .tokens s!"token {index} ({kindOfNode before left.node}) changed spelling"

/-- Admit the first draft using a freshly parsed/formatted second draft. -/
def admit (beforeText : String) (before : LosslessSource) (first : FormatDraft)
    (after : LosslessSource) (second : FormatDraft) (evidence : ValidationEvidence) :
    Except ValidationFailure CanonicalLayout := do
  validateMap first
  validateMap second
  compare beforeText before first.text after
  unless first.headerContract == second.headerContract do
    return ← fail .header "module/header/import structure or token spelling changed"
  unless first.commentContract == second.commentContract do
    if first.commentContract.size != second.commentContract.size then
      return ←
          fail .comments
              s!"comment contract count changed: \
        {first.commentContract.size} -> {second.commentContract.size}"
    for index in [0:first.commentContract.size]do
      let left := first.commentContract[index]!
      let right := second.commentContract[index]!
      unless left == right do
        return ← fail .comments s!"comment {index} changed: {repr left} -> {repr right}"
    return ← fail .comments "comment kind, payload, order, or logical owner path changed"
  unless second.text == first.text do
    return ← fail .idempotence "formatting the reparsed candidate changed bytes"
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
