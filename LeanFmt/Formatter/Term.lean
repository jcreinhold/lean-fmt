/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Foundational term documents over actual parsed nodes.

Application, projection, lambda, and conditional views own documents only when every nested child is
transparent to this module. Precedence-sensitive operators, project notation, lets, annotations,
named arguments, quotations, and every other term stay with the live term registry. This boundary is
intentional: the registry has the parser's precedence and parenthesizer information, while this module
has no operator spelling table and never infers structure from a flat token list. -/

import Lean.Parser.Term
import all LeanFmt.Formatter
import all LeanFmt.Formatter.Block
import all LeanFmt.Formatter.Collection
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
  if stx.isOfKind ``Lean.Parser.Term.proj then
    let #[receiver, _, field] := stx.getArgs | none
    let receiverDocument ← transparentDocument? receiver
    return receiverDocument ++ Doc.text "." ++ Syntax.flat (Syntax.spellings field)
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
  if stx.isOfKind ``termIfThenElse then
    let #[_, condition, _, positive, _, negative] := stx.getArgs | none
    let conditionDocument ← transparentDocument? condition
    let positiveDocument ← transparentDocument? positive
    let negativeDocument ← transparentDocument? negative
    return Doc.group <|
      Doc.text "if " ++ conditionDocument ++ Doc.text " then" ++
        Doc.nest 2 (Doc.line " " ++ positiveDocument) ++
        Doc.line " " ++ Doc.text "else" ++
        Doc.nest 2 (Doc.line " " ++ negativeDocument)
  if let some document := Collection.document? transparentDocument? stx then return document
  none

/-- Format one actual term child. Transparent core views become composable documents; every opaque or
precedence-sensitive view uses its live registered formatter on the actual node. -/
def format (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure RegisteredDocument) := do
  let registered ← Formatter.registered ownership .term stx
  if !(Comments.subtree ownership stx).isEmpty then return registered
  if let some block := Block.formatTerm? stx registered then return block
  match transparentDocument? stx with
  | some document =>
    let trace := match registered with
      | .ok value => value.trace
      | .error failure => failure.trace
    return .ok { document, trace, structural := true }
  | none => return registered

end LeanFmt.Internal.Formatter.Term
