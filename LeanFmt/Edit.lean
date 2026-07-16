module

import all LeanFmt.ArtifactModel

namespace LeanFmt.Internal

/-- Why a complete patch could not be constructed. The constructor rejects the whole edit set on
the first error; callers never receive partially assembled output. -/
inductive PatchError where
  | invalidRange (index : Nat) (range : SourceRange) (sourceBytes : Nat)
  | invalidBoundary (index position : Nat)
  | conflict (leftIndex rightIndex : Nat) (left right : SourceRange)
  | invalidOutputEncoding
  deriving BEq, Repr

instance : ToString PatchError where
  toString
    | .invalidRange index range sourceBytes =>
      s!"edit {index} has invalid byte range {range.start}-{range.stop} for {sourceBytes}-byte source"
    | .invalidBoundary index position =>
      s!"edit {index} position {position} is not a UTF-8 boundary"
    | .conflict leftIndex rightIndex left right =>
      s!"edits {leftIndex} ({left.start}-{left.stop}) and {rightIndex} \
        ({right.start}-{right.stop}) conflict"
    | .invalidOutputEncoding => "checked edits unexpectedly produced invalid UTF-8"

private structure IndexedEdit where
  index : Nat
  edit : Edit

/-- An all-or-nothing transformation of one immutable source snapshot. Construction owns range,
UTF-8, ordering, conflict, assembly, and inverse-edit checks. -/
structure Patch where
  private mk ::
  source : Digest
  output : String
  edits : Array Edit
  inverse : Array Edit

def Patch.sourceDigest (patch : Patch) : Digest := patch.source

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

private def sortedEdits (edits : Array Edit) : Array IndexedEdit :=
  (edits.mapIdx fun index edit => { index, edit }).qsort editLess

private def conflict? (left right : IndexedEdit) : Bool :=
  right.edit.range.start < left.edit.range.stop ||
    (left.edit.range.start == left.edit.range.stop &&
      right.edit.range.start == right.edit.range.stop &&
      left.edit.range.start == right.edit.range.start)

private def validateConflicts (edits : Array IndexedEdit) : Except PatchError Unit := do
  for left in edits, right in edits.drop 1 do
    if conflict? left right then
      throw <| .conflict left.index right.index left.edit.range right.edit.range

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

/-- Construct one complete patch from selected fix edits. Findings without fixes are deliberately
ignored; every selected fix participates in the same validation and conflict transaction. -/
def preparePatch (source : String) (findings : Array Finding) : Except PatchError Patch := do
  let edits := findings.filterMap (·.fix?)
  validateEdits source edits
  let ordered := sortedEdits edits
  validateConflicts ordered
  let (output, inverse) ← assemble source ordered
  return {
    source := Digest.ofString source
    output
    edits := ordered.map (·.edit)
    inverse
  }

/-- Reconstruct the exact input snapshot from a checked patch. This is primarily a characterization
and test capability; publication never relies on a lossy formatter being invertible by convention. -/
def Patch.revert (patch : Patch) : Except PatchError String := do
  validateEdits patch.output patch.inverse
  let ordered := sortedEdits patch.inverse
  validateConflicts ordered
  return (← assemble patch.output ordered).1

end LeanFmt.Internal
