/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Foundational term documents over actual parsed nodes.

Application, projection, lambda, annotation, named-argument, quotation, and conditional views own
documents from their actual parentage. Precedence-sensitive operators and later control terms remain
with their assigned structural prompts. Project notation invokes the live registry only at its actual
non-core child root; a closed ancestor composes that opaque child without delegating itself. -/

import Lean.Parser.Term
import all LeanFmt.Formatter
import all LeanFmt.Formatter.Block
import all LeanFmt.Formatter.Collection
import all LeanFmt.Formatter.ControlTerm
import all LeanFmt.Formatter.Syntax

namespace LeanFmt.Internal.Formatter.Term

private def nonemptyChildren (stx : Lean.Syntax) : Array Lean.Syntax :=
  stx.getArgs.filter fun child => !(Syntax.spellings child).isEmpty

private def separated (head : Doc) (values : Array Doc) : Doc :=
  values.foldl (init := head) fun document value =>
    document ++ Doc.nest 2 (Doc.line " " ++ value)

private partial def transparentDocument? (stx : Lean.Syntax) : Option Doc := do
  let tokens := Syntax.spellings stx
  if tokens.size == 1 then return Syntax.flat tokens
  if stx.getKind == `termS!_ || stx.getKind == `interpolatedStrKind ||
      stx.getKind == `interpolatedStrLitKind then
    return Syntax.flat tokens
  if stx.getKind == `null || stx.getKind == `group || stx.getKind == `choice then
    let children := nonemptyChildren stx
    if let #[child] := children then return ← transparentDocument? child
  if stx.isOfKind ``Lean.Parser.Term.proj then
    let #[receiver, _, field] := stx.getArgs | none
    let receiverDocument ← transparentDocument? receiver
    return receiverDocument ++ Doc.text "." ++ Syntax.flat (Syntax.spellings field)
  if stx.isOfKind ``Lean.Parser.Term.explicit then
    let children := nonemptyChildren stx
    let some body := children.find? fun child => Syntax.spellings child != #["@"] | none
    let bodyDocument ← transparentDocument? body
    return Doc.text "@" ++ bodyDocument
  if stx.isOfKind ``Lean.Parser.Term.app then
    let #[function, arguments] := stx.getArgs | none
    let functionDocument ← transparentDocument? function
    let arguments := nonemptyChildren arguments
    if arguments.isEmpty then none else
    let mut argumentDocuments := #[]
    for argument in arguments do
      let document ← transparentDocument? argument
      argumentDocuments := argumentDocuments.push document
    return Doc.group (separated functionDocument argumentDocuments)
  if stx.isOfKind ``Lean.Parser.Term.fun then
    let #[_, bodySyntax] := stx.getArgs | none
    if !bodySyntax.isOfKind ``Lean.Parser.Term.basicFun then none else
    let #[binders, typeSpec, _, body] := bodySyntax.getArgs | none
    if !(Syntax.spellings typeSpec).isEmpty then none else
    let binders := nonemptyChildren binders
    if binders.isEmpty then none else
    let mut binderDocuments := #[]
    for binder in binders do
      let document ← transparentDocument? binder
      binderDocuments := binderDocuments.push document
    let bodyDocument ← transparentDocument? body
    let header := Doc.group (separated (Doc.text "fun") binderDocuments ++ Doc.text " =>")
    return Doc.group (header ++ Doc.nest 2 (Doc.line " " ++ bodyDocument))
  if stx.isOfKind ``Lean.Parser.Term.typeAscription ||
      stx.isOfKind ``Lean.Parser.Term.namedArgument ||
      stx.isOfKind ``Lean.Parser.Term.dotIdent ||
      stx.isOfKind ``Lean.Parser.Term.explicitBinder ||
      stx.isOfKind ``Lean.Parser.Term.implicitBinder ||
      stx.isOfKind ``Lean.Parser.Term.strictImplicitBinder ||
      stx.isOfKind ``Lean.Parser.Term.instBinder ||
      stx.isOfKind ``Lean.Parser.Term.binderIdent ||
      stx.isOfKind ``Lean.Parser.Term.doubleQuotedName ||
      stx.isOfKind ``Lean.Parser.Term.quot then
    return Syntax.flat tokens
  none

private partial def composableDocument? (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  if CoreSurface.owner (← Lean.getEnv) .term stx.getKind == .extension then return .ok none
  if let some document := transparentDocument? stx then return .ok (some document)
  let childDocument (child : Lean.Syntax) : Lean.CoreM (Except FormatterFailure (Option Doc)) := do
    match CoreSurface.owner (← Lean.getEnv) .term child.getKind with
    | .extension =>
      return (← Formatter.registered ownership .term child).map fun formatted =>
        some formatted.document
    | _ =>
      match ← composableDocument? ownership child with
      | .ok (some document) => return .ok (some document)
      | .error failure => return .error failure
      | .ok none =>
        -- This is an exact-child debt boundary for the operator, collection, and control-term
        -- owners in Prompts 12b/12c. It must not widen into registry ownership of `stx`; Prompt
        -- 14b removes the boundary once those closed core families are structurally complete.
        return (← Formatter.registered ownership .term child).map fun formatted =>
          some formatted.document
  match ← Collection.document ownership childDocument stx with
  | .ok (some document) => return .ok (some document)
  | .error failure => return .error failure
  | .ok none => pure ()
  match ← ControlTerm.document ownership childDocument stx with
  | .ok (some document) => return .ok (some document)
  | .error failure => return .error failure
  | .ok none => pure ()
  match ← Block.document ownership childDocument stx with
  | .ok (some document) => return .ok (some document)
  | .error failure => return .error failure
  | .ok none => pure ()
  if stx.isOfKind ``Lean.Parser.Term.proj then
    let #[receiver, _, field] := stx.getArgs | return .ok none
    match ← childDocument receiver with
    | .ok (some receiverDocument) =>
      return .ok (some (receiverDocument ++ Doc.text "." ++
        Syntax.flat (Syntax.spellings field)))
    | .ok none => return .ok none
    | .error failure => return .error failure
  if let #[left, operator, right] := stx.getArgs then
    if let .atom _ spelling := operator then
      match ← childDocument left with
      | .error failure => return .error failure
      | .ok none => return .ok none
      | .ok (some leftDocument) =>
        match ← childDocument right with
        | .error failure => return .error failure
        | .ok none => return .ok none
        | .ok (some rightDocument) =>
          return .ok (some (Doc.group <|
            leftDocument ++ Doc.text (" " ++ spelling) ++
              Doc.nest 2 (Doc.line " " ++ rightDocument)))
  if stx.isOfKind ``Lean.Parser.Term.paren then
    let children := nonemptyChildren stx
    let inner? := children.find? fun child =>
      let tokens := Syntax.spellings child
      tokens != #["("] && tokens != #[")"] && !child.isOfKind ``Lean.Parser.Term.hygienicLParen
    let some inner := inner? | return .ok none
    match ← childDocument inner with
    | .ok (some document) => return .ok (some (Doc.text "(" ++ document ++ Doc.text ")"))
    | .ok none => return .ok none
    | .error failure => return .error failure
  if stx.isOfKind ``Lean.Parser.Term.app then
    let #[function, arguments] := stx.getArgs | return .ok none
    match ← childDocument function with
    | .error failure => return .error failure
    | .ok none => return .ok none
    | .ok (some functionDocument) =>
      let arguments := nonemptyChildren arguments
      if arguments.isEmpty then return .ok none
      let mut argumentDocuments := #[]
      for argument in arguments do
        match ← childDocument argument with
        | .ok (some document) => argumentDocuments := argumentDocuments.push document
        | .ok none => return .ok none
        | .error failure => return .error failure
      return .ok (some (Doc.group (separated functionDocument argumentDocuments)))
  if stx.isOfKind ``Lean.Parser.Term.fun then
    let #[_, bodySyntax] := stx.getArgs | return .ok none
    if !bodySyntax.isOfKind ``Lean.Parser.Term.basicFun then return .ok none
    let #[binders, typeSpec, _, body] := bodySyntax.getArgs | return .ok none
    let binders := nonemptyChildren binders
    if binders.isEmpty then return .ok none
    let mut binderDocuments := #[]
    for binder in binders do
      match ← childDocument binder with
      | .ok (some document) => binderDocuments := binderDocuments.push document
      | .ok none => return .ok none
      | .error failure => return .error failure
    let header := separated (Doc.text "fun") binderDocuments ++
      (if (Syntax.spellings typeSpec).isEmpty then Doc.empty
       else Doc.text " : " ++ Syntax.flat (Syntax.spellings typeSpec)) ++
      Doc.text " =>"
    match ← childDocument body with
    | .ok (some bodyDocument) =>
      return .ok (some (Doc.group <|
        Doc.group header ++ Doc.nest 2 (Doc.line " " ++ bodyDocument)))
    | .ok none => return .ok none
    | .error failure => return .error failure
  return .ok none

/-- Format one actual term child. Transparent core views become composable documents; every opaque or
precedence-sensitive view uses its live registered formatter on the actual node. -/
def format (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure RegisteredDocument) := do
  match ← composableDocument? ownership stx with
  | .ok (some document) =>
    return .ok {
      document
      trace := ← Formatter.trace ownership .term stx
      structural := true }
  | .error failure => return .error failure
  | .ok none =>
    return ← Formatter.registered ownership .term stx

end LeanFmt.Internal.Formatter.Term
