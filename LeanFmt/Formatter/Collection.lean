/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Transparent collection documents over actual delimiter, separator, field, and arm nodes.

The caller supplies the term-document boundary. A collection is structurally owned only when every
nested value is transparent through that boundary; otherwise its actual outer node stays with the
live registry. Separator presence comes from separator children, never from source columns or a flat
token scan. -/

import Lean.Parser.Term
import all LeanFmt.Formatter.Syntax

namespace LeanFmt.Internal.Formatter.Collection

private structure Separated where
  values : Array Doc := #[]
  separators : Nat := 0
  trailing : Bool := false

private partial def separated? (childDocument? : Lean.Syntax → Option Doc)
    (stx : Lean.Syntax) (result : Separated := {}) : Option Separated := do
  let mut result := result
  for child in stx.getArgs do
    let tokens := Syntax.spellings child
    if tokens.isEmpty then continue
    if tokens == #[","] then
      result := { result with separators := result.separators + 1, trailing := true }
    else if child.getKind == Lean.nullKind then
      result ← separated? childDocument? child result
    else
      let document ← childDocument? child
      result := { result with values := result.values.push document, trailing := false }
  if result.values.isEmpty && !(Syntax.spellings stx).isEmpty then none else
  if result.separators < result.values.size - 1 then none else
  if result.separators > result.values.size then none else
  return result

private def delimited (opening closing : String) (items : Separated) : Doc :=
  if items.values.isEmpty then Doc.text (opening ++ closing) else
  Id.run do
    let mut document := Doc.text opening ++
      Doc.nest 2 (Doc.line "" ++ items.values[0]!)
    for index in [1:items.values.size] do
      document := document ++ Doc.text "," ++
        Doc.nest 2 (Doc.line " " ++ items.values[index]!)
    if items.trailing then document := document ++ Doc.text ","
    return Doc.group (document ++ Doc.line "" ++ Doc.text closing)

private def delimiterDocument? (childDocument? : Lean.Syntax → Option Doc)
    (stx : Lean.Syntax) : Option Doc := do
  let args := stx.getArgs
  if args.size < 2 then none else
  let openingTokens := Syntax.spellings args[0]!
  let closingTokens := Syntax.spellings args[args.size - 1]!
  let opening ← openingTokens[0]?
  let closing ← closingTokens[closingTokens.size - 1]?
  let middle := args.extract 1 (args.size - 1)
  let wrapper : Lean.Syntax := .node .none Lean.nullKind middle
  let items ← separated? childDocument? wrapper
  return delimited opening closing items

private partial def findDescendants (predicate : Lean.Syntax → Bool) (stx : Lean.Syntax)
    (values : Array Lean.Syntax := #[]) : Array Lean.Syntax :=
  if predicate stx then values.push stx
  else stx.getArgs.foldl (init := values) fun result child => findDescendants predicate child result

private partial def firstDocument? (childDocument? : Lean.Syntax → Option Doc)
    (stx : Lean.Syntax) : Option Doc :=
  childDocument? stx <|> stx.getArgs.findSome? (firstDocument? childDocument?)

private def fieldDocument? (childDocument? : Lean.Syntax → Option Doc)
    (field : Lean.Syntax) : Option Doc := do
  let #[left, right] := field.getArgs | none
  let definitions := findDescendants (·.isOfKind ``Lean.Parser.Term.structInstFieldDef) right
  let definition ← definitions[0]?
  let value ← definition.getArgs.findSome? fun child =>
    if (Syntax.spellings child).isEmpty || Syntax.spellings child == #[":="] then none
    else childDocument? child
  return Syntax.flat (Syntax.spellings left) ++ Doc.text " := " ++ value

private def recordDocument? (childDocument? : Lean.Syntax → Option Doc)
    (stx : Lean.Syntax) : Option Doc := do
  let #[_, update, fields, ellipsis, typeSpec, _] := stx.getArgs | none
  if !(Syntax.spellings ellipsis).isEmpty || !(Syntax.spellings typeSpec).isEmpty then none else
  let fieldNodes := findDescendants (·.isOfKind ``Lean.Parser.Term.structInstField) fields
  if fieldNodes.isEmpty then return Doc.text "{}"
  let mut documents := #[]
  for field in fieldNodes do
    let document ← fieldDocument? childDocument? field
    documents := documents.push document
  let separators := findDescendants (fun child => Syntax.spellings child == #[","]) fields |>.size
  if separators > documents.size then none else
  let mut document := Doc.text "{ "
  if (Syntax.spellings update).isEmpty then
    document := document ++ documents[0]!
  else
    let receiver ← firstDocument? childDocument? update
    document := document ++ receiver ++ Doc.text " with" ++
      Doc.nest 2 (Doc.line " " ++ documents[0]!)
  for index in [1:documents.size] do
    if separators >= index then
      document := document ++ Doc.text "," ++ Doc.nest 2 (Doc.line " " ++ documents[index]!)
    else
      document := document ++ Doc.nest 2 (Doc.hard ++ documents[index]!)
  if separators == documents.size then document := document ++ Doc.text ","
  return Doc.group (document ++ Doc.text " }")

private def matchArmDocument? (childDocument? : Lean.Syntax → Option Doc)
    (arm : Lean.Syntax) : Option Doc := do
  let #[_, patterns, _, body] := arm.getArgs | none
  let patterns := nonemptyPatternChildren patterns
  if patterns.isEmpty then none else
  let mut patternDocument ← childDocument? patterns[0]!
  for index in [1:patterns.size] do
    patternDocument := patternDocument ++ Doc.text " | " ++
      (← childDocument? patterns[index]!)
  let bodyDocument ← childDocument? body
  return Doc.group <| Doc.text "| " ++ patternDocument ++ Doc.text " =>" ++
    Doc.nest 2 (Doc.line " " ++ bodyDocument)
where
  nonemptyPatternChildren (stx : Lean.Syntax) : Array Lean.Syntax :=
    stx.getArgs.filter fun child => !(Syntax.spellings child).isEmpty

private def matchDocument? (childDocument? : Lean.Syntax → Option Doc)
    (stx : Lean.Syntax) : Option Doc := do
  let discriminants := findDescendants (·.isOfKind ``Lean.Parser.Term.matchDiscr) stx
  let arms := findDescendants (·.isOfKind ``Lean.Parser.Term.matchAlt) stx
  if discriminants.isEmpty || arms.isEmpty then none else
  let mut document := Doc.text "match "
  for index in [0:discriminants.size] do
    if index > 0 then document := document ++ Doc.text ", "
    let discriminant := discriminants[index]!
    let value ← discriminant.getArgs.findSome? childDocument?
    document := document ++ value
  document := document ++ Doc.text " with"
  for arm in arms do
    document := document ++ Doc.hard ++ (← matchArmDocument? childDocument? arm)
  return document

/-- Build a transparent collection document, or return `none` so the caller can use the actual
node's registered term formatter. -/
def document? (childDocument? : Lean.Syntax → Option Doc) (stx : Lean.Syntax) : Option Doc :=
  if stx.isOfKind ``Lean.Parser.Term.paren || stx.isOfKind ``Lean.Parser.Term.tuple ||
      stx.getKind == `«term[_]» || stx.getKind == `«term#[_,]» then
    delimiterDocument? childDocument? stx
  else if stx.isOfKind ``Lean.Parser.Term.structInst then
    recordDocument? childDocument? stx
  else if stx.isOfKind ``Lean.Parser.Term.match then
    matchDocument? childDocument? stx
  else none

end LeanFmt.Internal.Formatter.Collection
