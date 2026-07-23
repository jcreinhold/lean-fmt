/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Structural tactic blocks over actual sequence, focus, alternative, and tactic nodes.

The term caller supplies recursive term formatting. Closed tactic ancestors compose recursively;
only a provenance-proved project tactic reaches the live tactic registry. `do` and local-declaration
offside scopes remain the exact Prompt 13b boundary. -/

import Lean.Parser.Tactic
import Lean.Parser.Term
import all LeanFmt.Formatter
import all LeanFmt.Formatter.Syntax

namespace LeanFmt.Internal.Formatter.Block

private abbrev TermDocument :=
  Lean.Syntax → Lean.CoreM (Except FormatterFailure (Option Doc))

private def nonemptyChildren (stx : Lean.Syntax) : Array Lean.Syntax :=
  stx.getArgs.filter fun child => !(Syntax.spellings child).isEmpty

private def join (documents : Array Doc) (separator : Doc) : Doc :=
  match documents[0]? with
  | none => Doc.empty
  | some first => documents.extract 1 documents.size |>.foldl (init := first) fun result document =>
      result ++ separator ++ document

private partial def tacticDocument (ownership : CommentOwnership) (formatTerm : TermDocument)
    (stx : Lean.Syntax) : Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  match CoreSurface.owner (← Lean.getEnv) .tactic stx.getKind with
  | .extension =>
    return (← Formatter.registered ownership .tactic stx).map fun formatted =>
      some formatted.document
  | _ => pure ()
  if stx.getKind == Lean.nullKind || stx.getKind == Lean.groupKind ||
      stx.isOfKind ``Lean.Parser.Tactic.tacticSeq ||
      stx.isOfKind ``Lean.Parser.Tactic.tacticSeq1Indented then
    let mut documents := #[]
    for nested in nonemptyChildren stx do
      match ← tacticDocument ownership formatTerm nested with
      | .ok (some document) => documents := documents.push document
      | .ok none => return .ok none
      | .error failure => return .error failure
    if documents.isEmpty then return .ok none
    return .ok (some (join documents Doc.hard))
  if stx.getKind == ``Lean.cdot then
    let children := nonemptyChildren stx
    let some body := children.back? | return .ok none
    match ← tacticDocument ownership formatTerm body with
    | .ok (some bodyDocument) =>
      return .ok (some (Doc.text "·" ++ Doc.nest 2 (Doc.line " " ++ bodyDocument)))
    | .ok none => return .ok none
    | .error failure => return .error failure
  if stx.isOfKind ``Lean.Parser.Tactic.first then
    let children := nonemptyChildren stx
    let some alternatives := children.back? | return .ok none
    let mut document := Doc.text "first"
    for alternative in nonemptyChildren alternatives do
      let groupChildren := nonemptyChildren alternative
      let some body := groupChildren.back? | return .ok none
      match ← tacticDocument ownership formatTerm body with
      | .ok (some bodyDocument) =>
        document := document ++ Doc.hard ++ Doc.text "| " ++ bodyDocument
      | .ok none => return .ok none
      | .error failure => return .error failure
    return .ok (some document)
  let args := nonemptyChildren stx
  if args.isEmpty then return .ok none
  let mut documents := #[]
  for nested in args do
    match nested with
    | .atom _ spelling => documents := documents.push (Doc.text spelling)
    | .ident .. => documents := documents.push (Syntax.flat (Syntax.spellings nested))
    | _ =>
      match CoreSurface.owner (← Lean.getEnv) .tactic nested.getKind with
      | .structural .term =>
        match ← formatTerm nested with
        | .ok (some document) => documents := documents.push document
        | .ok none => return .ok none
        | .error failure => return .error failure
      | _ =>
        match ← tacticDocument ownership formatTerm nested with
        | .ok (some document) => documents := documents.push document
        | .ok none => documents := documents.push (Syntax.flat (Syntax.spellings nested))
        | .error failure => return .error failure
  if let #[left, _, right] := documents then
    if (Syntax.spellings args[1]!) == #["<;>"] then
      return .ok (some (Doc.group <|
        left ++ Doc.text " <;>" ++ Doc.nest 2 (Doc.line " " ++ right)))
  return .ok (some (join documents (Doc.text " ")))

/-- Whether a subtree still establishes a cross-category offside scope assigned to Prompt 13b. -/
partial def contains (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Term.do || stx.isOfKind ``Lean.Parser.Term.whereDecls ||
    stx.getArgs.any contains

/-- Compose an actual `by` term from its tactic tree without delegating the closed block root. -/
def document (ownership : CommentOwnership) (formatTerm : TermDocument) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  if !stx.isOfKind ``Lean.Parser.Term.byTactic then return .ok none
  let children := nonemptyChildren stx
  let some sequence := children.back? | return .ok none
  match ← tacticDocument ownership formatTerm sequence with
  | .ok (some body) =>
    return .ok (some (Doc.group (Doc.text "by" ++ Doc.nest 2 (Doc.line " " ++ body))))
  | .ok none => return .ok none
  | .error failure => return .error failure

end LeanFmt.Internal.Formatter.Block
