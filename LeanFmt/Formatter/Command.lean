/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.Formatter
import all LeanFmt.Formatter.Trivia

import Lean.Parser.Module

/-! Module-stream composition: the header document, the header contract, and the vertical boundary
between two ordinary commands.

Every ordinary command's layout belongs to `LeanFmt.Formatter.NativeLayout`, which drives Lean's own
registered formatter. This module owns only what sits *between* those documents, plus the one command
Lean's registry cannot supply: the module header, parsed before any environment exists.

The header is the one place lean-fmt still spells tokens itself. `Lean.Parser.Module.header` is
`optional module >> optional prelude >> many import`, and `import` is
`optional public >> optional meta >> "import " >> optional all >> ident`. That closed token set has no
delimiter, no projection dot, and no antiquotation, so the separator between two adjacent header tokens
is always one space — which is why this module carries no spacing table. `headerDocument?` refuses
anything that is not a header node and falls back to the registry.

Vertical spacing between header rows is the one layout fact the source already got right: the
organizer owns header structure (its grouped and canonical layouts both blank-line the bucket
boundaries), so the formatter preserves a blank line where the source has one and collapses a run
to one, rather than forcing every row tight. Import order remains the source's — organizing is a
separate, validated command.

`place` decides blank lines between commands, not indentation: top-level commands stay at column zero
even inside a namespace, so indentation is a command's own business. -/

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

def sequence : CommandSequence :=
  { }

private def role (stx : Lean.Syntax) : CommandRole :=
  if stx.isOfKind ``Lean.Parser.Command.namespace || stx.isOfKind ``Lean.Parser.Command.section then
    .scopeOpen
  else
    if stx.isOfKind ``Lean.Parser.Command.end then .scopeClose
    else
      if
          stx.isOfKind ``Lean.Parser.Command.open || stx.isOfKind ``Lean.Parser.Command.export ||
                stx.isOfKind ``Lean.Parser.Command.universe ||
              stx.isOfKind ``Lean.Parser.Command.variable ||
            stx.isOfKind ``Lean.Parser.Command.set_option then
        .setup
      else .declaration

private def separated (previous current : CommandRole) : Bool :=
  match previous, current with
  | .setup, .setup => false
  | .scopeOpen, .scopeClose => false
  | _, _ => true

/-- Advance the structural module stream and return its vertical boundary. Top-level commands stay at
column zero even inside namespaces and sections; indentation belongs to command internals. -/
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
inside carry only the comments physically between them; a line comment there forces a break, since
everything after it on that line would otherwise be commented out. The tokens themselves are joined
with unbreakable spaces: an import row cannot be shortened, so a break would only stack
`public`/`import`/the module name vertically while the row still overflowed — mathlib's longLine
linter exempts whole import lines (`isImport`) precisely because they must stay whole. -/
private def importDocument (ownership : CommentOwnership) (stx : Lean.Syntax) : Doc :=
  Id.run do
    let tokens := headerTokens stx
    let some first := tokens[0]? | return Doc.empty
    let tokenText := fun (token : HeaderToken) => Doc.text token.spelling
    let mut document :=
      if tokens.size == 1 then tokenText first
      else Trivia.decorateTrailingBeforeBoundary ownership first.stx (tokenText first)
    for index in [1:tokens.size]do
      let previous := tokens[index - 1]!
      let token := tokens[index]!
      let boundary :=
        if
            hasTrailingLine ownership previous.stx ||
              !(Comments.leading ownership token.stx).isEmpty then
          Doc.hard
        else Doc.text " "
      let tokenDocument :=
        if index + 1 == tokens.size then
          Trivia.decorateLeading ownership token.stx (tokenText token)
        else Trivia.decorateBeforeBoundary ownership token.stx (tokenText token)
      document := document ++ boundary ++ tokenDocument
    let row :=
      match tokens[0]? with
      | some token => Trivia.decorateLeading ownership token.stx (Doc.group document)
      | none => Doc.group document
    let row :=
      match tokens.back? with
      | some token => Trivia.decorateTrailingBeforeBoundary ownership token.stx row
      | none => row
    Trivia.decorateBeforeBoundary ownership stx row

private partial def headerRowsFrom (ownership : CommentOwnership) (stx : Lean.Syntax)
    (rows : Array (Lean.Syntax × Doc)) : Array (Lean.Syntax × Doc) :=
  if stx.isOfKind ``Lean.Parser.Module.import then rows.push (stx, importDocument ownership stx)
  else
    match stx with
    | .atom _ value =>
      if value == "module" || value == "prelude" then
        rows.push (stx, Trivia.decorateBeforeBoundary ownership stx (Doc.text value))
      else rows
    | .node _ _ children =>
      children.foldl (init := rows) fun result child => headerRowsFrom ownership child result
    | _ => rows

/-- The trailing trivia of the row's last leaf. The lexer assigns the whole gap between two rows
to the previous token's trailing — leadings are empty — so that trivia is the only record of
whether a blank line stood there. -/
private partial def trailingText? (stx : Lean.Syntax) : Option String :=
  match stx with
  | .atom info _ | .ident info _ _ _ =>
    match info with
    | .original _ _ trailing _ => some trailing.toString
    | _ => none
  | .node _ kind children =>
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.reverse.findSome? trailingText?
  | .missing => none

/-- Whether a whitespace-only line stands in trailing trivia. A run of blank lines reads as one
boundary — the document emits at most one blank line, however many the source holds. -/
private def blankLineAfter (trailing : String) : Bool :=
  let lines := trailing.splitOn "\n"
  -- The first line finishes the row's own line and the last precedes the next row's first token;
  -- a whitespace-only line between them is a blank line. Single-`\n` trivia has neither.
  (lines.tail?.getD []).dropLast.any fun line => line.trimAscii.isEmpty

private def headerDocument? (ownership : CommentOwnership) (stx : Lean.Syntax) : Option Doc :=
  if stx.isOfKind ``Lean.Parser.Module.header then
    let rows := headerRowsFrom ownership stx #[]
    let document? : Option (Lean.Syntax × Doc) :=
      rows.foldl (init := none) fun acc (rowStx, row) =>
        match acc with
        | none => some (rowStx, row)
        | some (previousStx, document) =>
          let separator :=
            if (trailingText? previousStx).any blankLineAfter then Doc.hard ++ Doc.hard
            else Doc.hard
          some (rowStx, document ++ separator ++ row)
    some (document?.map (·.2) |>.getD Doc.empty)
  else none

/-- Format the parsed module/import header as one closed structural document. Import order, modifiers,
and exact-node comments remain those of the selected header syntax. -/
def header (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure RegisteredDocument) := do
  if let some document := headerDocument? ownership stx then
    let trace ← Formatter.trace ownership (.named ``Lean.Parser.Module.header) stx
    return .ok { document, trace }
  Formatter.registeredAs ownership (.named ``Lean.Parser.Module.header) stx stx.unsetTrailing

end Formatter.Command

end LeanFmt.Internal
