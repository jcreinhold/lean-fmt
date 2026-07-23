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
  | ")" | "]" | "}" | "⟩" | "," | ";" | ".{" => true
  | _ => false

private def hugsNext : String → Bool
  | "(" | "[" | "{" | "⟨" | "@(" | "@[" | "#[" | "`" | "`(" | "`[" | "`{" | ".{" | "$" | "." => true
  | _ => false

/-- Whether adjacent selected syntax tokens receive canonical horizontal separation, with the one
token of left context needed by typed antiquotations such as `$x:ident`. -/
def separatesAfter (previousPrevious : Option String) (previous token : String) : Bool :=
  let projectionDot := token == "." &&
    previous != "=>" && previous != ":=" && previous != "|" && previous != ","
  let quotationCategory := token == "|" && previousPrevious.any (·.endsWith "(")
  let compositeOpening := previous.endsWith "(" || previous.endsWith "[" ||
    previous.endsWith "{"
  let compositeProjection := previous.endsWith "."
  let antiquotationRepetition := (previous == "]" || previous == ")") &&
    (token == "?" || token == "*" || token == "+")
  !(hugsNext previous || hugsPrevious token || projectionDot || quotationCategory || compositeOpening ||
    compositeProjection || antiquotationRepetition)

/-- Whether two adjacent selected syntax tokens receive canonical horizontal separation when no
antiquotation context is available. -/
def separates (previous token : String) : Bool := separatesAfter none previous token

/-- Canonical flat spacing for an already-owned token row. Delimiter and projection punctuation hug;
all other adjacent tokens receive one space. -/
def flatText (tokens : Array String) : String := Id.run do
  let mut output := ""
  for index in [0:tokens.size] do
    let token := tokens[index]!
    if index > 0 then
      let previous := tokens[index - 1]!
      if separatesAfter tokens[index - 2]? previous token then output := output ++ " "
    output := output ++ token
  return output

/-- One exact flat token row. A multiline literal is verbatim and therefore remains a valid document
node rather than smuggling a newline through `Doc.text`. -/
def flat (tokens : Array String) : Doc :=
  let value := flatText tokens
  if value.contains '\n' then Doc.verbatim value else Doc.text value

private structure FlatSyntaxToken where
  spelling : String
  compact : Bool
  deriving Inhabited

private partial def flatSyntaxTokens (stx : Lean.Syntax) (tokens : Array FlatSyntaxToken := #[])
    (compact := false) : Array FlatSyntaxToken :=
  match stx with
  | .missing => tokens
  | .atom _ spelling => if spelling.isEmpty then tokens else tokens.push { spelling, compact }
  | .ident _ raw _ _ =>
    let spelling := raw.toString
    if spelling.isEmpty then tokens else tokens.push { spelling, compact }
  | .node _ kind children =>
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    let compact := compact || kind == `antiquotName
    children.foldl (init := tokens) fun tokens child => flatSyntaxTokens child tokens compact

/-- A flat syntax document that preserves the parser's compact typed-antiquotation node. Unlike a
spelling-only heuristic, this distinguishes `$x:ident` from a custom quotation containing `$x :`. -/
def flatSyntax (stx : Lean.Syntax) : Doc := Id.run do
  let tokens := flatSyntaxTokens stx
  let containsQuotation := (List.range tokens.size).any fun index =>
    index >= 2 && tokens[index]!.spelling == "|" &&
      tokens[index - 2]!.spelling.endsWith "("
  if containsQuotation then
    if let some exact := stx.reprint then return Doc.verbatim exact.trimAscii.copy
  let mut output := ""
  for index in [:tokens.size] do
    let token := tokens[index]!
    if index > 0 && !token.compact then
      let previous := tokens[index - 1]!
      if separatesAfter (tokens[index - 2]?.map (·.spelling)) previous.spelling token.spelling then
        output := output ++ " "
    output := output ++ token.spelling
  if output.contains '\n' then return Doc.verbatim output
  return Doc.text output

/-- Exact spelling of a syntax island whose bytes are semantically data, with outer trivia removed
so its structural parent remains the sole boundary owner. -/
private def stripBoundaryInfo (start stop : Nat) : Lean.SourceInfo → Lean.SourceInfo
  | .original leading position trailing endPos =>
    let leading := if leading.startPos.byteIdx < start then
        { leading with stopPos := leading.startPos }
      else leading
    let trailing := if stop < trailing.stopPos.byteIdx then
        { trailing with stopPos := trailing.startPos }
      else trailing
    .original leading position trailing endPos
  | info => info

private partial def withoutBoundaryTrivia (start stop : Nat) : Lean.Syntax → Lean.Syntax
  | .node info kind children =>
    .node (stripBoundaryInfo start stop info) kind
      (children.map (withoutBoundaryTrivia start stop))
  | .atom info value => .atom (stripBoundaryInfo start stop info) value
  | .ident info raw value preresolved =>
    .ident (stripBoundaryInfo start stop info) raw value preresolved
  | .missing => .missing

def verbatimSyntax (stx : Lean.Syntax) : Doc :=
  let start := stx.getRange?.map (·.start.byteIdx) |>.getD 0
  let stop := stx.getRange?.map (·.stop.byteIdx) |>.getD start
  match withoutBoundaryTrivia start stop stx |>.reprint with
  | some value =>
    let tokens := spellings stx
    let value := if let some pipeIndex := tokens.findIdx? (· == "|") then
        if 0 < pipeIndex then
          let category := tokens[pipeIndex - 1]!
          value.replace ("(" ++ category ++ " |") ("(" ++ category ++ "|")
        else value
      else value
    Doc.verbatim value
  | none => flatSyntax stx

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
    let separator := if separatesAfter tokens[index - 2]? previous token then
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
