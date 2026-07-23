/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Structural declaration documents over actual command syntax.

Shared value declarations use their parser nodes for declaration id, binder list, optional result,
value, equations, termination suffix, and local `where` declarations. Their flat and broken forms are
lean-fmt documents, and term, tactic, control, and `do` bodies retain structural ownership across the
command boundary. Unsupported project command wrappers are not recognized here. -/

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

private def familyKind (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.inductive ||
    stx.isOfKind ``Lean.Parser.Command.coinductive ||
    stx.isOfKind ``Lean.Parser.Command.classInductive ||
    stx.isOfKind ``Lean.Parser.Command.structure

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

private partial def containerMembers (containerKind memberKind : Lean.Name) (stx : Lean.Syntax)
    (result : Array Lean.Syntax := #[]) : Array Lean.Syntax :=
  if stx.getKind == memberKind then result.push stx
  else if stx.getKind == containerKind || stx.getKind == Lean.nullKind ||
      stx.getKind == Lean.groupKind then
    stx.getArgs.foldl (init := result) fun values child =>
      containerMembers containerKind memberKind child values
  else result

private partial def transparentMember? (kind : Lean.Name) (stx : Lean.Syntax) : Option Lean.Syntax :=
  if stx.getKind == kind then some stx
  else if stx.getKind == Lean.nullKind || stx.getKind == Lean.groupKind then
    stx.getArgs.findSome? (transparentMember? kind)
  else none

private def isFamilyMember (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.ctor ||
    stx.isOfKind ``Lean.Parser.Command.computedField ||
    stx.isOfKind ``Lean.Parser.Command.structExplicitBinder ||
    stx.isOfKind ``Lean.Parser.Command.structImplicitBinder ||
    stx.isOfKind ``Lean.Parser.Command.structInstBinder ||
    stx.isOfKind ``Lean.Parser.Command.structSimpleBinder

private partial def spellingsExcept (excluded : Lean.Syntax → Bool) (stx : Lean.Syntax)
    (result : Array String := #[]) : Array String :=
  if excluded stx then result else
  match stx with
  | .missing => result
  | .atom _ value => if value.isEmpty then result else result.push value
  | .ident _ raw _ _ =>
    let value := raw.toString
    if value.isEmpty then result else result.push value
  | .node _ kind children =>
    if kind == Lean.choiceKind then
      match children[0]? with
      | some selected => spellingsExcept excluded selected result
      | none => result
    else
      children.foldl (init := result) fun result child => spellingsExcept excluded child result

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

private def declarationHead (tokens : Array String) : Doc := Id.run do
  let mut document := Doc.empty
  let mut ordinary := #[]
  let mut docComment := #[]
  for token in tokens do
    if !docComment.isEmpty then
      docComment := docComment.push token
      if token.endsWith "-/" then
        document := document ++ Syntax.flat docComment ++ Doc.hard
        docComment := #[]
    else if token.startsWith "/--" || token.startsWith "/-!" then
      unless ordinary.isEmpty do
        document := document ++ Syntax.flat ordinary ++ Doc.text " "
      ordinary := #[]
      docComment := #[token]
      if token.endsWith "-/" then
        document := document ++ Syntax.flat docComment ++ Doc.hard
        docComment := #[]
    else
      ordinary := ordinary.push token
  unless docComment.isEmpty do document := document ++ Syntax.flat docComment ++ Doc.hard
  unless ordinary.isEmpty do document := document ++ Syntax.flat ordinary
  return document

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
  let owner := if value.isOfKind ``Lean.Parser.Command.declValEqns then
      findDescendant? (·.isOfKind ``Lean.Parser.Term.matchAltsWhereDecls) value |>.getD value
    else value
  let whereDecls ← owner.getArgs.findSome? (transparentMember? ``Lean.Parser.Term.whereDecls)
  let declarations := containerMembers ``Lean.Parser.Term.whereDecls
    ``Lean.Parser.Term.letRecDecl whereDecls
  let mut document := Doc.text "where"
  for declaration in declarations do
    document := document ++ Doc.nest 2
      (Doc.hard ++ Syntax.flat (Syntax.spellings declaration))
  return document

private def terminationDocument? (value : Lean.Syntax) : Option Doc := do
  let suffix ← findDescendant? (·.isOfKind ``Lean.Parser.Termination.suffix) value
  let tokens := Syntax.spellings suffix
  if tokens.isEmpty then none else some (Syntax.flat tokens)

private def equationDocument (ownership : CommentOwnership) (value : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure Doc) := do
  let some equationContainer :=
      findDescendant? (·.isOfKind ``Lean.Parser.Term.matchAltsWhereDecls) value |
    return .ok Doc.empty
  let some alternativeContainer := equationContainer.getArgs.findSome?
      (transparentMember? ``Lean.Parser.Term.matchAlts) |
    return .ok Doc.empty
  let alternatives := containerMembers ``Lean.Parser.Term.matchAlts
    ``Lean.Parser.Term.matchAlt alternativeContainer
  let mut document? := none
  for alternative in alternatives do
    let #[_, patterns, _, body] := alternative.getArgs | continue
    match ← Term.format ownership body with
    | .error failure => return .error failure
    | .ok formatted =>
      let row := Doc.text "| " ++ Syntax.flat (Syntax.spellings patterns) ++ Doc.text " =>" ++
        Doc.nest 2 (Doc.line " " ++ formatted.document)
      document? := some <| document?.map (· ++ Doc.hard ++ row) |>.getD row
  return .ok (document?.getD Doc.empty)

private def structureValueDocument (value : Lean.Syntax) : Doc :=
  let fields := descendants (·.isOfKind ``Lean.Parser.Term.structInstField) value
  fields.foldl (init := Doc.text "where") fun document field =>
    document ++ Doc.nest 2 (Doc.hard ++ Syntax.flat (Syntax.spellings field))

private def familyDocument? (stx : Lean.Syntax) : Option Doc := do
  let #[modifiers, inner] := stx.getArgs | none
  if !familyKind inner then none else
  let excluded := fun child => isFamilyMember child ||
    child.isOfKind ``Lean.Parser.Command.optDeriving
  let headerTokens := Syntax.spellings modifiers ++ spellingsExcept excluded inner
  let members := descendants isFamilyMember inner
  let mut document := Syntax.groupedTopLevel headerTokens
  for member in members do
    document := document ++ Doc.nest 2
      (Doc.hard ++ Syntax.flat (Syntax.spellings member))
  if let some derivingStx := findDescendant? (·.isOfKind ``Lean.Parser.Command.optDeriving) inner then
    let tokens := Syntax.spellings derivingStx
    unless tokens.isEmpty do
      document := document ++ Doc.nest 2 (Doc.hard ++ Syntax.flat tokens)
  return document

private def simpleDocument? (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let #[modifiers, inner] := stx.getArgs | return .ok none
  if !simpleKind inner then return .ok none else
  let parts := simpleParts modifiers inner
  let mut document := declarationHead parts.leading
  if let some signature := parts.signature? then
    let (binders, typeSpec?) := signatureParts signature #[] none
    for binder in binders do
      document := document ++ Doc.nest 2
        (Doc.line " " ++ Syntax.flat (Syntax.spellings binder))
    if let some typeSpec := typeSpec? then document := document ++ typeDocument typeSpec
  if let some value := parts.value? then
    if isEquationValue value then
      match ← equationDocument ownership value with
      | .error failure => return .error failure
      | .ok equations => document := document ++ Doc.nest 2 (Doc.hard ++ equations)
      if let some termination := terminationDocument? value then
        document := document ++ Doc.hard ++ termination
      if let some whereDocument := whereDocument? value then
        document := document ++ Doc.hard ++ whereDocument
    else if isStructureValue value then
      document := document ++ Doc.nest 2 (Doc.hard ++ structureValueDocument value)
    else
      match valueBody? value with
      | some body =>
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

/-- Format a closed declaration command, or return `none` for a non-declaration command. Supported
core declaration families receive structural documents; only an unsupported declaration shape falls
back to its actual live registry root. -/
def format? (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Option (Except FormatterFailure RegisteredDocument)) := do
  if !handles stx then return none
  let documentResult ← if stx.isOfKind ``Lean.Parser.Command.mutual then
    mutualDocument? ownership stx
  else if let some family := familyDocument? stx then
    pure (.ok (some family))
  else
    simpleDocument? ownership stx
  match documentResult with
  | .error failure => return some (.error failure)
  | .ok (some document) =>
    return some (.ok {
      document
      trace := ← Formatter.trace ownership .command stx
      structural := true })
  | .ok none =>
    if let some document := derivingDocument? stx then
      return some (.ok {
        document
        trace := ← Formatter.trace ownership .command stx
        structural := true })
  let registered ← Formatter.registeredAs ownership .command stx stx.unsetTrailing
  return some registered

end Formatter.Declaration

end LeanFmt.Internal
