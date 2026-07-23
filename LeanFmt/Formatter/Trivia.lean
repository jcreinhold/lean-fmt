/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Formatter-only trivia policy.

Rule suppression remains in `LeanFmt.Suppression`. The one formatter directive is recognized only as
an exact line-comment payload leading a complete ordinary command. Mid-expression, trailing, doc, and
block comments cannot select a formatting unit. -/

import all LeanFmt.Comments
import all LeanFmt.Doc

namespace LeanFmt.Internal.Formatter.Trivia

def formatIgnoreNextText : String := "-- lean-fmt: format-ignore-next"

/-- Exact slice selected by a formatter directive leading this complete command. Outer blank padding
is not part of the unit; the module composer supplies that canonical boundary. -/
def formatIgnoreNext? (ownership : CommentOwnership) (stx : Lean.Syntax) : Option SourceRange := do
  let start := stx.getRange?.map (·.start.byteIdx) |>.getD 0
  let comments := Comments.subtree ownership stx
  let directive ← comments.find? fun comment =>
    comment.kind == .line && comment.range.stop <= start &&
      (Comments.payload ownership comment).trimAscii == formatIgnoreNextText
  let syntaxStop := stx.getRange?.map (·.stop.byteIdx) |>.getD start
  let stop := comments.foldl (init := syntaxStop) fun stop comment => max stop comment.range.stop
  return ⟨directive.range.start, stop⟩

private def commentDocument (ownership : CommentOwnership) (comment : Comment) : Doc :=
  let payload := Comments.payload ownership comment
  if payload.contains '\n' then Doc.verbatim payload else Doc.text payload

private def exactLeading (ownership : CommentOwnership) (stx : Lean.Syntax) : Option Doc :=
  Comments.leading ownership stx |>.foldl (init := none) fun document? comment =>
    some <| match document? with
      | some document => document ++ Doc.hard ++ commentDocument ownership comment
      | none => commentDocument ownership comment

private def exactTrailing (ownership : CommentOwnership) (stx : Lean.Syntax)
    (terminateLine : Bool := true) : Option Doc :=
  Comments.trailing ownership stx |>.foldl (init := none) fun document? comment =>
    let next := Doc.text " " ++ commentDocument ownership comment ++
      (if terminateLine && comment.kind == .line then Doc.hard else Doc.empty)
    some <| document?.map (· ++ next) |>.getD next

/-- Add comments logically owned by exactly this structural node. Descendant documents add their own
comments recursively; opaque registry leaves are never decorated because their native formatter is
already the sole emitter for that subtree. -/
def decorate (ownership : CommentOwnership) (stx : Lean.Syntax) (document : Doc) : Doc :=
  let document := match exactLeading ownership stx with
    | some comments => comments ++ Doc.hard ++ document
    | none => document
  match exactTrailing ownership stx with
  | some comments => document ++ comments
  | none => document

/-- Add only comments trailing this exact node. Recursive structural child callbacks use this form;
their parent owns comments that lead a nested child and establishes the correct offside base. -/
def decorateTrailing (ownership : CommentOwnership) (stx : Lean.Syntax) (document : Doc) : Doc :=
  match exactTrailing ownership stx with
  | some comments => document ++ comments
  | none => document

/-- Add only comments leading this exact node. Command composition owns trivia physically following
the command boundary, so the final token of a structural command uses this form and cannot emit that
same payload a second time. -/
def decorateLeading (ownership : CommentOwnership) (stx : Lean.Syntax) (document : Doc) : Doc :=
  match exactLeading ownership stx with
  | some comments => comments ++ Doc.hard ++ document
  | none => document

/-- Add only comments trailing this exact node when the enclosing structural owner supplies the next
hard boundary. This is the command-internal counterpart of `decorateLeading`. -/
def decorateTrailingBeforeBoundary (ownership : CommentOwnership) (stx : Lean.Syntax)
    (document : Doc) : Doc :=
  match exactTrailing ownership stx (terminateLine := false) with
  | some comments => document ++ comments
  | none => document

/-- Add exact-node comments when the enclosing structural owner already supplies the following hard
boundary. A trailing line comment must end the current row, but emitting that boundary twice would
invent a blank line. This is intentionally separate from `decorate`: inline term composition still
needs the comment itself to force the break. -/
def decorateBeforeBoundary (ownership : CommentOwnership) (stx : Lean.Syntax)
    (document : Doc) : Doc :=
  let document := match exactLeading ownership stx with
    | some comments => comments ++ Doc.hard ++ document
    | none => document
  match exactTrailing ownership stx (terminateLine := false) with
  | some comments => document ++ comments
  | none => document

/-- Comments logically leading the complete command, independent of which adjacent token physically
stores their trivia. -/
def leading (ownership : CommentOwnership) (stx : Lean.Syntax) : Option Doc :=
  let start := stx.getRange?.map (·.start.byteIdx) |>.getD 0
  let comments := Comments.subtreeAt ownership stx .leading |>.filter (·.range.stop <= start)
  comments.foldl (init := none) fun document? comment =>
    some <| match document? with
      | some document => document ++ Doc.hard ++ commentDocument ownership comment
      | none => commentDocument ownership comment

/-- Comments logically trailing the complete command and physically before its unit boundary.
Comments assigned as leading trivia of the next command are emitted there, never duplicated here. -/
def trailing (ownership : CommentOwnership) (stx : Lean.Syntax) (boundaryStop : Nat) : Option Doc :=
  let stop := stx.getRange?.map (·.stop.byteIdx) |>.getD 0
  let comments := Comments.subtreeAt ownership stx .trailing |>.filter fun comment =>
    comment.range.start >= stop && comment.range.start < boundaryStop
  let (document?, _) := comments.foldl (init := (none, stop)) fun (document?, cursor) comment =>
    let boundary := if Comments.hasNewlineBetween ownership cursor comment.range.start then
        Doc.hard
      else Doc.text " "
    let next := boundary ++ commentDocument ownership comment
    (some <| document?.map (· ++ next) |>.getD next, comment.range.stop)
  document?

/-- Comments after the final selected syntax leaf. They belong to the module boundary, not to an
invented trailing child of the last command. -/
def fileDangling (ownership : CommentOwnership) : Option Doc :=
  Comments.fileDangling ownership |>.foldl (init := none) fun document? comment =>
    some <| match document? with
      | some document => document ++ Doc.hard ++ commentDocument ownership comment
      | none => commentDocument ownership comment

end LeanFmt.Internal.Formatter.Trivia
