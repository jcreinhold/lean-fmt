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
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

structure Comment where
  kind : CommentKind
  range : SourceRange
  suppressed : Bool := false
  deriving Inhabited, BEq, Repr

inductive CommentPlacement where
  | leading
  | trailing
  | dangling
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

private structure Site where
  stx : Lean.Syntax
  range : SourceRange
  depth : Nat
  path : Array Nat
  leaf : Bool
  spelling : String
  deriving Inhabited

private inductive Owner where
  | node (value : Lean.Syntax) (path : Array Nat)
  | file

private structure Assignment where
  comment : Comment
  placement : CommentPlacement
  owner : Owner

/-- Width-independent ownership for one parsed module. Its table is deliberately private. -/
structure CommentOwnership where
  private assignments : Array Assignment
  private extracted : Array Comment
  private normalized : String

structure CommentSummary where
  comments : Nat
  leading : Nat
  trailing : Nat
  dangling : Nat
  suppressed : Nat
  payloadDigest : String
  valid : Bool
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

structure CommentContractEntry where
  kind : CommentKind
  placement : CommentPlacement
  ownerKind : String
  ownerPath : Array Nat
  payload : String
  suppressed : Bool
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
    (path : Array Nat)
    (sites : Array Site) (comments : Array Comment) : Array Site × Array Comment :=
  match stx with
  | .node _ kind args =>
    if kind == Lean.choiceKind then
      match args[0]? with
      | some selected => collectSitesFrom bytes selected depth (path.push 0) sites comments
      | none => (sites, comments)
    else
      let sites := match sourceRange? stx with
        | some range => sites.push { stx, range, depth, path, leaf := false, spelling := "" }
        | none => sites
      let (sites, comments, _) := args.foldl (init := (sites, comments, 0))
        fun (sites, comments, index) child =>
          let (sites, comments) := collectSitesFrom bytes child (depth + 1)
            (path.push index) sites comments
          (sites, comments, index + 1)
      (sites, comments)
  | .atom info _ | .ident info .. =>
    match sourceRange? stx with
    | none => (sites, comments)
    | some range =>
      let spelling := slice bytes range
      -- Zero-width parser sentinels (notably end-of-input) do not spell source and therefore cannot
      -- own source trivia. Keeping one as the following leaf turns a final comment into leading
      -- trivia of an unrenderable node instead of file-dangling trivia.
      let sites := if spelling.isEmpty || isDocSpelling spelling then sites else
        sites.push { stx, range, depth, path, leaf := true, spelling }
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
  let (sites, comments, _) := roots.foldl (init := (#[], #[], 0))
    fun (sites, comments, index) root =>
      let (sites, comments) := collectSitesFrom bytes root 0 #[index] sites comments
      (sites, comments, index + 1)
  (sites, comments)

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

/- The column a byte offset sits at, counted from the last newline before it.

Bytes, not codepoints: the only comparison this feeds is between two columns on two lines of the same
file, and the two disagree only if the indentation before one of them holds a multi-byte character.
Indentation is whitespace, so it cannot. -/
private def columnOf (bytes : ByteArray) (offset : Nat) : Nat := Id.run do
  let offset := min offset bytes.size
  let mut cursor := offset
  while cursor > 0 do
    if bytes[cursor - 1]! == 0x0a then return offset - cursor
    cursor := cursor - 1
  return offset

/- The statement a comment lines up under, when the comment is indented past the token after it.

This is the whole of the offside case. A comment on its own line, indented strictly deeper than the
token that follows it, cannot be that token's leading trivia in any layout that keeps the source's
block structure -- the block it sits in closed before that token, and it closed *after* the comment.
`assignWithNeighbors` would otherwise hand it to the following token and the formatter would render it
at that token's column, outside the block it was written in.

The owner is the innermost node that ends where the token before the comment ends and *starts at
exactly the comment's column*. Ending there is what makes it a construct the comment sits at the end
of; starting at the comment's column is what makes the comment a member of the same item list rather
than something indented arbitrarily. Both are byte-level facts about lines, and neither names a
syntax kind.

Equality rather than `<=` on the column is deliberate and is what keeps the rule narrow. A comment
indented deeper than every enclosing block's items -- say two spaces inside a `namespace` whose
commands are at column zero -- selects nothing here and keeps the leading-trivia assignment it has
always had. Widening it to `<=` selects the command root instead, which is a block the adapter has no
break to attach to. -/
private def enclosingBlock? (bytes : ByteArray) (sites : Array Site) (left : Site)
    (comment : Comment) : Option Site :=
  let column := columnOf bytes comment.range.start
  sites.foldl (init := none) fun selected site =>
    if site.leaf || site.range.stop != left.range.stop ||
        columnOf bytes site.range.start != column then selected
    else match selected with
      | none => some site
      | some current => if site.depth > current.depth then some site else selected

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
  { comment, placement, owner := .node site.stx site.path }

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
    else if columnOf bytes right.range.start < columnOf bytes comment.range.start then
      match enclosingBlock? bytes sites left comment with
      | some block => syntaxOwner block .dangling comment
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
  ⟨assignments, extracted, normalized⟩

private def sameSyntax (left right : Lean.Syntax) : Bool := left.eqWithInfo right

private def forSyntax (ownership : CommentOwnership) (stx : Lean.Syntax)
    (placement : CommentPlacement) : Array Comment :=
  ownership.assignments.filterMap fun assignment =>
    match assignment.owner with
    | .node owner _ =>
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
    | .node _ _ => none

def all (ownership : CommentOwnership) : Array Comment := ownership.extracted

/-- Exact normalized-source bytes of an owned comment. -/
def payload (ownership : CommentOwnership) (comment : Comment) : String :=
  slice ownership.normalized.toUTF8 comment.range

/-- Whether normalized source contains a line break between two byte offsets. -/
def hasNewlineBetween (ownership : CommentOwnership) (start stop : Nat) : Bool :=
  hasNewline ownership.normalized.toUTF8 start stop

/-- Whether normalized source put a blank line between two byte offsets.

Two line breaks with nothing but horizontal whitespace between them. This is the one vertical fact a
comment's own bytes cannot carry and the structural command stream cannot supply either: `place`
decides spacing *between commands* from their roles, and a comment leading a command is inside that
command's unit, so the gap between a copyright block and the `module` it precedes belongs to neither.
Anything other than whitespace between the breaks means the caller asked about a range containing
another token, and the answer is no. -/
def hasBlankLineBetween (ownership : CommentOwnership) (start stop : Nat) : Bool := Id.run do
  let bytes := ownership.normalized.toUTF8
  let mut cursor := min start bytes.size
  let stop := min stop bytes.size
  let mut breaks := 0
  while cursor < stop do
    let byte := bytes[cursor]!
    if byte == 0x0a then
      breaks := breaks + 1
      if breaks >= 2 then return true
    else if byte != 0x20 && byte != 0x09 && byte != 0x0d then
      return false
    cursor := cursor + 1
  return false

/-- Comments logically owned by the node itself or one of its selected source-covering descendants.
Lean may physically store boundary trivia on an adjacent token, so this is an ownership count, not a
claim that one isolated registered document emits those same comments. -/
def subtree (ownership : CommentOwnership) (stx : Lean.Syntax) : Array Comment :=
  match sourceRange? stx with
  | none => #[]
  | some root => ownership.assignments.filterMap fun assignment =>
    match assignment.owner with
    | .file => none
    | .node owner _ =>
      match sourceRange? owner with
      | some range => if containsRange root range then some assignment.comment else none
      | none => if sameSyntax owner stx then some assignment.comment else none

/-- Comments a block inside this subtree owns that lie *after* that block's own last token, each with
the owning block's range.

Every other accessor here answers "which comments does this subtree own", which is all a renderer needs
when the comment sits between two of the subtree's tokens: the boundary it belongs at is between them.
A comment dangling at the end of a block is the one placement where it is not — the block closed, so
the comment is past every token the subtree spells, and the renderer has to be told *which* block ended
in order to put it back at that block's indentation rather than at the subtree's. -/
def blockDangling (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Array (SourceRange × Comment) :=
  match sourceRange? stx with
  | none => #[]
  | some root => ownership.assignments.filterMap fun assignment =>
    if assignment.placement != .dangling then none else
    match assignment.owner with
    | .file => none
    | .node owner _ =>
      match sourceRange? owner with
      | some range =>
        if containsRange root range && range.stop <= assignment.comment.range.start then
          some (range, assignment.comment)
        else none
      | none => none

/-- Comments in a syntax subtree with one requested logical placement. -/
def subtreeAt (ownership : CommentOwnership) (stx : Lean.Syntax)
    (placement : CommentPlacement) : Array Comment :=
  match sourceRange? stx with
  | none => #[]
  | some root => ownership.assignments.filterMap fun assignment =>
    if assignment.placement != placement then none else
    match assignment.owner with
    | .file => none
    | .node owner _ =>
      match sourceRange? owner with
      | some range => if containsRange root range then some assignment.comment else none
      | none => if sameSyntax owner stx then some assignment.comment else none

/-- Stable validation input: exact payload and logical owner path, excluding source positions that
layout necessarily changes. -/
def contract (normalized : String) (ownership : CommentOwnership) : Array CommentContractEntry :=
  let bytes := normalized.toUTF8
  ownership.assignments.map fun assignment =>
    let (ownerKind, ownerPath) := match assignment.owner with
      | .file => ("file", #[])
      | .node stx path => (stx.getKind.toString, path)
    {
      kind := assignment.comment.kind
      placement := assignment.placement
      ownerKind
      ownerPath
      payload := slice bytes assignment.comment.range
      suppressed := assignment.comment.suppressed }

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
      | .node stx _ =>
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
