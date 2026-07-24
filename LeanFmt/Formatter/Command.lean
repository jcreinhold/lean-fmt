/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Module-stream composition: the header document, the header contract, and the vertical boundary
between two ordinary commands.

Every ordinary command's layout belongs to `LeanFmt.Formatter.NativeLayout`, which drives Lean's own
registered formatter. This module owns only what sits *between* those documents and the one command
Lean's registry cannot supply: the module header, which is parsed before any environment exists.

The header is the one place lean-fmt still spells tokens itself, and it is small enough to say what
that costs. `Lean.Parser.Module.header` is `optional module >> optional prelude >> many import`, and
`import` is `optional public >> optional meta >> "import " >> optional all >> ident`. That closed
token set contains no delimiter, no projection dot, and no antiquotation, so the separator between
two adjacent header tokens is always one space -- which is why this module carries no spacing table.
`headerDocument?` refuses anything that is not a header node and falls back to the registry.

`place` decides blank lines between commands, not indentation: Lean's command style keeps top-level
commands at column zero even inside a namespace, so indentation is a command's own business. -/

import Lean.Parser.Module
import all LeanFmt.Formatter
import all LeanFmt.Formatter.Trivia

namespace LeanFmt.Internal

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

/-- Advance the structural module stream and return its vertical boundary. Lean's command style keeps
top-level commands at column zero even inside namespaces and sections; indentation belongs to command
internals, not to the module stream. -/
def place (state : CommandSequence) (stx : Lean.Syntax) : CommandSequence × CommandPlacement :=
  let current := role stx
  let blankBefore := state.previous?.any (separated · current)
  (⟨some current⟩, { indent := 0, blankBefore })

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

private structure HeaderToken where
  stx : Lean.Syntax
  spelling : String
  deriving Inhabited

private partial def headerTokens (stx : Lean.Syntax) (tokens : Array HeaderToken := #[]) :
    Array HeaderToken :=
  match stx with
  | .missing => tokens
  | .atom _ spelling => if spelling.isEmpty then tokens else tokens.push { stx, spelling }
  | .ident _ raw _ _ =>
    let spelling := raw.toString
    if spelling.isEmpty then tokens else tokens.push { stx, spelling }
  | .node _ kind children =>
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := tokens) fun tokens child => headerTokens child tokens

private def hasTrailingLine (ownership : CommentOwnership) (stx : Lean.Syntax) : Bool :=
  (Comments.trailing ownership stx).any fun comment => comment.kind == .line

/-- One `import` row. The caller owns the row's own leading and trailing comments, so the tokens
inside carry only the comments physically between them; a line comment there forces a break, because
everything after it on that line would otherwise be commented out. -/
private def importDocument (ownership : CommentOwnership) (stx : Lean.Syntax) : Doc := Id.run do
  let tokens := headerTokens stx
  let some first := tokens[0]? | return Doc.empty
  let tokenText := fun (token : HeaderToken) => Doc.text token.spelling
  let mut document := if tokens.size == 1 then tokenText first
    else Trivia.decorateTrailingBeforeBoundary ownership first.stx (tokenText first)
  for index in [1:tokens.size] do
    let previous := tokens[index - 1]!
    let token := tokens[index]!
    let boundary := if hasTrailingLine ownership previous.stx ||
        !(Comments.leading ownership token.stx).isEmpty then
      Doc.hard
    else Doc.line " "
    let tokenDocument := if index + 1 == tokens.size then
        Trivia.decorateLeading ownership token.stx (tokenText token)
      else Trivia.decorateBeforeBoundary ownership token.stx (tokenText token)
    document := document ++ boundary ++ tokenDocument
  let row := match tokens[0]? with
    | some token => Trivia.decorateLeading ownership token.stx (Doc.group document)
    | none => Doc.group document
  let row := match tokens.back? with
    | some token => Trivia.decorateTrailingBeforeBoundary ownership token.stx row
    | none => row
  Trivia.decorateBeforeBoundary ownership stx row

private partial def headerRowsFrom (ownership : CommentOwnership) (stx : Lean.Syntax)
    (rows : Array Doc) : Array Doc :=
  if stx.isOfKind ``Lean.Parser.Module.import then
    rows.push (importDocument ownership stx)
  else match stx with
    | .atom _ value =>
      if value == "module" || value == "prelude" then
        rows.push (Trivia.decorateBeforeBoundary ownership stx (Doc.text value))
      else rows
    | .node _ _ children =>
      children.foldl (init := rows) fun result child => headerRowsFrom ownership child result
    | _ => rows

private def headerDocument? (ownership : CommentOwnership) (stx : Lean.Syntax) : Option Doc :=
  if stx.isOfKind ``Lean.Parser.Module.header then
    let rows := headerRowsFrom ownership stx #[]
    let document? : Option Doc := rows.foldl (init := none) fun document? row =>
      some <| document?.map (· ++ Doc.hard ++ row) |>.getD row
    some (document?.getD Doc.empty)
  else none

/-- Format the parsed module/import header as one closed structural document. Import order, modifiers,
and exact-node comments remain those of the actual selected header syntax. -/
def header (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure RegisteredDocument) := do
  if let some document := headerDocument? ownership stx then
    let trace ← Formatter.trace ownership (.named ``Lean.Parser.Module.header) stx
    return .ok { document, trace }
  Formatter.registeredAs ownership (.named ``Lean.Parser.Module.header) stx stx.unsetTrailing

end Formatter.Command

end LeanFmt.Internal
