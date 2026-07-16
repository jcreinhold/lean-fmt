module

/- The immutable lossless projection of one accepted Lean module and its codec.

Every offset in this module indexes the *normalized* source: `raw.crlfToLf`, which is the string
`Lean.Parser.mkInputContext` actually parses. No offset the compiler produces indexes the bytes on
disk. `LosslessSource.ofSource` is the only supported way to obtain both forms together, so a caller
cannot accidentally mix them.

The design comparison behind this shape is `docs/projects/ruff-01-lossless-source/notes/
02-projection-interface.md`; the measured parser facts it relies on are in `01-source-authority.md`.
-/

import all LeanFmt.Digest
import Lean

namespace LeanFmt.Internal

/-- Half-open UTF-8 byte range in the normalized source. -/
structure SourceRange where
  start : Nat
  stop : Nat
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- The line-ending form observed on disk.

Lean rejects isolated `\r`, so an accepted file's endings are uniformly one form or the other; a
mixed file is not accepted source. This is deliberately *not* part of `LosslessSource`: only a
producer holding the file's bytes can observe it, and the compiler plugin never does. It belongs to
whoever read the file, and it is what that reader needs in order to write one back. -/
inductive LineEndings where
  | lf
  | crlf
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- Trivia is exactly what `Lean.Parser.whitespace` consumes. Doc comments are absent on purpose:
`Lean/Parser/Basic.lean:584` records that doc-comment and module-doc openers are real tokens, so
they arrive as syntax nodes and are distinguished by kind. -/
inductive TriviaKind where
  | whitespace
  | lineComment
  | blockComment
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- One trivia run. Runs tile their enclosing trivia span in order, so only the stop is stored. -/
structure Trivia where
  kind : TriviaKind
  stop : Nat
  deriving Inhabited, BEq, DecidableEq, Repr

/-- How the parser recorded a leaf. Parsed command syntax is `original` throughout; the other two
are carried so a future producer cannot silently smuggle in fabricated positions. -/
inductive LeafInfo where
  | original
  | synthetic
  | missing
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- A parser leaf together with the trivia the parser attached to it.

`leading` tiles `[previous token's trailing stop, start)`, where the first token's predecessor is
`LosslessSource.headerStop`. `trailing` tiles `[stop, next token's leading start)`. No leading start
is stored: contiguity determines it, and storing it would allow the two to disagree. -/
structure Token where
  node : Nat
  leading : Array Trivia := #[]
  start : Nat
  stop : Nat
  trailing : Array Trivia := #[]
  info : LeafInfo := .original
  deriving Inhabited, BEq, Repr

/-- Where this token's trailing trivia ends, i.e. where the next token's leading trivia begins. -/
def Token.trailingStop (token : Token) : Nat :=
  match token.trailing.back? with
  | none => token.stop
  | some trivia => trivia.stop

/-- An interior syntax node. `kind` indexes `LosslessSource.kinds`; `parent` is `none` for a command
root. This is the parent/child structure the roadmap requires, carried without exposing
`Lean.Syntax` to callers. -/
structure Node where
  kind : Nat
  parent : Option Nat := none
  range : SourceRange
  deriving Inhabited, BEq, Repr

/-! ## Wire format

`Trivia`, `Token`, and `Node` are the only things in an artifact whose count grows with the file, so
they are the only things whose encoding matters. Derived field-name objects cost more than the
source they describe — measured at 12.2x on the local-syntax fixture, where `{"kind":"whitespace",
"stop":4}` spends 24 of its 29 bytes restating the schema. Each is written as a fixed-shape array
instead. The decoders below are total and reject anything that is not exactly that shape; a
projection that fails to decode is an ordinary miss. -/

private def TriviaKind.toIndex : TriviaKind → Nat
  | .whitespace => 0
  | .lineComment => 1
  | .blockComment => 2

private def TriviaKind.ofIndex? : Nat → Option TriviaKind
  | 0 => some .whitespace
  | 1 => some .lineComment
  | 2 => some .blockComment
  | _ => none

private def LeafInfo.toIndex : LeafInfo → Nat
  | .original => 0
  | .synthetic => 1
  | .missing => 2

private def LeafInfo.ofIndex? : Nat → Option LeafInfo
  | 0 => some .original
  | 1 => some .synthetic
  | 2 => some .missing
  | _ => none

private def fields (json : Lean.Json) (size : Nat) : Except String (Array Lean.Json) := do
  let array ← json.getArr?
  unless array.size == size do
    throw s!"expected {size} fields, got {array.size}"
  return array

private def natAt (array : Array Lean.Json) (index : Nat) : Except String Nat := do
  let some json := array[index]? | throw s!"missing field {index}"
  Lean.fromJson? json

instance : Lean.ToJson Trivia where
  toJson trivia := Lean.toJson (trivia.kind.toIndex, trivia.stop)

instance : Lean.FromJson Trivia where
  fromJson? json := do
    let array ← fields json 2
    let some kind := TriviaKind.ofIndex? (← natAt array 0) | throw "unknown trivia kind"
    return { kind, stop := ← natAt array 1 }

instance : Lean.ToJson Token where
  toJson token := .arr #[
    Lean.toJson token.node, Lean.toJson token.start, Lean.toJson token.stop,
    Lean.toJson token.info.toIndex, Lean.toJson token.leading, Lean.toJson token.trailing]

instance : Lean.FromJson Token where
  fromJson? json := do
    let array ← fields json 6
    let some info := LeafInfo.ofIndex? (← natAt array 3) | throw "unknown leaf info"
    return {
      node := ← natAt array 0
      start := ← natAt array 1
      stop := ← natAt array 2
      info
      leading := ← Lean.fromJson? array[4]!
      trailing := ← Lean.fromJson? array[5]!
    }

instance : Lean.ToJson Node where
  toJson node := .arr #[
    Lean.toJson node.kind, Lean.toJson node.parent,
    Lean.toJson node.range.start, Lean.toJson node.range.stop]

instance : Lean.FromJson Node where
  fromJson? json := do
    let array ← fields json 4
    return {
      kind := ← natAt array 0
      parent := ← Lean.fromJson? array[1]!
      range := { start := ← natAt array 2, stop := ← natAt array 3 }
    }

/-- The exact, compact representation of one accepted module.

Identity binds the normalized string and the module, and nothing else. It records no property of the
file on disk on purpose: a module linter is handed `fileMap.source`, which is already normalized, so
raw byte identity is unobservable from inside the compiler. A schema carrying it could not be
produced by both mandated producers, and the two would disagree on exactly the CRLF files that miss
today. A consumer holds the file, so it can recover line endings itself.

A consumer that holds a source file can check every claim here without a frontend and without
trusting the producer. -/
structure LosslessSource where
  schema : String
  mainModule : String
  normalizedBytes : Nat
  normalizedDigest : Digest
  /-- `[0, headerStop)` is the module header. Module linters never receive it, so it is recorded
  rather than assumed to be covered by the command stream. -/
  headerStop : Nat
  /-- Where the token stream ends, i.e. where the terminal command begins. `[terminalStop,
  normalizedBytes)` is the uninterpreted tail: it reconstructs verbatim and is never a token. It is
  empty exactly when the terminal is `eoi`, and is `#exit` plus Lean's never-parsed remainder
  otherwise. -/
  terminalStop : Nat
  kinds : Array String
  nodes : Array Node
  tokens : Array Token
  deriving BEq, Repr, Lean.ToJson, Lean.FromJson

def losslessSourceSchema : String := "lean-fmt.lossless-source.v1"

namespace LosslessSource

/-! ## Normalization -/

/-- Read the two forms of a source together.

This is the only place the product is permitted to normalize. `Lean.Parser.mkInputContext` applies
`crlfToLf` by default, so the parser never sees a `\r` that was part of a `\r\n`; a caller that
digests the raw bytes and compares them against compiler-produced offsets is comparing two different
strings. -/
def normalize (raw : String) : String × LineEndings :=
  let normalized := raw.crlfToLf
  (normalized, if normalized == raw then .lf else .crlf)

/-- Reapply the recorded line-ending form. Inverse of `normalize` for accepted source, which cannot
contain an isolated `\r`. -/
def denormalize (normalized : String) : LineEndings → String
  | .lf => normalized
  | .crlf => normalized.replace "\n" "\r\n"

/-! ## Trivia scanning -/

/- Classify one trivia span. The span's bounds come from the parser; this only names what is inside
it, mirroring the grammar of `Lean.Parser.whitespace` (`Lean/Parser/Basic.lean:563-588`). Anything
that grammar rejects cannot appear here, because the file would not have parsed. -/
private partial def scanTrivia (source : String) (start stop : String.Pos.Raw)
    (acc : Array Trivia := #[]) : Array Trivia :=
  if start.byteIdx >= stop.byteIdx then
    acc
  else
    let current := start.get source
    if current == '-' then
      -- `--` runs to, but does not include, the newline; `whitespace` takes the newline itself.
      let stop' := lineCommentStop (start.next source) stop
      scanTrivia source stop' stop (acc.push { kind := .lineComment, stop := stop'.byteIdx })
    else if current == '/' then
      let stop' := blockCommentStop ((start.next source).next source) stop 1
      scanTrivia source stop' stop (acc.push { kind := .blockComment, stop := stop'.byteIdx })
    else
      let stop' := whitespaceStop start stop
      scanTrivia source stop' stop (acc.push { kind := .whitespace, stop := stop'.byteIdx })
where
  whitespaceStop (pos stop : String.Pos.Raw) : String.Pos.Raw :=
    if pos.byteIdx >= stop.byteIdx then pos
    else if (pos.get source).isWhitespace then whitespaceStop (pos.next source) stop
    else pos
  lineCommentStop (pos stop : String.Pos.Raw) : String.Pos.Raw :=
    if pos.byteIdx >= stop.byteIdx then pos
    else if pos.get source == '\n' then pos
    else lineCommentStop (pos.next source) stop
  blockCommentStop (pos stop : String.Pos.Raw) (nesting : Nat) : String.Pos.Raw :=
    if pos.byteIdx >= stop.byteIdx || nesting == 0 then pos
    else
      let current := pos.get source
      let next := pos.next source
      if next.byteIdx >= stop.byteIdx then next
      else if current == '-' && next.get source == '/' then
        let after := next.next source
        if nesting == 1 then after else blockCommentStop after stop (nesting - 1)
      else if current == '/' && next.get source == '-' then
        blockCommentStop (next.next source) stop (nesting + 1)
      else blockCommentStop next stop nesting

/-! ## Production -/

private structure Build where
  kinds : Array String := #[]
  kindIndex : Std.HashMap String Nat := {}
  nodes : Array Node := #[]
  tokens : Array Token := #[]

private def Build.intern (build : Build) (kind : String) : Nat × Build :=
  match build.kindIndex[kind]? with
  | some index => (index, build)
  | none =>
    let index := build.kinds.size
    (index, { build with
      kinds := build.kinds.push kind
      kindIndex := build.kindIndex.insert kind index })

private def leafSpan (info : Lean.SourceInfo) : Option (String.Pos.Raw × String.Pos.Raw) :=
  match info with
  | .original _ pos _ endPos => some (pos, endPos)
  | .synthetic pos endPos _ => some (pos, endPos)
  | .none => none

/- Walk one command in source order, pushing nodes before their children so a child can name its
parent, then widening each node to the hull of the leaves beneath it. -/
private partial def collect (source : String) (parent : Option Nat) (stx : Lean.Syntax)
    (build : Build) : Option SourceRange × Build :=
  match stx with
  | .missing =>
    let token : Token := { node := parent.getD 0, start := 0, stop := 0, info := .missing }
    (none, { build with tokens := build.tokens.push token })
  | .node _ kind args =>
    let (kindIndex, build) := build.intern kind.toString
    let index := build.nodes.size
    let placeholder : Node := { kind := kindIndex, parent, range := { start := 0, stop := 0 } }
    let build := { build with nodes := build.nodes.push placeholder }
    -- A `choice` node holds several parses of *one* byte range, so walking every alternative would
    -- emit those bytes once per alternative and the token stream would run backwards. Only the
    -- first contributes; the `choice` node itself stays, so the ambiguity is visible rather than
    -- silently resolved. `Parser/Basic.lean:1418-1440` is what licenses picking any one of them:
    -- `longestMatchStep` restores each alternative to the same `startPos` and keeps it only when
    -- its score ties, whose first component is the stop position. Equal start, equal stop, one
    -- tokenizer: the alternatives differ in tree shape alone and spell identical text.
    let args := if kind == Lean.choiceKind then args.extract 0 1 else args
    let (span, build) := args.foldl (init := (none, build)) fun (span, build) arg =>
      let (argSpan, build) := collect source (some index) arg build
      (mergeSpan span argSpan, build)
    let range := span.getD { start := 0, stop := 0 }
    let build := { build with nodes := build.nodes.modify index ({ · with range }) }
    (span, build)
  | .atom info _ | .ident info _ _ _ =>
    let node := parent.getD 0
    match info with
    | .original leading pos trailing endPos =>
      let token : Token := {
        node
        leading := scanTrivia source leading.startPos pos
        start := pos.byteIdx
        stop := endPos.byteIdx
        trailing := scanTrivia source endPos trailing.stopPos
        info := .original
      }
      (some { start := pos.byteIdx, stop := endPos.byteIdx },
        { build with tokens := build.tokens.push token })
    | _ =>
      let (start, stop) := match leafSpan info with
        | some (pos, endPos) => (pos.byteIdx, endPos.byteIdx)
        | none => (0, 0)
      let token : Token := { node, start, stop, info := .synthetic }
      (some { start, stop }, { build with tokens := build.tokens.push token })
where
  mergeSpan : Option SourceRange → Option SourceRange → Option SourceRange
    | none, span => span
    | span, none => span
    | some a, some b => some { start := min a.start b.start, stop := max a.stop b.stop }

/-- Byte offset where the first leaf's leading trivia begins, i.e. where the command stream starts.

Taken from the parser's own `leading.startPos` rather than reconstructed, because the token stream
records no leading start of its own — `headerStop` *is* that boundary. -/
private partial def firstLeadingStart? (stx : Lean.Syntax) : Option Nat :=
  match stx with
  | .missing => none
  | .node _ _ args => args.findSome? firstLeadingStart?
  | .atom info _ | .ident info _ _ _ =>
    match info with
    | .original leading .. => some leading.startPos.byteIdx
    | .synthetic pos .. => some pos.byteIdx
    | .none => none

/-- Project one accepted module.

`normalized` must be the string the parser saw, i.e. `(normalize raw).1`, because every offset
`commands` carries indexes it. `commands` is the ordered non-terminal command stream. `terminal?` is
the terminal command that ended the file: `eoi` for an ordinary file, `#exit` for one that stops
early. Neither producer may pass the module header — a module linter never receives it — so the
header is recorded as the prefix before the first leaf's leading trivia, which is a position both
producers can actually see. -/
def ofSource (mainModule : String) (normalized : String) (commands : Array Lean.Syntax)
    (terminal? : Option Lean.Syntax := none) : LosslessSource :=
  let build := commands.foldl (init := ({} : Build)) fun build stx =>
    (collect normalized none stx build).2
  -- With no commands the whole file is header: its trailing trivia runs to end of file.
  let headerStop := (commands.findSome? firstLeadingStart?).getD normalized.utf8ByteSize
  -- Where the terminal command *begins*, which is where the modeled token stream ends: neither
  -- producer puts a terminal into `commands`, so its own text is tail, not token. For `eoi` this is
  -- end of file, since trailing trivia is greedy up to the next token's text and `eoi` has none.
  -- For `#exit` it is the `#exit` itself, and the tail is that plus the never-parsed remainder.
  let terminalStop :=
    match terminal?.bind firstLeadingStart? with
    | some start => start
    | none => match build.tokens.back? with
      | some token => token.trailingStop
      | none => normalized.utf8ByteSize
  {
    schema := losslessSourceSchema
    mainModule
    normalizedBytes := normalized.utf8ByteSize
    normalizedDigest := Digest.ofString normalized
    headerStop
    terminalStop
    kinds := build.kinds
    nodes := build.nodes
    tokens := build.tokens
  }

/-! ## Validation

Consumption never trusts a producer. These checks run on every artifact read, cost one integer pass
plus one digest, and need neither a frontend nor the compiler. Every failure is an ordinary miss. -/

/-- Do the trivia runs tile `[start, stop)` in strictly source order? -/
private def triviaTiles (runs : Array Trivia) (start stop : Nat) : Bool := Id.run do
  let mut cursor := start
  for run in runs do
    if run.stop <= cursor || run.stop > stop then
      return false
    cursor := run.stop
  return cursor == stop

/-- Structural validity, independent of any source.

The load-bearing clause is the tiling: token spans and their trivia must cover `[headerStop,
terminalStop)` exactly once, contiguously, with no gap and no overlap. That is the invariant
`RLS-SPEC` measured and the reason this projection is lossless rather than merely plausible. -/
def structurallyValid (source : LosslessSource) : Bool := Id.run do
  unless source.schema == losslessSourceSchema do
    return false
  unless source.headerStop <= source.terminalStop &&
      source.terminalStop <= source.normalizedBytes do
    return false
  for node in source.nodes do
    unless node.kind < source.kinds.size do
      return false
    unless node.parent.all (· < source.nodes.size) do
      return false
    unless node.range.start <= node.range.stop && node.range.stop <= source.normalizedBytes do
      return false
  let mut cursor := source.headerStop
  for token in source.tokens do
    -- A projection is only lossless if the parser recorded real positions for every leaf.
    unless token.info == .original do
      return false
    unless token.node < source.nodes.size do
      return false
    unless triviaTiles token.leading cursor token.start do
      return false
    unless token.start <= token.stop do
      return false
    unless triviaTiles token.trailing token.stop token.trailingStop do
      return false
    cursor := token.trailingStop
  -- With no commands the header runs to the terminal, so an empty stream is valid exactly when the
  -- header already covers the parsed region.
  return cursor == source.terminalStop

/-- Validity against a concrete on-disk source.

`raw` is the file's bytes as the caller read them; normalizing here is the whole point. A caller that
digested `raw` directly and compared it to a compiler-produced identity would be comparing two
different strings, which is why every CRLF file misses today. -/
def validFor (source : LosslessSource) (raw : String) : Bool :=
  let normalized := (normalize raw).1
  structurallyValid source &&
    source.normalizedBytes == normalized.utf8ByteSize &&
    source.normalizedDigest == Digest.ofString normalized

end LosslessSource

end LeanFmt.Internal
