/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Formatter-only trivia policy.

Rule suppression remains in `LeanFmt.Suppression`. The one formatter directive is recognized only as an
exact line-comment payload leading a complete ordinary command; mid-expression, trailing, doc, and
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

/- Join a run of comments that lead something, preserving a blank line the source put between two of
them.

A blank line is a source fact nothing else in the pipeline supplies: `Command.place` decides the
boundary *between* commands from their roles, and these comments sit inside one command's unit. So the
gap between a copyright block and the `module` it precedes is owned by neither and was simply dropped.
Every file in a Lean project has one. -/
private def joinLeading (ownership : CommentOwnership) (comments : Array Comment) : Option Doc :=
  (comments.foldl (init := (none, none)) fun (document?, cursor) comment =>
    let next := match document?, cursor with
      | some document, some cursor =>
        let boundary := if Comments.hasBlankLineBetween ownership cursor comment.range.start then
            Doc.blank
          else Doc.hard
        document ++ boundary ++ commentDocument ownership comment
      | _, _ => commentDocument ownership comment
    (some next, some comment.range.stop)).1

/- The boundary between a leading run and the thing it leads. The callers below emit that boundary
themselves, so they have to ask for it rather than be handed it. -/
private def ownerBoundary (ownership : CommentOwnership) (comments : Array Comment)
    (stx : Lean.Syntax) : Doc :=
  match comments.back?, stx.getRange?.map (·.start.byteIdx) with
  | some last, some start =>
    if Comments.hasBlankLineBetween ownership last.range.stop start then Doc.blank else Doc.hard
  | _, _ => Doc.hard

/- Comments that lead the *complete command*, whichever adjacent token physically stores their trivia.
`Comments.leading` answers the narrower question about one exact node.

A `doc`-kind comment is never one of them. Lean stores a docstring's opening token in the following
token's `SourceInfo`, so comment ownership sees it leading that token — but the docstring is *command
syntax*, and the command's own structural document is its sole emitter. Emitting it here too duplicates
that opening and makes the candidate an unterminated nested comment.

The range filter alone almost does this — a docstring the command owns starts exactly where the
command starts, so `stop <= start` is false for it — but "almost" is no guarantee to rest a duplication
hazard on. `Analysis` used to guard the same hazard by dropping the command's *entire* leading trivia
whenever it contained doc syntax, which also dropped every ordinary comment above the docstring; that
is the defect this replaces. Excluding by kind is the rule that was meant, stated once, here, where the
comments are selected. -/
private def commandLeading (ownership : CommentOwnership) (stx : Lean.Syntax) : Array Comment :=
  let start := stx.getRange?.map (·.start.byteIdx) |>.getD 0
  Comments.subtreeAt ownership stx .leading |>.filter fun comment =>
    comment.kind != .doc && comment.range.stop <= start

private def exactLeading (ownership : CommentOwnership) (stx : Lean.Syntax) : Option Doc :=
  joinLeading ownership (Comments.leading ownership stx)

private def exactLeadingBoundary (ownership : CommentOwnership) (stx : Lean.Syntax) : Doc :=
  ownerBoundary ownership (Comments.leading ownership stx) stx

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
    | some comments => comments ++ exactLeadingBoundary ownership stx ++ document
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
  | some comments => comments ++ exactLeadingBoundary ownership stx ++ document
  | none => document

/-- Add only comments trailing this exact node when the enclosing structural owner supplies the next
hard boundary: the command-internal counterpart of `decorateLeading`. -/
def decorateTrailingBeforeBoundary (ownership : CommentOwnership) (stx : Lean.Syntax)
    (document : Doc) : Doc :=
  match exactTrailing ownership stx (terminateLine := false) with
  | some comments => document ++ comments
  | none => document

/-- Add exact-node comments when the enclosing structural owner already supplies the following hard
boundary. A trailing line comment must end the current row, but emitting that boundary twice would
invent a blank line. Kept separate from `decorate` on purpose: inline term composition still needs the
comment itself to force the break. -/
def decorateBeforeBoundary (ownership : CommentOwnership) (stx : Lean.Syntax)
    (document : Doc) : Doc :=
  let document := match exactLeading ownership stx with
    | some comments => comments ++ exactLeadingBoundary ownership stx ++ document
    | none => document
  match exactTrailing ownership stx (terminateLine := false) with
  | some comments => document ++ comments
  | none => document

/-- Add every logical comment below an opaque structural leaf. Descriptor-backed extensions have no
recursive formatter callbacks, so this is their exact-once comment path. -/
def decorateSubtree (ownership : CommentOwnership) (stx : Lean.Syntax) (document : Doc) : Doc :=
  let leading := Comments.subtreeAt ownership stx .leading
  let trailing := Comments.subtreeAt ownership stx .trailing
  let document := leading.foldr (init := document) fun comment result =>
    commentDocument ownership comment ++ Doc.hard ++ result
  trailing.foldl (init := document) fun result comment =>
    result ++ Doc.text " " ++ commentDocument ownership comment ++
      (if comment.kind == .line then Doc.hard else Doc.empty)

def decorateSubtreeTrailingAfter (ownership : CommentOwnership) (owner included : Lean.Syntax)
    (document : Doc) : Doc :=
  let includedStop? := included.getRange?.map (·.stop.byteIdx)
  Comments.subtreeAt ownership owner .trailing |>.filter (fun comment =>
    includedStop?.any (· <= comment.range.start)) |>.foldl
      (init := document) fun result comment =>
    result ++ Doc.text " " ++ commentDocument ownership comment ++
      (if comment.kind == .line then Doc.hard else Doc.empty)

/-- Comments logically leading the complete command, independent of which adjacent token physically
stores their trivia. A blank line between two of them is preserved; see `joinLeading`. -/
def leading (ownership : CommentOwnership) (stx : Lean.Syntax) : Option Doc :=
  joinLeading ownership (commandLeading ownership stx)

/-- The boundary between the comments `leading` returns and the command itself. Module composition
emits that boundary, so it has to ask rather than be handed it. -/
def leadingBoundary (ownership : CommentOwnership) (stx : Lean.Syntax) : Doc :=
  ownerBoundary ownership (commandLeading ownership stx) stx

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

/-- Comments after the final selected syntax leaf: they belong to the module boundary, not to an
invented trailing child of the last command. -/
def fileDangling (ownership : CommentOwnership) : Option Doc :=
  Comments.fileDangling ownership |>.foldl (init := none) fun document? comment =>
    some <| match document? with
      | some document => document ++ Doc.hard ++ commentDocument ownership comment
      | none => commentDocument ownership comment

end LeanFmt.Internal.Formatter.Trivia
