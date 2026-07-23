/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Structural collection documents over actual delimiter, separator, and field nodes.

The caller owns recursive term dispatch. A closed collection therefore composes structural core
children and opaque project children without delegating its own root. Separators are recognized only
as atom children in the selected parser tree; no source columns or flattened token grammar are used.
Match/control layout is intentionally absent and belongs to `LeanFmt.Formatter.ControlTerm`. -/

import Lean.Parser.Term
import all LeanFmt.Formatter
import all LeanFmt.Formatter.Syntax
import all LeanFmt.Formatter.Trivia

namespace LeanFmt.Internal.Formatter.Collection

private structure Separated where
  values : Array Doc := #[]
  separators : Nat := 0
  trailing : Bool := false

private def isAtom (value : String) : Lean.Syntax → Bool
  | .atom _ spelling => spelling == value
  | _ => false

private partial def separated (ownership : CommentOwnership)
    (childDocument : Lean.Syntax → Lean.CoreM (Except FormatterFailure (Option Doc)))
    (stx : Lean.Syntax) (result : Separated := {}) : Lean.CoreM (Except FormatterFailure Separated) := do
  let mut result := result
  for child in stx.getArgs do
    if (Syntax.spellings child).isEmpty then continue
    if isAtom "," child then
      result := { result with separators := result.separators + 1, trailing := true }
    else if child.getKind == Lean.nullKind then
      match ← separated ownership childDocument child result with
      | .ok nested => result := nested
      | .error failure => return .error failure
    else
      match ← childDocument child with
      | .ok (some document) =>
        let document := match Trivia.leading ownership child with
          | some comments => comments ++ Doc.hard ++ document
          | none => document
        result := { result with values := result.values.push document, trailing := false }
      | .ok none => return .ok { result with separators := 0, values := #[] }
      | .error failure => return .error failure
  return .ok result

private def delimited (opening closing : String) (items : Separated) : Doc :=
  if items.values.isEmpty then Doc.text (opening ++ closing) else
  Id.run do
    let mut document := Doc.text opening ++ Doc.nest 2 (Doc.line "" ++ items.values[0]!)
    for index in [1:items.values.size] do
      document := document ++ Doc.text "," ++
        Doc.nest 2 (Doc.line " " ++ items.values[index]!)
    if items.trailing then document := document ++ Doc.text ","
    return Doc.group (document ++ Doc.line "" ++ Doc.text closing)

private def delimiterDocument (ownership : CommentOwnership)
    (childDocument : Lean.Syntax → Lean.CoreM (Except FormatterFailure (Option Doc)))
    (stx : Lean.Syntax) : Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let args := stx.getArgs
  if args.size < 2 then return .ok none
  let opening? := (Syntax.spellings args[0]!)[0]?
  let closingTokens := Syntax.spellings args[args.size - 1]!
  let closing? := closingTokens[closingTokens.size - 1]?
  let some opening := opening? | return .ok none
  let some closing := closing? | return .ok none
  let wrapper : Lean.Syntax := .node .none Lean.nullKind (args.extract 1 (args.size - 1))
  match ← separated ownership childDocument wrapper with
  | .error failure => return .error failure
  | .ok items =>
    if items.values.isEmpty && !(Syntax.spellings wrapper).isEmpty then return .ok none
    if !items.values.isEmpty && items.separators < items.values.size - 1 then return .ok none
    if items.separators > items.values.size then return .ok none
    return .ok (some (delimited opening closing items))

private partial def descendants (predicate : Lean.Syntax → Bool) (stx : Lean.Syntax)
    (values : Array Lean.Syntax := #[]) : Array Lean.Syntax :=
  if predicate stx then values.push stx
  else stx.getArgs.foldl (init := values) fun result child => descendants predicate child result

private structure RecordField where
  stx : Lean.Syntax
  commaAfter : Bool := false
  deriving Inhabited

private partial def recordFields (stx : Lean.Syntax) (fields : Array RecordField := #[]) :
    Array RecordField :=
  if stx.isOfKind ``Lean.Parser.Term.structInstField then fields.push { stx }
  else
    stx.getArgs.foldl (init := fields) fun fields child =>
      if isAtom "," child then
        if fields.isEmpty then fields
        else fields.modify (fields.size - 1) ({ · with commaAfter := true })
      else recordFields child fields

private partial def firstDocument
    (childDocument : Lean.Syntax → Lean.CoreM (Except FormatterFailure (Option Doc)))
    (stx : Lean.Syntax) : Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  if stx.getKind != Lean.nullKind then
    match ← childDocument stx with
    | .ok (some document) => return .ok (some document)
    | .error failure => return .error failure
    | .ok none => pure ()
  if stx.getKind == Lean.nullKind || (Syntax.spellings stx).isEmpty then
    for child in stx.getArgs do
      match ← firstDocument childDocument child with
      | .ok (some document) => return .ok (some document)
      | .error failure => return .error failure
      | .ok none => pure ()
  return .ok none

private def fieldDocument
    (ownership : CommentOwnership)
    (childDocument : Lean.Syntax → Lean.CoreM (Except FormatterFailure (Option Doc)))
    (field : Lean.Syntax) : Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let #[left, right] := field.getArgs | return .ok none
  let definitions := descendants (·.isOfKind ``Lean.Parser.Term.structInstFieldDef) right
  let leading := Trivia.leading ownership field
  let attachLeading := fun document => match leading with
    | some comments => comments ++ Doc.hard ++ document
    | none => document
  let some definition := definitions[0]? |
    return .ok (some (attachLeading (Syntax.flatSyntax left)))
  for child in definition.getArgs do
    if (Syntax.spellings child).isEmpty || isAtom ":=" child then continue
    match ← childDocument child with
    | .ok (some value) =>
      return .ok (some (attachLeading <|
        Syntax.flatSyntax left ++ Doc.text " := " ++ value))
    | .error failure => return .error failure
    | .ok none => pure ()
  return .ok none

private def recordDocument
    (ownership : CommentOwnership)
    (childDocument : Lean.Syntax → Lean.CoreM (Except FormatterFailure (Option Doc)))
    (stx : Lean.Syntax) : Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let #[_, update, fields, ellipsis, typeSpec, _] := stx.getArgs | return .ok none
  let fieldEntries := recordFields fields
  if fieldEntries.isEmpty then return .ok (some (Doc.text "{}"))
  let mut documents := #[]
  for field in fieldEntries do
    match ← fieldDocument ownership childDocument field.stx with
    | .ok (some document) => documents := documents.push document
    | .ok none => return .ok none
    | .error failure => return .error failure
  let mut document := Doc.text "{ "
  if (Syntax.spellings update).isEmpty then
    document := document ++ documents[0]!
  else
    match ← firstDocument childDocument update with
    | .ok (some receiver) =>
      document := document ++ receiver ++ Doc.text " with" ++
        Doc.nest 2 (Doc.line " " ++ documents[0]!)
    | .ok none => return .ok none
    | .error failure => return .error failure
  for index in [1:documents.size] do
    if fieldEntries[index - 1]!.commaAfter then
      document := document ++ Doc.text "," ++ Doc.nest 2 (Doc.line " " ++ documents[index]!)
    else
      document := document ++ Doc.nest 2 (Doc.hard ++ documents[index]!)
  if fieldEntries[fieldEntries.size - 1]!.commaAfter then document := document ++ Doc.text ","
  if (descendants (isAtom "..") ellipsis).size == 1 then
    document := document ++ Doc.text " .."
  else if !(Syntax.spellings ellipsis).isEmpty then
    return .ok none
  if !(Syntax.spellings typeSpec).isEmpty then
    let typeChildren := typeSpec.getArgs.filter fun child =>
      !(Syntax.spellings child).isEmpty && !isAtom ":" child
    let some typeSyntax := typeChildren[0]? | return .ok none
    match ← childDocument typeSyntax with
    | .ok (some typeDocument) => document := document ++ Doc.text " : " ++ typeDocument
    | .ok none => return .ok none
    | .error failure => return .error failure
  return .ok (some (Doc.group (document ++ Doc.text " }")))

/-- Compose one closed delimiter or record root from actual parser children. `none` means this module
does not own the syntax family; it never means to copy the source or delegate a recognized root. -/
def document
    (ownership : CommentOwnership)
    (childDocument : Lean.Syntax → Lean.CoreM (Except FormatterFailure (Option Doc)))
    (stx : Lean.Syntax) : Lean.CoreM (Except FormatterFailure (Option Doc)) :=
  do
    let result ← if stx.isOfKind ``Lean.Parser.Term.paren || stx.isOfKind ``Lean.Parser.Term.tuple ||
        stx.isOfKind ``Lean.Parser.Term.anonymousCtor || stx.getKind == `«term[_]» ||
        stx.getKind == `«term#[_,]» then
      delimiterDocument ownership childDocument stx
    else if stx.isOfKind ``Lean.Parser.Term.structInst then
      recordDocument ownership childDocument stx
    else
      pure (.ok none)
    return result.map fun document? => document?.map fun document =>
      match Trivia.leading ownership stx with
      | some comments => comments ++ Doc.hard ++ document
      | none => document

end LeanFmt.Internal.Formatter.Collection
