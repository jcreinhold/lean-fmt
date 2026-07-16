module

/- Where does a comment actually live?

`RLC-SPEC` has to say which token owns each comment, and the roadmap requires those rules be
"derived from the lossless source model" rather than invented. `RLS-SPEC` already established that
comments are not tree nodes: they live in the `leading` and `trailing` substrings of the token the
parser attached them to. That leaves exactly one question, and it decides the whole comment
contract:

    given `def x := 0  -- why` followed by a newline and `-- about y` and `def y := 1`,
    which token owns `-- why`, and which owns `-- about y`?

`Lean.Syntax.updateLeading` (`Lean/Syntax.lean:304`) is documented to answer it: it splits a token's
trailing at the first newline via `chooseNiceTrailStop`, "so that e.g. comments are associated to the
(intuitively) correct token". A grep of the 4.32 tree finds no caller. If it is really dead, the
parser's own record is `leading` empty everywhere and `trailing` greedy to the next token, and a
formatter must do the newline split itself.

This probe reports the raw `SourceInfo` substrings, so the answer is measured on the toolchain that
ships rather than read off a docstring. -/

import Lean

open Lean System

namespace LayoutCore.TriviaProbe

private structure Leaf where
  text : String
  leading : String
  trailing : String
  leadingStart : Nat
  pos : Nat
  endPos : Nat
  trailingStop : Nat
  deriving Inhabited

private def mkLeaf (info : SourceInfo) (text : String) : Option Leaf :=
  match info with
  | .original leading pos trailing endPos =>
    some {
      text
      leading := leading.toString
      trailing := trailing.toString
      leadingStart := leading.startPos.byteIdx
      pos := pos.byteIdx
      endPos := endPos.byteIdx
      trailingStop := trailing.stopPos.byteIdx }
  | _ => none

private partial def collect (leaves : Array Leaf) (stx : Syntax) : Array Leaf :=
  match stx with
  | .missing => leaves
  | .node _ _ args => args.foldl collect leaves
  | .atom info val => match mkLeaf info val with
    | some leaf => leaves.push leaf
    | none => leaves
  | .ident info rawVal _ _ => match mkLeaf info rawVal.toString with
    | some leaf => leaves.push leaf
    | none => leaves

private def escape (s : String) : String :=
  s.replace "\n" "\\n" |>.replace "\t" "\\t"

/-- Does this trivia run contain a comment opener outside a string? Trivia cannot contain a string,
so a bare scan is exact here. -/
private def hasComment (s : String) : Bool :=
  (s.splitOn "--").length > 1 || (s.splitOn "/-").length > 1

private def containsNewline (s : String) : Bool := s.any (· == '\n')

private unsafe def parseModule (source : String) (path : FilePath) : IO (Array Syntax) := do
  let input := Parser.mkInputContext source path.toString
  let (header, state, messages) ← Parser.parseHeader input
  if messages.hasErrors then
    throw <| IO.userError s!"header parse failed: {path}"
  let env ← importModules (Elab.headerToImports header) {} (trustLevel := 1024) (loadExts := true)
  let pmctx : Parser.ParserModuleContext := { env, options := {} }
  let mut stxs := #[header.raw]
  let mut state := state
  let mut messages := messages
  repeat
    let (stx, next, msgs) := Parser.parseCommand input pmctx state messages
    stxs := stxs.push stx
    state := next
    messages := msgs
    if Parser.isTerminalCommand stx then
      break
  if messages.hasErrors then
    for message in messages.toArray do
      IO.eprintln s!"  parse_error: {← message.toString}"
    throw <| IO.userError s!"command parse failed: {path}"
  return stxs

/-- Report every leaf whose trivia carries a comment, plus the two aggregate facts the contract turns
on: whether any `leading` is non-empty at all, and whether any `trailing` spans a newline. -/
unsafe def run (path : FilePath) : IO UInt32 := do
  initSearchPath (← findSysroot)
  -- `importModules (loadExts := true)` replays `[init]` code, which needs this and cannot run twice
  -- in one process against different module sets. One file per process is the contract.
  enableInitializersExecution
  let raw ← IO.FS.readFile path
  let stxs ← parseModule raw path
  let leaves := stxs.foldl collect #[]
  -- `LosslessSource.headerStop` is the first *command* leaf's leading start. With leading empty that
  -- is its `pos`, so everything before it — including any comment — is header text, and a module
  -- linter never receives it. Reported separately because it is a hole in the token stream, not a
  -- comment the layout engine can attach.
  let headerLeaves := (stxs.extract 0 1).foldl collect #[]
  let commandLeaves := (stxs.extract 1 stxs.size).foldl collect #[]
  let headerStop := match commandLeaves[0]? with
    | some leaf => leaf.leadingStart
    | none => 0
  let headerComments := headerLeaves.filter (fun l => hasComment l.leading || hasComment l.trailing)
  let nonEmptyLeading := leaves.filter (·.leading != "") |>.size
  let trailingWithNewline := leaves.filter (containsNewline ·.trailing) |>.size
  let leadingWithComment := leaves.filter (hasComment ·.leading) |>.size
  let trailingWithComment := leaves.filter (hasComment ·.trailing) |>.size
  IO.println s!"file={path}"
  IO.println s!"  leaves={leaves.size} nonempty_leading={nonEmptyLeading} \
trailing_spans_newline={trailingWithNewline}"
  IO.println s!"  comment_in_leading={leadingWithComment} comment_in_trailing={trailingWithComment}"
  IO.println s!"  header_leaves={headerLeaves.size} header_stop={headerStop} \
comment_bearing_header_leaves={headerComments.size} command_leaves={commandLeaves.size}"
  for leaf in leaves do
    if hasComment leaf.leading || hasComment leaf.trailing then
      IO.println s!"  token={repr leaf.text} span={leaf.pos}-{leaf.endPos}"
      IO.println s!"    leading={repr (escape leaf.leading)} \
trailing={repr (escape leaf.trailing)}"
  -- The contract-deciding summary. `updateLeading`'s split would put every comment that follows a
  -- newline into the *next* token's leading; without it, one token's trailing swallows the newline,
  -- the comment, and everything up to the next token.
  let verdict :=
    if nonEmptyLeading == 0 && trailingWithNewline > 0 then "trailing-greedy"
    else if nonEmptyLeading > 0 && trailingWithNewline == 0 then "newline-split"
    else "mixed"
  IO.println s!"  verdict={verdict}"
  return 0

end LayoutCore.TriviaProbe
