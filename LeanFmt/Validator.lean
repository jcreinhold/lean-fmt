/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Pure admission checks for a whole-module formatting draft.

The comparator consumes lossless projections produced by two independent frontend runs. Locations
and whitespace lengths may change; node kind/parent order, token ownership and spelling, header
structure/token spelling, comment payload/logical ownership, and terminal tail may not. Keeping this
module pure makes the comparison independently testable and prevents it from acquiring frontend
authority. -/

import all LeanFmt.Formatter

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
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- A layout admitted after a fresh candidate frontend and byte-identical second formatting pass. -/
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
  for index in [0:draft.sourceMap.size] do
    let mark := draft.sourceMap[index]!
    unless mark.source.start == sourceCursor && mark.output.start == outputCursor do
      return ← fail .sourceMap s!"map unit {index} overlaps or leaves a gap"
    unless mark.source.start <= mark.source.stop && mark.output.start <= mark.output.stop do
      return ← fail .sourceMap s!"map unit {index} has an inverted range"
    sourceCursor := mark.source.stop
    outputCursor := mark.output.stop
  unless sourceCursor == draft.sourceBytes do
    return ← fail .sourceMap s!"source map stops at {sourceCursor}, expected {draft.sourceBytes}"
  unless outputCursor == draft.text.utf8ByteSize do
    return ← fail .sourceMap
      s!"output map stops at {outputCursor}, expected {draft.text.utf8ByteSize}"

/-- Compare the enumerated normalized structure. The first mismatch identifies its node/token path. -/
def compare (beforeText : String) (before : LosslessSource)
    (afterText : String) (after : LosslessSource) : Except ValidationFailure Unit := do
  let beforeBytes := beforeText.toUTF8
  let afterBytes := afterText.toUTF8
  unless slice beforeBytes before.terminalStop beforeBytes.size ==
      slice afterBytes after.terminalStop afterBytes.size do
    return ← fail .terminal "terminal command or verbatim tail changed"
  unless before.nodes.size == after.nodes.size do
    return ← fail .structure s!"node count changed: {before.nodes.size} -> {after.nodes.size}"
  for index in [0:before.nodes.size] do
    let left := before.nodes[index]!
    let right := after.nodes[index]!
    let leftKind := kindOfNode before index
    let rightKind := kindOfNode after index
    unless leftKind == rightKind && left.parent == right.parent do
      return ← fail .structure
        s!"node {index} changed kind/parent: {leftKind}/{left.parent} -> {rightKind}/{right.parent}"
  unless before.tokens.size == after.tokens.size do
    return ← fail .tokens s!"token count changed: {before.tokens.size} -> {after.tokens.size}"
  for index in [0:before.tokens.size] do
    let left := before.tokens[index]!
    let right := after.tokens[index]!
    unless left.node == right.node do
      return ← fail .structure
        s!"token {index} changed owner {left.node} -> {right.node}"
    let leftText := slice beforeBytes left.start left.stop
    let rightText := slice afterBytes right.start right.stop
    unless leftText == rightText do
      return ← fail .tokens
        s!"token {index} ({kindOfNode before left.node}) changed spelling"

/-- Admit the first draft using a freshly parsed/formatted second draft. -/
def admit (beforeText : String) (before : LosslessSource) (first : FormatDraft)
    (after : LosslessSource) (second : FormatDraft) : Except ValidationFailure CanonicalLayout := do
  validateMap first
  validateMap second
  compare beforeText before first.text after
  unless first.headerContract == second.headerContract do
    return ← fail .header "module/header/import structure or token spelling changed"
  unless first.commentContract == second.commentContract do
    return ← fail .comments "comment kind, payload, order, or logical owner path changed"
  unless second.text == first.text do
    return ← fail .idempotence "formatting the reparsed candidate changed bytes"
  return {
    text := first.text
    sourceMap := first.sourceMap
    metrics := { first.metrics with frontendRuns := 2 }
    validation := {
      frontendRuns := 2
      renders := 2
      structuralComparisons := 1
      idempotencePasses := 1 } }

end Validator

end LeanFmt.Internal
