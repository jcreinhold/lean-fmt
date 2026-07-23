/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Selected-syntax token access for structural formatter rules.

This module is deliberately lexical, not a fallback formatter. It selects one spelling of a parser
`choice`, returns token spellings carried by actual `Syntax`, and constructs only flat token rows.
Owning command/term/block rules decide every break and must refuse constructs whose grammar they do
not structurally own. No operation reads source bytes or source whitespace. -/

import Lean.Syntax
import all LeanFmt.Doc

namespace LeanFmt.Internal.Formatter.Syntax

private partial def spellingsFrom (stx : Lean.Syntax) (values : Array String) : Array String :=
  match stx with
  | .missing => values
  | .atom _ value => if value.isEmpty then values else values.push value
  | .ident _ raw _ _ =>
    let spelling := raw.toString
    if spelling.isEmpty then values else values.push spelling
  | .node _ kind children =>
    if kind == Lean.choiceKind then
      match children[0]? with
      | some selected => spellingsFrom selected values
      | none => values
    else
      children.foldl (init := values) fun result child => spellingsFrom child result

/-- Exact nontrivia token spellings from the selected syntax tree, in source order. -/
def spellings (stx : Lean.Syntax) : Array String := spellingsFrom stx #[]

private def hugsPrevious : String → Bool
  | ")" | "]" | "}" | "⟩" | "," | ";" => true
  | _ => false

private def hugsNext : String → Bool
  | "(" | "[" | "{" | "⟨" | "@(" | "@[" | "`(" | "`[" | "`{" | ".{" | "$" | "." => true
  | _ => false

private def separates (previous token : String) : Bool :=
  let projectionDot := token == "." &&
    previous != "=>" && previous != ":=" && previous != "|" && previous != ","
  !(hugsNext previous || hugsPrevious token || projectionDot)

/-- Canonical flat spacing for an already-owned token row. Delimiter and projection punctuation hug;
all other adjacent tokens receive one space. -/
def flatText (tokens : Array String) : String := Id.run do
  let mut output := ""
  for index in [0:tokens.size] do
    let token := tokens[index]!
    if index > 0 then
      let previous := tokens[index - 1]!
      if separates previous token then output := output ++ " "
    output := output ++ token
  return output

/-- One exact flat token row. A multiline literal is verbatim and therefore remains a valid document
node rather than smuggling a newline through `Doc.text`. -/
def flat (tokens : Array String) : Doc :=
  let value := flatText tokens
  if value.contains '\n' then Doc.verbatim value else Doc.text value

private def opensDelimiter : String → Bool
  | "(" | "[" | "{" | "⟨" | "@(" | "@[" | "`(" | "`[" | "`{" | ".{" => true
  | _ => false

private def closesDelimiter : String → Bool
  | ")" | "]" | "}" | "⟩" => true
  | _ => false

/-- A header row may break only between top-level token groups. Delimited binders and parameter lists
remain indivisible; the keyword and declared name remain together. -/
def groupedTopLevel (tokens : Array String) : Doc := Id.run do
  if tokens.isEmpty then return Doc.empty
  let mut document := Doc.text tokens[0]!
  let mut depth := if opensDelimiter tokens[0]! then 1 else 0
  let protectedPrefix := if tokens[0]? == some "class" && tokens[1]? == some "inductive" then 3 else 2
  for index in [1:tokens.size] do
    let previous := tokens[index - 1]!
    let token := tokens[index]!
    let separator := if separates previous token then
        if index < protectedPrefix || depth > 0 then Doc.text " " else Doc.line " "
      else Doc.empty
    document := document ++ separator ++ Doc.text token
    if closesDelimiter token then depth := depth - 1
    if opensDelimiter token then depth := depth + 1
  return Doc.group (Doc.nest 2 document)

/-- Join nonempty rows with hard line breaks. -/
def lines (rows : Array String) : Doc :=
  let result : Option Doc := rows.foldl (init := none) fun document? row =>
    some <| match document? with
      | some document => document ++ Doc.hard ++ Doc.text row
      | none => Doc.text row
  result.getD Doc.empty

end LeanFmt.Internal.Formatter.Syntax
