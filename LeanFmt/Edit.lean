/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.ArtifactModel

namespace LeanFmt.Internal

/-- Why a complete patch could not be constructed. The constructor rejects the whole edit set on the
first error; callers never get partially assembled output. -/
inductive PatchError where
  | invalidRange (index : Nat) (range : SourceRange) (sourceBytes : Nat)
  | invalidBoundary (index position : Nat)
  /-- Two fixes cannot both apply to one snapshot. The provenance is the two **rule codes** and the
  two **finding ranges** — never internal edit indices, which name nothing a user can act on. A
  conflict rejects the whole file; no edit is dropped and no fix wins. -/
  | conflict (leftCode rightCode : String) (left right : SourceRange)
  | invalidOutputEncoding
  deriving BEq, Repr

instance : ToString PatchError where
  toString
    | .invalidRange index range sourceBytes =>
      s!"edit {index} has invalid byte range {range.start}-{range.stop} for {sourceBytes}-byte source"
    | .invalidBoundary index position =>
      s!"edit {index} position {position} is not a UTF-8 boundary"
    | .conflict leftCode rightCode left right =>
      s!"fixes from {leftCode} ({left.start}-{left.stop}) and {rightCode} \
        ({right.start}-{right.stop}) conflict"
    | .invalidOutputEncoding => "checked edits unexpectedly produced invalid UTF-8"

/-- An edit paired with the finding it came from, so a conflict rejection names the rule and its
finding range, not an anonymous array index. The inverse-patch path, which has no finding, uses an
empty code and the edit's own range. -/
private structure ProvenancedEdit where
  code : String
  findingRange : SourceRange
  edit : Edit

private structure IndexedEdit where
  index : Nat
  code : String
  findingRange : SourceRange
  edit : Edit

/-- An all-or-nothing transformation of one immutable source snapshot. Construction owns range,
UTF-8, ordering, conflict, assembly, and inverse-edit checks. -/
structure Patch where
  private mk ::
  source : Digest
  output : String
  edits : Array Edit
  inverse : Array Edit

def Patch.formatted (patch : Patch) : String := patch.output

def Patch.editCount (patch : Patch) : Nat := patch.edits.size

def Patch.changed (patch : Patch) : Bool := !patch.edits.isEmpty

def Patch.matchesSource (patch : Patch) (source : String) : Bool :=
  patch.source == Digest.ofString source

private def editLess (left right : IndexedEdit) : Bool :=
  if left.edit.range.start != right.edit.range.start then
    left.edit.range.start < right.edit.range.start
  else if left.edit.range.stop != right.edit.range.stop then
    left.edit.range.stop < right.edit.range.stop
  else
    left.index < right.index

private def boundaryValid (source : String) (position : Nat) : Bool :=
  String.Pos.Raw.isValid source ⟨position⟩

private def validateEdits (source : String) (edits : Array Edit) : Except PatchError Unit := do
  let sourceBytes := source.utf8ByteSize
  for edit in edits, index in [0:edits.size] do
    unless edit.range.start <= edit.range.stop && edit.range.stop <= sourceBytes do
      throw <| .invalidRange index edit.range sourceBytes
    unless boundaryValid source edit.range.start do
      throw <| .invalidBoundary index edit.range.start
    unless boundaryValid source edit.range.stop do
      throw <| .invalidBoundary index edit.range.stop

private def sortedEdits (edits : Array ProvenancedEdit) : Array IndexedEdit :=
  (edits.mapIdx fun index item =>
    { index, code := item.code, findingRange := item.findingRange, edit := item.edit }).qsort editLess

private def conflict? (left right : IndexedEdit) : Bool :=
  right.edit.range.start < left.edit.range.stop ||
    (left.edit.range.start == left.edit.range.stop &&
      right.edit.range.start == right.edit.range.stop &&
      left.edit.range.start == right.edit.range.start)

private def validateConflicts (edits : Array IndexedEdit) : Except PatchError Unit := do
  for left in edits, right in edits.drop 1 do
    if conflict? left right then
      throw <| .conflict left.code right.code left.findingRange right.findingRange

private def decode (bytes : ByteArray) : Except PatchError String :=
  match String.fromUTF8? bytes with
  | some value => .ok value
  | none => .error .invalidOutputEncoding

private def assemble (source : String)
    (ordered : Array IndexedEdit) : Except PatchError (String × Array Edit) := do
  let sourceBytes := source.toUTF8
  let mut cursor := 0
  let mut output := ByteArray.empty
  let mut inverse := #[]
  for item in ordered do
    let edit := item.edit
    output := output ++ sourceBytes.extract cursor edit.range.start
    let outputStart := output.size
    let replacement := edit.replacement.toUTF8
    output := output ++ replacement
    let original ← decode (sourceBytes.extract edit.range.start edit.range.stop)
    inverse := inverse.push {
      range := { start := outputStart, stop := outputStart + replacement.size }
      replacement := original
    }
    cursor := edit.range.stop
  output := output ++ sourceBytes.extract cursor sourceBytes.size
  return (← decode output, inverse)

/-- Construct one complete patch from selected fixes. Findings without a fix are ignored, as are fixes
the caller withheld by applicability (`Application.prepareFile` strips a non-admitted fix to `none`
before reaching here — admission is policy and does not belong in the assembler). Every remaining
fix's edits share one validation and conflict transaction, tagged with their rule so a conflict names
it. -/
def preparePatch (source : String) (findings : Array Finding) : Except PatchError Patch := do
  let provenanced := findings.flatMap fun finding =>
    match finding.fix? with
    | some fix => fix.edits.map fun edit =>
        ({ code := finding.code, findingRange := finding.range, edit } : ProvenancedEdit)
    | none => #[]
  validateEdits source (provenanced.map (·.edit))
  let ordered := sortedEdits provenanced
  validateConflicts ordered
  let (output, inverse) ← assemble source ordered
  return {
    source := Digest.ofString source
    output
    edits := ordered.map (·.edit)
    inverse
  }

/-- Reconstruct the exact input snapshot from a checked patch. Primarily a characterization and test
capability; publication never relies on a lossy formatter being invertible. -/
def Patch.revert (patch : Patch) : Except PatchError String := do
  validateEdits patch.output patch.inverse
  let provenanced := patch.inverse.map fun edit =>
    ({ code := "", findingRange := edit.range, edit } : ProvenancedEdit)
  let ordered := sortedEdits provenanced
  validateConflicts ordered
  return (← assemble patch.output ordered).1

end LeanFmt.Internal
