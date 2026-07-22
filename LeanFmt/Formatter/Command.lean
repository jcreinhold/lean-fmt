/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Core command-shell ownership over actual parsed syntax.

The public operation deliberately reports only the ownership boundary needed by whole-module
composition. Header syntax and Lean's built-in command namespace are closed formatter-owned shells;
all other command kinds are open project syntax and stay with the live formatter registry. Nested
declarations, terms, tactics, and parser categories remain inside the same registry traversal until
their dedicated structural layers replace them.

This classification is structural rather than a spelling database: adding a new project command does
not require changing lean-fmt, and adding a new toolchain command under `Lean.Parser.Command` enters
the closed core side automatically. -/

import Lean.Parser.Module
import all LeanFmt.Formatter

namespace LeanFmt.Internal

/-- Whether an actual command document belongs to lean-fmt's closed shell layer or the environment's
open formatter registry. -/
inductive CommandDocumentOwner where
  | core
  | registry
  deriving Inhabited, BEq, Repr

/-- A formatted header or command and the boundary that owns its outer syntax. -/
structure CommandDocument where
  document : Doc
  trace : FormatterTrace
  owner : CommandDocumentOwner
  deriving Inhabited

/-- Owner-relative placement of one command in the module stream. -/
structure CommandPlacement where
  indent : Nat
  blankBefore : Bool
  deriving Inhabited, BEq, Repr

private inductive CommandRole where
  | scopeOpen
  | scopeClose
  | setup
  | declaration
  deriving Inhabited, BEq

/-- Width-independent state for structural command composition. Its representation is private so the
caller cannot infer nesting from source columns or manufacture a different spacing policy. -/
structure CommandSequence where
  private depth : Nat := 0
  private previous? : Option CommandRole := none

namespace Formatter.Command

def sequence : CommandSequence := {}

private def role (stx : Lean.Syntax) : CommandRole :=
  if stx.isOfKind ``Lean.Parser.Command.namespace ||
      stx.isOfKind ``Lean.Parser.Command.section then
    .scopeOpen
  else if stx.isOfKind ``Lean.Parser.Command.end then
    .scopeClose
  else if stx.isOfKind ``Lean.Parser.Command.open ||
      stx.isOfKind ``Lean.Parser.Command.export ||
      stx.isOfKind ``Lean.Parser.Command.universe ||
      stx.isOfKind ``Lean.Parser.Command.variable ||
      stx.isOfKind ``Lean.Parser.Command.set_option then
    .setup
  else
    .declaration

private def separated (previous current : CommandRole) : Bool :=
  match previous, current with
  | .setup, .setup => false
  | .scopeOpen, .scopeClose => false
  | _, _ => true

/-- Advance the structural module stream and return the command's canonical indentation and vertical
boundary. Scope closing is applied before placement; scope opening is applied after it. -/
def place (state : CommandSequence) (stx : Lean.Syntax) : CommandSequence × CommandPlacement :=
  let current := role stx
  let indent := match current with
    | .scopeClose => state.depth - 1
    | _ => state.depth
  let blankBefore := state.previous?.any (separated · current)
  let depth := match current with
    | .scopeOpen => indent + 1
    | .scopeClose => indent
    | _ => state.depth
  (⟨depth, some current⟩, { indent := indent * 2, blankBefore })

private partial def contractFrom (stx : Lean.Syntax) (entries : Array String) : Array String :=
  match stx with
  | .missing => entries.push "missing"
  | .atom _ value => entries.push ("atom:" ++ value)
  | .ident _ raw _ _ => entries.push ("ident:" ++ raw.toString)
  | .node _ kind children =>
    if kind == Lean.choiceKind then
      match children[0]? with
      | some selected => contractFrom selected entries
      | none => entries.push "choice:empty"
    else
      children.foldl (init := entries.push ("node:" ++ kind.toString)) fun result child =>
        contractFrom child result

/-- Location-independent header structure. Token spellings remain exact; whitespace and source
positions are intentionally absent. -/
def headerContract (stx : Lean.Syntax) : Array String :=
  contractFrom stx #[]

private def format (ownership : CommentOwnership) (owner : CommandDocumentOwner)
    (category : FormatterCategory) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure CommandDocument) := do
  let result ← Formatter.registered ownership category stx
  let document := result.map fun registered =>
    { document := registered.document, trace := registered.trace, owner }
  return document

private def ownerOf (stx : Lean.Syntax) : CommandDocumentOwner :=
  let coreNamespace := ``Lean.Parser.Command.declaration |>.getPrefix
  if coreNamespace.isPrefixOf stx.getKind then .core else .registry

private partial def tokenSpellingsFrom (stx : Lean.Syntax) (values : Array String) : Array String :=
  match stx with
  | .missing => values
  | .atom _ value => if value.isEmpty then values else values.push value
  | .ident _ raw value _ =>
    let spelling := raw.toString
    values.push (if spelling.isEmpty then value.toString else spelling)
  | .node _ kind children =>
    if kind == Lean.choiceKind then
      match children[0]? with
      | some selected => tokenSpellingsFrom selected values
      | none => values
    else
      children.foldl (init := values) fun result child => tokenSpellingsFrom child result

private def tokenSpellings (stx : Lean.Syntax) : Array String := tokenSpellingsFrom stx #[]

private def hugsPrevious : String → Bool
  | ")" | "]" | "}" | "⟩" | "," | ";" => true
  | _ => false

private def hugsNext : String → Bool
  | "(" | "[" | "{" | "⟨" | "`(" | "`[" | "`{" | "$" => true
  | _ => false

private def spacedTokens (tokens : Array String) : String := Id.run do
  let mut output := ""
  for index in [0:tokens.size] do
    let token := tokens[index]!
    if index > 0 then
      let previous := tokens[index - 1]!
      unless hugsNext previous || hugsPrevious token do output := output ++ " "
    output := output ++ token
  return output

private def lines (rows : Array String) : Doc :=
  let result : Option Doc := rows.foldl (init := none) fun document? row =>
    some <| match document? with
      | some document => document ++ Doc.hard ++ Doc.text row
      | none => Doc.text row
  result.getD Doc.empty

private partial def headerRowsFrom (stx : Lean.Syntax) (rows : Array String) : Array String :=
  if stx.isOfKind ``Lean.Parser.Module.import then
    rows.push (spacedTokens (tokenSpellings stx))
  else match stx with
    | .atom _ value => if value == "module" || value == "prelude" then rows.push value else rows
    | .node _ _ children =>
      children.foldl (init := rows) fun result child => headerRowsFrom child result
    | _ => rows

private def headerDocument? (stx : Lean.Syntax) : Option Doc :=
  if stx.isOfKind ``Lean.Parser.Module.header then some (lines (headerRowsFrom stx #[])) else none

/-- Format the parsed module/import header as one closed core document. Import order and modifiers
remain those of the actual header syntax. A comment-free header uses formatter-owned rows; until the
trivia layer lands, a commented header retains Lean's exact comment emission. -/
def header (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure CommandDocument) := do
  let result ← format ownership .core (.named ``Lean.Parser.Module.header) stx
  match result, headerDocument? stx with
  | .ok formatted, some document =>
    if (Comments.subtree ownership stx).isEmpty then
      return .ok { formatted with document }
    else
      return .ok formatted
  | result, _ => return result

private def macroRulesDocument (stx : Lean.Syntax) : Doc :=
  let tokens := tokenSpellings stx
  let body := if tokens[0]? == some "macro_rules" then tokens.extract 1 tokens.size else tokens
  let alternatives := body.foldl (init := #[]) fun (rows : Array (Array String)) token =>
    if token == "|" then rows.push #[token]
    else match rows.back? with
      | some row => rows.set! (rows.size - 1) (row.push token)
      | none => #[#[token]]
  alternatives.foldl (init := Doc.text "macro_rules") fun document alternative =>
    document ++ Doc.nest 2 (Doc.hard ++ Doc.text (spacedTokens alternative))

/-- Format one actual ordinary command. Built-in command shells are closed; project-defined command
syntax is delegated under the environment and options that parsed it. -/
def command (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure CommandDocument) := do
  let result ← format ownership (ownerOf stx) .command stx
  if stx.isOfKind ``Lean.Parser.Command.macro_rules &&
      (Comments.subtree ownership stx).isEmpty then
    let trace := match result with
      | .ok formatted => formatted.trace
      | .error failure => failure.trace
    return .ok { document := macroRulesDocument stx, trace, owner := .core }
  match result with
  | .ok formatted => return .ok formatted
  | .error failure => return .error failure

end Formatter.Command

end LeanFmt.Internal
