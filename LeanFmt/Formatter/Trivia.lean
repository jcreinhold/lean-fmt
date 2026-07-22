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

/-- Comments logically leading the complete command, independent of which adjacent token physically
stores their trivia. -/
def leading (ownership : CommentOwnership) (stx : Lean.Syntax) : Option Doc :=
  let start := stx.getRange?.map (·.start.byteIdx) |>.getD 0
  let comments := Comments.subtreeAt ownership stx .leading |>.filter (·.range.stop <= start)
  comments.foldl (init := none) fun document? comment =>
    some <| match document? with
      | some document => document ++ Doc.hard ++ commentDocument ownership comment
      | none => commentDocument ownership comment

/-- Comments physically following the complete command. Lean can logically attach an end-of-file
line comment as `leading` trivia of a synthetic descendant, so the source boundary, rather than the
logical placement tag, decides this outer case. Interior comments remain in registry-owned syntax. -/
def trailing (ownership : CommentOwnership) (stx : Lean.Syntax) (boundaryStop : Nat) : Option Doc :=
  let stop := stx.getRange?.map (·.stop.byteIdx) |>.getD 0
  let comments := Comments.all ownership |>.filter fun comment =>
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
