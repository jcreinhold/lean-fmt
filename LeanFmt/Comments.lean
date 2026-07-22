/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Deterministic comment ownership over actual source-covering syntax.

The parser stores comments in leaf `SourceInfo`, not as ordinary tree children. This module selects
the first spelling of every `choice`, scans each selected trivia region once, recognizes doc-comment
tokens separately, and assigns every payload to one leading, trailing, dangling, or file owner.
Ownership depends only on source positions, physical-line relation, and delimiter context; render
width never enters this module.

The assignment table is private. Formatter rules can ask for comments leading, trailing, or dangling
from the actual `Syntax` value they are rendering. -/

import Lean.Syntax
import all LeanFmt.LosslessSource

namespace LeanFmt.Internal

inductive CommentKind where
  | line
  | block
  | doc
  deriving Inhabited, BEq, DecidableEq, Repr

structure Comment where
  kind : CommentKind
  range : SourceRange
  suppressed : Bool := false
  deriving Inhabited, BEq, Repr

inductive CommentPlacement where
  | leading
  | trailing
  | dangling
  deriving Inhabited, BEq, DecidableEq, Repr

private structure Site where
  stx : Lean.Syntax
  range : SourceRange
  depth : Nat
  leaf : Bool
  spelling : String
  deriving Inhabited

private inductive Owner where
  | node (value : Lean.Syntax)
  | file

private structure Assignment where
  comment : Comment
  placement : CommentPlacement
  owner : Owner

/-- Width-independent ownership for one parsed module. Its table is deliberately private. -/
structure CommentOwnership where
  private assignments : Array Assignment
  private extracted : Array Comment

structure CommentSummary where
  comments : Nat
  leading : Nat
  trailing : Nat
  dangling : Nat
  suppressed : Nat
  payloadDigest : String
  valid : Bool
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

namespace Comments

private def sourceRange? (stx : Lean.Syntax) : Option SourceRange := do
  let range ← stx.getRange?
  return ⟨range.start.byteIdx, range.stop.byteIdx⟩

private def slice (bytes : ByteArray) (range : SourceRange) : String :=
  (String.fromUTF8? (bytes.extract range.start range.stop)).getD ""

private def isDocSpelling (value : String) : Bool :=
  value.startsWith "/--" || value.startsWith "/-!"

private def matchingDelimiters : String → String → Bool
  | "(", ")" | "[", "]" | "{", "}" | "⟨", "⟩" => true
  | _, _ => false

private def isClosing : String → Bool
  | ")" | "]" | "}" | "⟩" => true
  | _ => false

private def containsRange (outer inner : SourceRange) : Bool :=
  outer.start <= inner.start && inner.stop <= outer.stop

private partial def collectSitesFrom (bytes : ByteArray) (stx : Lean.Syntax) (depth : Nat)
    (sites : Array Site) (comments : Array Comment) : Array Site × Array Comment :=
  match stx with
  | .node _ kind args =>
    if kind == Lean.choiceKind then
      match args[0]? with
      | some selected => collectSitesFrom bytes selected depth sites comments
      | none => (sites, comments)
    else
      let sites := match sourceRange? stx with
        | some range => sites.push { stx, range, depth, leaf := false, spelling := "" }
        | none => sites
      args.foldl (init := (sites, comments)) fun (sites, comments) child =>
        collectSitesFrom bytes child (depth + 1) sites comments
  | .atom info _ | .ident info .. =>
    match sourceRange? stx with
    | none => (sites, comments)
    | some range =>
      let spelling := slice bytes range
      let sites := if isDocSpelling spelling then sites else
        sites.push { stx, range, depth, leaf := true, spelling }
      let comments := if isDocSpelling spelling then
          comments.push { kind := .doc, range }
        else comments
      collectTrivia bytes info sites comments
  | .missing => (sites, comments)
where
  collectTrivia (bytes : ByteArray) (info : Lean.SourceInfo) (sites : Array Site)
      (comments : Array Comment) : (Array Site × Array Comment) :=
    match info with
    | .original leading _ trailing _ =>
      (sites, scanTrivia bytes trailing (scanTrivia bytes leading comments))
    | _ => (sites, comments)

  scanTrivia (bytes : ByteArray) (trivia : Substring.Raw)
      (comments : Array Comment) : Array Comment := Id.run do
    let stop := min trivia.stopPos.byteIdx bytes.size
    let mut cursor := min trivia.startPos.byteIdx stop
    let mut result := comments
    while cursor < stop do
      if bytes[cursor]! == 0x2d && cursor + 1 < stop && bytes[cursor + 1]! == 0x2d then
        let start := cursor
        cursor := cursor + 2
        while cursor < stop && bytes[cursor]! != 0x0a do cursor := cursor + 1
        result := result.push { kind := .line, range := ⟨start, cursor⟩ }
      else if bytes[cursor]! == 0x2f && cursor + 1 < stop && bytes[cursor + 1]! == 0x2d then
        let start := cursor
        cursor := cursor + 2
        let mut nesting := 1
        while cursor + 1 < stop && nesting > 0 do
          if bytes[cursor]! == 0x2f && bytes[cursor + 1]! == 0x2d then
            nesting := nesting + 1
            cursor := cursor + 2
          else if bytes[cursor]! == 0x2d && bytes[cursor + 1]! == 0x2f then
            nesting := nesting - 1
            cursor := cursor + 2
          else
            cursor := cursor + 1
        result := result.push { kind := .block, range := ⟨start, cursor⟩ }
      else
        cursor := cursor + 1
    return result

private def collectSites (bytes : ByteArray) (roots : Array Lean.Syntax) : Array Site × Array Comment :=
  roots.foldl (init := (#[], #[])) fun (sites, comments) root =>
    collectSitesFrom bytes root 0 sites comments

private def commentOrder (left right : Comment) : Bool :=
  left.range.start < right.range.start ||
    (left.range.start == right.range.start && left.range.stop < right.range.stop)

private def siteOrder (left right : Site) : Bool :=
  left.range.start < right.range.start ||
    (left.range.start == right.range.start && left.range.stop < right.range.stop)

private def uniqueComments (comments : Array Comment) : Array Comment := Id.run do
  let mut result := #[]
  for comment in comments.qsort commentOrder do
    match result.back? with
    | some previous =>
      unless previous.kind == comment.kind && previous.range == comment.range do
        result := result.push comment
    | none => result := result.push comment
  return result

private def hasNewline (bytes : ByteArray) (start stop : Nat) : Bool := Id.run do
  let mut cursor := min start bytes.size
  let stop := min stop bytes.size
  while cursor < stop do
    if bytes[cursor]! == 0x0a then return true
    cursor := cursor + 1
  return false

private def suppressedBy (regions : Array SourceRange) (comment : Comment) : Comment :=
  { comment with suppressed := regions.any (containsRange · comment.range) }

private def enclosingDelimiter? (sites : Array Site) (left right : Site) : Option Site :=
  sites.foldl (init := none) fun selected site =>
    if site.leaf || !containsRange site.range ⟨left.range.start, right.range.stop⟩ then selected
    else match selected with
      | none => some site
      | some current =>
        if site.depth > current.depth ||
            (site.depth == current.depth && site.range.stop - site.range.start <
              current.range.stop - current.range.start) then some site else selected

private def syntaxOwner (site : Site) (placement : CommentPlacement) (comment : Comment) : Assignment :=
  { comment, placement, owner := .node site.stx }

private def assignWithNeighbors (bytes : ByteArray) (sites : Array Site) (comment : Comment)
    (previous following : Option Site) : Assignment :=
  match previous, following with
  | some left, some right =>
    if matchingDelimiters left.spelling right.spelling then
      match enclosingDelimiter? sites left right with
      | some container => syntaxOwner container .dangling comment
      | none => syntaxOwner right .leading comment
    else if !hasNewline bytes left.range.stop comment.range.start then
      syntaxOwner left .trailing comment
    else if isClosing right.spelling then
      match enclosingDelimiter? sites left right with
      | some container => syntaxOwner container .dangling comment
      | none => syntaxOwner right .leading comment
    else
      syntaxOwner right .leading comment
  | none, some right => syntaxOwner right .leading comment
  | some left, none =>
    if !hasNewline bytes left.range.stop comment.range.start then syntaxOwner left .trailing comment
    else { comment, placement := .dangling, owner := .file }
  | none, none => { comment, placement := .dangling, owner := .file }

/-- Merge source-sorted comments with source-sorted leaves. Each leaf cursor advances once; comment
ownership is linear except for the rare closing-delimiter query for the smallest enclosing node. -/
private def assignAll (bytes : ByteArray) (sites leaves : Array Site)
    (comments : Array Comment) : Array Assignment := Id.run do
  let mut assignments := #[]
  let mut previous : Option Site := none
  let mut leafIndex := 0
  for comment in comments do
    while leafIndex < leaves.size && leaves[leafIndex]!.range.stop <= comment.range.start do
      previous := some leaves[leafIndex]!
      leafIndex := leafIndex + 1
    let mut followingIndex := leafIndex
    while followingIndex < leaves.size && leaves[followingIndex]!.range.start < comment.range.stop do
      followingIndex := followingIndex + 1
    assignments := assignments.push <|
      assignWithNeighbors bytes sites comment previous leaves[followingIndex]?
  return assignments

/-- Build ownership from the actual parsed header, commands, and optional terminal command. -/
def build (normalized : String) (header : Lean.Syntax) (commands : Array Lean.Syntax)
    (terminal? : Option Lean.Syntax := none) (suppressed : Array SourceRange := #[]) :
    CommentOwnership :=
  let bytes := normalized.toUTF8
  let roots := #[header] ++ commands ++ terminal?.toArray
  let (sites, rawComments) := collectSites bytes roots
  -- A terminal command begins the verbatim tail. Its syntax remains an owner for comments immediately
  -- before it, but trivia after `#exit` is outside the parsed region and is not formatter input.
  let parsedStop := terminal?.bind sourceRange? |>.map (·.start) |>.getD bytes.size
  let rawComments := rawComments.filter (·.range.start < parsedStop)
  let sites := sites.qsort siteOrder
  let leaves := sites.filter (·.leaf)
  let extracted := (uniqueComments rawComments).map (suppressedBy suppressed)
  let assignments := assignAll bytes sites leaves extracted
  ⟨assignments, extracted⟩

private def sameSyntax (left right : Lean.Syntax) : Bool := left.eqWithInfo right

private def forSyntax (ownership : CommentOwnership) (stx : Lean.Syntax)
    (placement : CommentPlacement) : Array Comment :=
  ownership.assignments.filterMap fun assignment =>
    match assignment.owner with
    | .node owner =>
      if assignment.placement == placement && sameSyntax owner stx then some assignment.comment else none
    | .file => none

def leading (ownership : CommentOwnership) (stx : Lean.Syntax) : Array Comment :=
  forSyntax ownership stx .leading

def trailing (ownership : CommentOwnership) (stx : Lean.Syntax) : Array Comment :=
  forSyntax ownership stx .trailing

def dangling (ownership : CommentOwnership) (stx : Lean.Syntax) : Array Comment :=
  forSyntax ownership stx .dangling

def fileDangling (ownership : CommentOwnership) : Array Comment :=
  ownership.assignments.filterMap fun assignment =>
    match assignment.owner with
    | .file => some assignment.comment
    | .node _ => none

def all (ownership : CommentOwnership) : Array Comment := ownership.extracted

private def assignmentComments (ownership : CommentOwnership) : Array Comment :=
  ownership.assignments.map (·.comment)

/-- The table owns every extracted comment exactly once, in source order. -/
def valid (ownership : CommentOwnership) : Bool :=
  assignmentComments ownership == ownership.extracted

private def placementName : CommentPlacement → String
  | .leading => "L"
  | .trailing => "T"
  | .dangling => "D"

private def kindName : CommentKind → String
  | .line => "line"
  | .block => "block"
  | .doc => "doc"

/-- Counts and an exact payload/ownership digest suitable for process-boundary tests. -/
def summary (normalized : String) (ownership : CommentOwnership) : CommentSummary := Id.run do
  let bytes := normalized.toUTF8
  let mut leading := 0
  let mut trailing := 0
  let mut dangling := 0
  let mut suppressed := 0
  let mut digestInput := ""
  for assignment in ownership.assignments do
    match assignment.placement with
    | .leading => leading := leading + 1
    | .trailing => trailing := trailing + 1
    | .dangling => dangling := dangling + 1
    if assignment.comment.suppressed then suppressed := suppressed + 1
    let owner := match assignment.owner with
      | .file => "file"
      | .node stx =>
        match sourceRange? stx with
        | some range => s!"{stx.getKind}:{range.start}:{range.stop}"
        | none => s!"{stx.getKind}:none"
    digestInput := digestInput ++ s!"{kindName assignment.comment.kind}:\
{assignment.comment.range.start}:{assignment.comment.range.stop}:\
{placementName assignment.placement}:{owner}:" ++ slice bytes assignment.comment.range ++ "\n"
  return {
    comments := ownership.extracted.size
    leading
    trailing
    dangling
    suppressed
    payloadDigest := Digest.ofString digestInput |>.hex
    valid := valid ownership }

end Comments

end LeanFmt.Internal
