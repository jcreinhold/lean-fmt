/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Structural control-term documents over explicit parser children.

Branch, declaration, continuation, discriminant, and alternative membership are taken from their
syntax kinds and fixed child contracts. This module never searches rendered text or source columns.
Embedded tactic and `do` bodies are documents supplied by the block owner; the control ancestor
retains structural ownership. -/

import Lean.Parser.Term
import all LeanFmt.Formatter
import all LeanFmt.Formatter.Syntax
import all LeanFmt.Formatter.Trivia

namespace LeanFmt.Internal.Formatter.ControlTerm

private abbrev ChildDocument :=
  Lean.Syntax → Lean.CoreM (Except FormatterFailure (Option Doc))

private def ifDocument (formatChild : ChildDocument) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let #[_, condition, _, positive, _, negative] := stx.getArgs | return .ok none
  match ← formatChild condition with
  | .error failure => return .error failure
  | .ok none => return .ok none
  | .ok (some conditionDocument) =>
    match ← formatChild positive with
    | .error failure => return .error failure
    | .ok none => return .ok none
    | .ok (some positiveDocument) =>
      match ← formatChild negative with
      | .error failure => return .error failure
      | .ok none => return .ok none
      | .ok (some negativeDocument) =>
        return .ok (some (Doc.group <|
          Doc.text "if " ++ conditionDocument ++ Doc.text " then" ++
            Doc.nest 2 (Doc.line " " ++ positiveDocument) ++
            Doc.line " " ++ Doc.text "else" ++
            Doc.nest 2 (Doc.line " " ++ negativeDocument)))

private partial def findKind (kind : Lean.Name) (stx : Lean.Syntax) : Option Lean.Syntax :=
  if stx.getKind == kind then some stx
  else stx.getArgs.findSome? (findKind kind)

private def letDeclaration (formatChild : ChildDocument) (declaration : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let some valueDeclaration :=
      findKind ``Lean.Parser.Term.letIdDecl declaration <|>
        findKind ``Lean.Parser.Term.letPatDecl declaration |
    return .ok none
  let args := valueDeclaration.getArgs
  if args.size < 2 then return .ok none
  let valueSyntax := args[args.size - 1]!
  match ← formatChild valueSyntax with
  | .error failure => return .error failure
  | .ok none => return .ok none
  | .ok (some valueDocument) =>
    let prefixSyntax : Lean.Syntax :=
      .node .none Lean.nullKind (args.extract 0 (args.size - 1))
    return .ok (some (Doc.group <|
      Syntax.flat (Syntax.spellings prefixSyntax) ++
        Doc.nest 2 (Doc.line " " ++ valueDocument)))

private def letDocument (formatChild : ChildDocument) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let #[_, config, declaration, _, continuation] := stx.getArgs | return .ok none
  if !(Syntax.spellings config).isEmpty then return .ok none
  match ← letDeclaration formatChild declaration with
  | .error failure => return .error failure
  | .ok none => return .ok none
  | .ok (some declarationDocument) =>
    match ← formatChild continuation with
    | .error failure => return .error failure
    | .ok none => return .ok none
    | .ok (some continuationDocument) =>
      return .ok (some (Doc.text "let " ++ declarationDocument ++
        Doc.hard ++ continuationDocument))

private partial def containerMembers (containerKind memberKind : Lean.Name) (stx : Lean.Syntax)
    (values : Array Lean.Syntax := #[]) : Array Lean.Syntax :=
  if stx.getKind == memberKind then values.push stx
  else if stx.getKind == containerKind || stx.getKind == Lean.nullKind ||
      stx.getKind == Lean.groupKind then
    stx.getArgs.foldl (init := values) fun result nested =>
      containerMembers containerKind memberKind nested result
  else values

private def discriminantDocument (formatChild : ChildDocument) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let #[binder, value] := stx.getArgs | return .ok none
  match ← formatChild value with
  | .error failure => return .error failure
  | .ok none => return .ok none
  | .ok (some valueDocument) =>
    if (Syntax.spellings binder).isEmpty then return .ok (some valueDocument)
    return .ok (some (Syntax.flat (Syntax.spellings binder) ++ Doc.text " " ++ valueDocument))

private def alternativeDocument (ownership : CommentOwnership) (formatChild : ChildDocument)
    (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let #[_, patterns, _, body] := stx.getArgs | return .ok none
  match ← formatChild body with
  | .error failure => return .error failure
  | .ok none => return .ok none
  | .ok (some bodyDocument) =>
    let document := Doc.group <|
      Doc.text "| " ++ Syntax.flat (Syntax.spellings patterns) ++ Doc.text " =>" ++
        Doc.nest 2 (Doc.line " " ++ bodyDocument)
    return .ok (some <| match Trivia.leading ownership stx with
      | some comments => comments ++ Doc.hard ++ document
      | none => document)

private def matchDocument (ownership : CommentOwnership) (formatChild : ChildDocument)
    (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let #[_, _, _, discriminantContainer, _, alternativeContainer] := stx.getArgs |
    return .ok none
  let discriminants := containerMembers Lean.nullKind ``Lean.Parser.Term.matchDiscr
    discriminantContainer
  let alternatives := containerMembers ``Lean.Parser.Term.matchAlts
    ``Lean.Parser.Term.matchAlt alternativeContainer
  if discriminants.isEmpty || alternatives.isEmpty then return .ok none
  let mut document := Doc.text "match "
  for index in [0:discriminants.size] do
    match ← discriminantDocument formatChild discriminants[index]! with
    | .error failure => return .error failure
    | .ok none => return .ok none
    | .ok (some discriminant) =>
      if index > 0 then document := document ++ Doc.text ", "
      document := document ++ discriminant
  document := Doc.group (document ++ Doc.text " with")
  for alternative in alternatives do
    match ← alternativeDocument ownership formatChild alternative with
    | .error failure => return .error failure
    | .ok none => return .ok none
    | .ok (some arm) => document := document ++ Doc.hard ++ arm
  return .ok (some document)

/-- Compose a closed core control term, returning `none` only for a family owned elsewhere. -/
def document (ownership : CommentOwnership) (formatChild : ChildDocument) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) :=
  if stx.isOfKind ``termIfThenElse then ifDocument formatChild stx
  else if stx.isOfKind ``Lean.Parser.Term.let then letDocument formatChild stx
  else if stx.isOfKind ``Lean.Parser.Term.match then matchDocument ownership formatChild stx
  else return .ok none

end LeanFmt.Internal.Formatter.ControlTerm
