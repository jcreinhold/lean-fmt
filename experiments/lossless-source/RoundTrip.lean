module

/- Byte-for-byte round-trip oracle for the Lean 4.32 parser's own trivia record.

This experiment answers one question for `RLS-SPEC`: which compiler-owned data reconstructs an
accepted source file exactly, and which data only appears to. It deliberately does not reuse any
`LeanFmt` module, so a production regression cannot mask a parser fact.

Two reconstructions are built from the same ordered leaf walk:

* `slice`  concatenates `leading ++ source[pos, endPos) ++ trailing`.
* `token`  concatenates `leading ++ atomVal/identRawVal ++ trailing`.

`slice` tests whether the trivia record covers every source byte exactly once and in order.
`token` additionally tests whether the token payload the parser hands us is the literal source
text, which is what a serialized projection would have to store. -/

import Lean

open Lean System

namespace LosslessSource

/-- One parser leaf, recorded with both candidate texts and its raw span. -/
structure Leaf where
  form : String
  infoKind : String
  leading : String
  trailing : String
  tokenText : String
  sliceText : String
  leadingStart : Nat
  pos : Nat
  endPos : Nat
  trailingStop : Nat
  deriving Inhabited

private def rawSlice (source : String) (start stop : String.Pos.Raw) : String :=
  Substring.Raw.toString { str := source, startPos := start, stopPos := stop }

private def mkLeaf (source : String) (form : String) (info : SourceInfo)
    (text : String) : Leaf :=
  match info with
  | .original leading pos trailing endPos =>
    { form
      infoKind := "original"
      leading := leading.toString
      trailing := trailing.toString
      tokenText := text
      sliceText := rawSlice source pos endPos
      leadingStart := leading.startPos.byteIdx
      pos := pos.byteIdx
      endPos := endPos.byteIdx
      trailingStop := trailing.stopPos.byteIdx }
  | .synthetic pos endPos _ =>
    { form
      infoKind := "synthetic"
      leading := ""
      trailing := ""
      tokenText := text
      sliceText := ""
      leadingStart := pos.byteIdx
      pos := pos.byteIdx
      endPos := endPos.byteIdx
      trailingStop := endPos.byteIdx }
  | .none =>
    { form
      infoKind := "none"
      leading := ""
      trailing := ""
      tokenText := text
      sliceText := ""
      leadingStart := 0
      pos := 0
      endPos := 0
      trailingStop := 0 }

/- Visit every leaf in source order. `node` info is ignored on purpose: the parser records token
provenance on atoms and identifiers, and a node's own info is `SourceInfo.none` or a synthetic
span copied from a token that is also visited. -/
private partial def collectLeaves (source : String) (leaves : Array Leaf)
    (stx : Syntax) : Array Leaf :=
  match stx with
  | .missing => leaves.push { (default : Leaf) with form := "missing", infoKind := "missing" }
  | .node _ _ args => args.foldl (collectLeaves source) leaves
  | .atom info val => leaves.push (mkLeaf source "atom" info val)
  | .ident info rawVal _ _ => leaves.push (mkLeaf source "ident" info rawVal.toString)

private def reconstruct (leaves : Array Leaf) (useToken : Bool) : String :=
  leaves.foldl (init := "") fun acc leaf =>
    acc ++ leaf.leading ++ (if useToken then leaf.tokenText else leaf.sliceText) ++ leaf.trailing

private def firstDifference (expected actual : String) : Option Nat := Id.run do
  let a := expected.toUTF8
  let b := actual.toUTF8
  for index in [0 : min a.size b.size] do
    if a.get! index != b.get! index then
      return some index
  if a.size == b.size then none else some (min a.size b.size)

private def excerpt (text : String) (offset : Nat) : String :=
  let bytes := text.toUTF8
  let start := if offset > 24 then offset - 24 else 0
  let stop := min bytes.size (offset + 24)
  String.fromUTF8! (bytes.extract start stop) |>.replace "\n" "\\n" |>.replace "\r" "\\r"

/-- Report the ordering/coverage invariant separately from the byte comparison: a passing
reconstruction with a coverage gap would be an accident, not a contract. -/
private def coverageBreak (leaves : Array Leaf) : Option Nat := Id.run do
  let mut cursor := 0
  for index in [0 : leaves.size] do
    let leaf := leaves[index]!
    if leaf.infoKind != "original" then
      continue
    if leaf.leadingStart != cursor then
      return some index
    if !(leaf.leadingStart <= leaf.pos && leaf.pos <= leaf.endPos && leaf.endPos <= leaf.trailingStop) then
      return some index
    cursor := leaf.trailingStop
  return none

private unsafe def parseModule (source : String) (path : FilePath) :
    IO (Array Syntax × Bool) := do
  -- Production uses this exact constructor, whose `normalizeLineEndings` default is `true`.
  let input := Parser.mkInputContext source path.toString
  let (header, state, messages) ← Parser.parseHeader input
  if messages.hasErrors then
    throw <| IO.userError s!"header parse failed: {path}"
  -- `loadExts := true` is required: parser extensions (every `syntax`/`notation` declaration,
  -- including all of Init's tactics) live in environment extensions, not in the builtin token
  -- table. Without replaying them the token table is wrong and parsing silently diverges.
  let env ← importModules (Elab.headerToImports header) {} (trustLevel := 1024)
    (loadExts := true)
  let pmctx : Parser.ParserModuleContext := { env, options := {} }
  let mut stxs := #[header.raw]
  let mut state := state
  let mut messages := messages
  let mut sawEoi := false
  repeat
    let (stx, next, msgs) := Parser.parseCommand input pmctx state messages
    stxs := stxs.push stx
    state := next
    messages := msgs
    -- Mirror the frontend: it stops at the first terminal command, which is `eoi` for an ordinary
    -- file but also `#exit`. Anything after `#exit` is never parsed and therefore has no trivia.
    if Parser.isTerminalCommand stx then
      sawEoi := stx.isOfKind ``Parser.Command.eoi
      break
  if messages.hasErrors then
    for message in messages.toArray do
      IO.eprintln s!"  parse_error: {← message.toString}"
    throw <| IO.userError s!"command parse failed: {path}"
  return (stxs, sawEoi)

/- The oracle compares against two candidate originals:

* `raw`        the bytes on disk, which is what `Application` digests today.
* `normalized` `raw.crlfToLf`, which is the string `mkInputContext` actually parses and therefore
               the only string every `SourceInfo` offset indexes.

Reporting both is the point of the experiment: an artifact that claims byte ranges into `raw` is
wrong for any file whose two forms differ. -/
private unsafe def checkFile (path : FilePath) : IO Bool := do
  let raw ← IO.FS.readFile path
  let normalized := raw.crlfToLf
  let (stxs, sawEoi) ← parseModule raw path
  let leaves := stxs.foldl (collectLeaves normalized) #[]
  let sliceText := reconstruct leaves (useToken := false)
  let tokenText := reconstruct leaves (useToken := true)
  let originals := leaves.filter (·.infoKind == "original") |>.size
  let synthetics := leaves.filter (·.infoKind == "synthetic") |>.size
  let missings := leaves.filter (·.infoKind == "missing") |>.size
  IO.println s!"file={path}"
  IO.println s!"  raw_bytes={raw.utf8ByteSize} normalized_bytes={normalized.utf8ByteSize} \
line_endings_normalized={raw != normalized}"
  IO.println s!"  commands={stxs.size} eoi={sawEoi}"
  IO.println s!"  leaves={leaves.size} original={originals} synthetic={synthetics} missing={missings}"
  IO.println s!"  slice_roundtrip_normalized={sliceText == normalized} \
token_roundtrip_normalized={tokenText == normalized}"
  IO.println s!"  slice_roundtrip_raw={sliceText == raw} token_roundtrip_raw={tokenText == raw}"
  match coverageBreak leaves with
  | some index => IO.println s!"  coverage_break_at_leaf={index}"
  | none => IO.println s!"  coverage=contiguous_from_zero"
  if sliceText != normalized then
    if let some offset := firstDifference normalized sliceText then
      IO.println s!"  slice_first_diff_byte={offset}"
      IO.println s!"    expected={excerpt normalized offset}"
      IO.println s!"    actual  ={excerpt sliceText offset}"
  if tokenText != normalized then
    if let some offset := firstDifference normalized tokenText then
      IO.println s!"  token_first_diff_byte={offset}"
      IO.println s!"    expected={excerpt normalized offset}"
      IO.println s!"    actual  ={excerpt tokenText offset}"
      -- Name the leaf that produced the divergence: this is the spec-relevant fact.
      for leaf in leaves do
        if leaf.infoKind == "original" && leaf.pos <= offset && offset < leaf.trailingStop &&
            leaf.tokenText != leaf.sliceText then
          IO.println s!"    leaf form={leaf.form} token={leaf.tokenText.quote} \
slice={leaf.sliceText.quote}"
          break
  -- The contract is losslessness against the string the parser was given.
  return sliceText == normalized && tokenText == normalized

private def usage := "usage: round-trip FILE"

/- Exit codes are the harness contract, so "Lean rejects these bytes" and "Lean accepts these bytes
but the trivia record does not reconstruct them" stay distinguishable:

  0  parsed, and the trivia record reconstructs the parsed string byte-for-byte
  1  parsed, but reconstruction diverged
  2  usage
  3  the parser rejected the file

One file per process. `importModules (loadExts := true)` replays `[init]` code and may not run twice
in one process against different module sets, so the caller owns iteration and process exit remains
the reclamation boundary. This matches the execution-core-v2 finding that one process retaining
distinct exact contexts is not a supported strategy. -/
private unsafe def run (args : List String) : IO UInt32 := do
  let [arg] := args
    | IO.eprintln usage
      return 2
  initSearchPath (← findSysroot)
  enableInitializersExecution
  try
    return if (← checkFile arg) then 0 else 1
  catch error =>
    IO.eprintln s!"rejected: {error}"
    return 3

end LosslessSource

public unsafe def main (args : List String) : IO UInt32 := LosslessSource.run args
