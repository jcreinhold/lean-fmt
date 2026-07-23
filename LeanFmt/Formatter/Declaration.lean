/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Structural declaration documents over actual command syntax.

Shared value declarations use their parser nodes for declaration id, binder list, optional result,
and simple value. Their flat and broken forms are lean-fmt documents. Nested result types remain exact
token rows; ordinary value bodies request term documents. Equation declarations, value-less families,
and offside bodies stay with the complete live command registry because their outer grammar or base
column is part of the formatting context. Project command wrappers are not recognized here. -/

import Lean.Parser.Command
import all LeanFmt.Formatter
import all LeanFmt.Formatter.Block
import all LeanFmt.Formatter.Syntax
import all LeanFmt.Formatter.Term

namespace LeanFmt.Internal

namespace Formatter.Declaration

private def handles (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.declaration ||
    stx.isOfKind ``Lean.Parser.Command.mutual ||
    stx.isOfKind ``Lean.Parser.Command.deriving

private def simpleKind (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.abbrev ||
    stx.isOfKind ``Lean.Parser.Command.definition ||
    stx.isOfKind ``Lean.Parser.Command.theorem ||
    stx.isOfKind ``Lean.Parser.Command.opaque ||
    stx.isOfKind ``Lean.Parser.Command.instance ||
    stx.isOfKind ``Lean.Parser.Command.axiom ||
    stx.isOfKind ``Lean.Parser.Command.example

private def isSignature (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.declSig ||
    stx.isOfKind ``Lean.Parser.Command.optDeclSig

private def isSimpleValue (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.declValSimple

private def isEquationValue (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.declValEqns

private def isStructureValue (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.whereStructInst

private def isValue (stx : Lean.Syntax) : Bool :=
  isSimpleValue stx || isEquationValue stx || isStructureValue stx

private partial def findDescendant? (predicate : Lean.Syntax → Bool)
    (stx : Lean.Syntax) : Option Lean.Syntax :=
  if predicate stx then some stx else stx.getArgs.findSome? (findDescendant? predicate)

private partial def descendants (predicate : Lean.Syntax → Bool) (stx : Lean.Syntax)
    (result : Array Lean.Syntax := #[]) : Array Lean.Syntax :=
  if predicate stx then result.push stx
  else stx.getArgs.foldl (init := result) fun result child => descendants predicate child result

private def isBinder (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Term.explicitBinder ||
    stx.isOfKind ``Lean.Parser.Term.implicitBinder ||
    stx.isOfKind ``Lean.Parser.Term.strictImplicitBinder ||
    stx.isOfKind ``Lean.Parser.Term.instBinder ||
    stx.isOfKind ``Lean.Parser.Term.binderIdent

private partial def signatureParts (stx : Lean.Syntax) (binders : Array Lean.Syntax)
    (typeSpec? : Option Lean.Syntax) : Array Lean.Syntax × Option Lean.Syntax :=
  if isBinder stx then (binders.push stx, typeSpec?)
  else if stx.isOfKind ``Lean.Parser.Term.typeSpec then (binders, some stx)
  else stx.getArgs.foldl (init := (binders, typeSpec?)) fun (binders, typeSpec?) child =>
    signatureParts child binders typeSpec?

private structure SimpleParts where
  leading : Array String := #[]
  signature? : Option Lean.Syntax := none
  value? : Option Lean.Syntax := none
  trailing : Array String := #[]

private def simpleParts (modifiers inner : Lean.Syntax) : SimpleParts :=
  let initial : SimpleParts := { leading := Syntax.spellings modifiers }
  inner.getArgs.foldl (init := initial) fun parts child =>
    match findDescendant? isSignature child, findDescendant? isValue child with
    | some signature, _ => { parts with signature? := some signature }
    | _, some value => { parts with value? := some value }
    | _, _ =>
      if parts.value?.isSome then
        { parts with trailing := parts.trailing ++ Syntax.spellings child }
      else
        { parts with leading := parts.leading ++ Syntax.spellings child }

private def typeDocument (typeSpec : Lean.Syntax) : Doc :=
  let tokens := Syntax.spellings typeSpec
  let body := if tokens[0]? == some ":" then tokens.extract 1 tokens.size else tokens
  Doc.text " :" ++ Doc.nest 2 (Doc.line " " ++ Syntax.flat body)

private def valueBody? (value : Lean.Syntax) : Option Lean.Syntax :=
  value.getArgs.find? fun child =>
    let tokens := Syntax.spellings child
    !child.isOfKind ``Lean.Parser.Termination.suffix && !tokens.isEmpty && tokens != #[":="]

private def valueDocument (body : Doc) : Doc :=
  Doc.text " :=" ++ Doc.nest 2 (Doc.line " " ++ body)

private def flatValueDocument (value : Lean.Syntax) : Doc :=
  let tokens := Syntax.spellings value
  let body := if tokens[0]? == some ":=" then tokens.extract 1 tokens.size else tokens
  Doc.text " :=" ++ Doc.nest 2 (Doc.line " " ++ Syntax.flat body)

private def whereDocument? (value : Lean.Syntax) : Option Doc := do
  let whereDecls ← findDescendant? (·.isOfKind ``Lean.Parser.Term.whereDecls) value
  let declarations := descendants (·.isOfKind ``Lean.Parser.Term.letRecDecl) whereDecls
  let mut document := Doc.text "where"
  for declaration in declarations do
    document := document ++ Doc.nest 2
      (Doc.hard ++ Syntax.flat (Syntax.spellings declaration))
  return document

private def terminationDocument? (value : Lean.Syntax) : Option Doc := do
  let suffix ← findDescendant? (·.isOfKind ``Lean.Parser.Termination.suffix) value
  let tokens := Syntax.spellings suffix
  if tokens.isEmpty then none else some (Syntax.flat tokens)

private def equationDocument (value : Lean.Syntax) : Doc :=
  let alternatives := descendants (·.isOfKind ``Lean.Parser.Term.matchAlt) value
  let document? := alternatives.foldl (init := none) fun document? alternative =>
    let row := Syntax.flat (Syntax.spellings alternative)
    some <| match document? with
      | some document => document ++ Doc.hard ++ row
      | none => row
  document?.getD Doc.empty

private def structureValueDocument (value : Lean.Syntax) : Doc :=
  let fields := descendants (·.isOfKind ``Lean.Parser.Term.structInstField) value
  fields.foldl (init := Doc.text "where") fun document field =>
    document ++ Doc.nest 2 (Doc.hard ++ Syntax.flat (Syntax.spellings field))

private def simpleDocument? (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let #[modifiers, inner] := stx.getArgs | return .ok none
  if !simpleKind inner then return .ok none else
  let parts := simpleParts modifiers inner
  let mut document := Syntax.flat parts.leading
  if let some signature := parts.signature? then
    let (binders, typeSpec?) := signatureParts signature #[] none
    for binder in binders do
      document := document ++ Doc.nest 2
        (Doc.line " " ++ Syntax.flat (Syntax.spellings binder))
    if let some typeSpec := typeSpec? then document := document ++ typeDocument typeSpec
  if let some value := parts.value? then
    if isEquationValue value then
      document := document ++ Doc.nest 2 (Doc.hard ++ equationDocument value)
      if let some termination := terminationDocument? value then
        document := document ++ Doc.hard ++ termination
      if let some whereDocument := whereDocument? value then
        document := document ++ Doc.hard ++ whereDocument
    else if isStructureValue value then
      document := document ++ Doc.nest 2 (Doc.hard ++ structureValueDocument value)
    else
      match valueBody? value with
      | some body =>
        if Block.contains body then return .ok none
        match ← Term.format ownership body with
        | .ok formatted => document := document ++ valueDocument formatted.document
        | .error failure => return .error failure
      | none => document := document ++ flatValueDocument value
      if let some termination := terminationDocument? value then
        document := document ++ Doc.hard ++ termination
      if let some whereDocument := whereDocument? value then
        document := document ++ Doc.hard ++ whereDocument
  else if !inner.isOfKind ``Lean.Parser.Command.axiom then
    return .ok none
  unless parts.trailing.isEmpty do
    document := document ++ Doc.nest 2
      (Doc.line " " ++ Syntax.flat parts.trailing)
  return .ok (some (Doc.group document))

private def mutualDocument? (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  if !stx.isOfKind ``Lean.Parser.Command.mutual then return .ok none
  let declarations := descendants (·.isOfKind ``Lean.Parser.Command.declaration) stx
  let mut document := Doc.text "mutual"
  for index in [0:declarations.size] do
    let declaration := declarations[index]!
    match ← simpleDocument? ownership declaration with
    | .ok (some declarationDocument) =>
      let boundary := if index == 0 then Doc.hard else Doc.blank
      document := document ++ boundary ++ Doc.text "  " ++ Doc.nest 2 declarationDocument
    | .error failure => return .error failure
    | .ok none => return .ok none
  return .ok (some (document ++ Doc.hard ++ Doc.text "end"))

private def derivingDocument? (stx : Lean.Syntax) : Option Doc :=
  if stx.isOfKind ``Lean.Parser.Command.deriving then
    some (Syntax.flat (Syntax.spellings stx))
  else none

/-- Format a closed declaration command, or return `none` for a non-declaration command. Shared
simple declarations receive structural flat/broken documents when comment-free; other declaration
families retain the live registry document and trace. -/
def format? (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Option (Except FormatterFailure RegisteredDocument)) := do
  if !handles stx then return none
  let documentResult ← if stx.isOfKind ``Lean.Parser.Command.mutual then
      mutualDocument? ownership stx
    else
      simpleDocument? ownership stx
  match documentResult with
  | .error failure => return some (.error failure)
  | .ok (some document) =>
    if (Comments.subtree ownership stx).isEmpty then
      return some (.ok {
        document
        trace := ← Formatter.trace ownership .command stx
        structural := true })
  | .ok none =>
    if let some document := derivingDocument? stx then
      if (Comments.subtree ownership stx).isEmpty then
        return some (.ok {
          document
          trace := ← Formatter.trace ownership .command stx
          structural := true })
  let registered ← Formatter.registeredAs ownership .command stx stx.unsetTrailing
  return some registered

end Formatter.Declaration

end LeanFmt.Internal
