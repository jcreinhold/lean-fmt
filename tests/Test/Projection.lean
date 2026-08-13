module

public import Test.Harness
public import Test.Json
public import Test.Proc

/-!
# The lossless projection oracle

This oracle shares no code with the product: every claim is re-derived from the artifact JSON and
the file on disk alone, so it can *contradict* `ModuleSyntax.structurallyValid` rather than restate
it.

The claim it checks and the product does not is **tiling**: that the leaves form a gapless,
non-overlapping linear cover of the source between the header and the unparsed tail.
`structurallyValid` checks that command roots are contiguous *in the entry array*, that each
root's range lies within the file, that command ranges do not overlap, and that the terminal tree
ends exactly at the array boundary. It never compares one leaf's `trailingStop` to the next leaf's
`leadingStart`, so a projection that silently drops a token's bytes, or claims the same bytes
twice, passes it. That is the failure this oracle exists to catch, and the lossless suite's
mutation case keeps the catching non-vacuous.

Offsets are UTF-8 byte offsets into the *normalized* source (`raw.crlfToLf`), because
`Parser.mkInputContext` normalizes before it assigns any position.

The wire encoding — entry tags, source-info tags, the meaning of `terminal` — is pinned exactly to
`lean-fmt.module-artifact.v10`. A later schema that reorders any of it would be mis-decoded rather
than rejected, so bumping `artifactSchema` has to be a deliberate edit that re-reads the encoding.

`v10` → `v11` was such an edit: it adds the optional top-level `interfaceHash` field for the
result cache's interface closure mode and changes nothing this decoder reads — the entry and
info tags, `terminal`, and every field below are byte-identical, which this oracle continuing to
pass verifies. -/

namespace LeanFmt.Test.Projection

/-- The one schema this file decodes. -/
public def artifactSchema : String :=
  "lean-fmt.module-artifact.v11"

/-- A decoded source info: what the leaf owns of the normalized source. -/
private inductive Info where
  | none
  | original (leadingStart trailingStop : Nat)
  | synthetic

private def fail {α} (message : String) : IO α :=
  throw <| IO.userError message

private def jsonNat? (json : Lean.Json) : Option Nat :=
  match json with
  | .num n => some n.mantissa.toNat
  | _ => none

private def entryArray (entry : Lean.Json) (label : String) : IO (Array Lean.Json) :=
  match entry with
  | .arr items => return items
  | _ => fail s!"{label} is not an array"

private def entryTag (entry : Lean.Json) (label : String) : IO Nat := do
  let items ← entryArray entry label
  match items[0]? with
  | some tag =>
    match tag with
    | .num n =>
      return n.mantissa.toNat
    | _ =>
      fail s!"{label} has no tag"
  | none =>
    fail s!"{label} has no tag"

/-- Decode one `info` field: `0` for none, `[1, leadingStart, position, endPosition, trailingStop]`
for original, `[2, ...]` for synthetic. -/
private def decodeInfo (raw : Lean.Json) : IO Info := do
  match raw with
  | .num n =>
    if n.mantissa.toNat == 0 then
      return .none
    fail s!"unknown source-info tag {n.mantissa.toNat}"
  | .arr items =>
    match items[0]? with
    | none =>
      fail s!"malformed source info {raw.compress}"
    | some tag =>
      match jsonNat? tag with
      | some 1 =>
        let some positions :=
          items[1:5].toArray.mapM
            jsonNat? | fail s!"original info has {items.size} fields, expected 5"
        match positions.toList with
        | [leadingStart, position, endPosition, trailingStop] =>
          unless
            leadingStart <= position && position <= endPosition && endPosition <= trailingStop do
            fail
                s!"original info out of order: {leadingStart} <= {position} <= {endPosition} \
              <= {trailingStop}"
          return .original leadingStart trailingStop
        | _ =>
          fail "unreachable: five fields did not match five"
      | some 2 =>
        return .synthetic
      | some other =>
        fail s!"unknown source-info tag {other}"
      | none =>
        fail s!"malformed source-info tag {raw.compress}"
  | _ =>
    fail s!"malformed source info {raw.compress}"

/-- Pre-order walk over the flat `entries` array, collecting the byte span each leaf owns. -/
private structure Walk where
  entries : Array Lean.Json
  kinds : Array String

/-- Return `(nextIndex, spans)` for the subtree rooted at `index`. -/
private partial def Walk.subtree (walk : Walk) (index : Nat) : IO (Nat × Array (Nat × Nat)) := do
  let some entry := walk.entries[index]? | fail s!"entry index {index} of {walk.entries.size}"
  let tag ← entryTag entry s!"entry {index}"
  match tag with
  | 0 =>
    return (index + 1, #[]) -- missing
  | 2 | 3 => -- atom | ident
    let items ← entryArray entry s!"entry {index}"
    let some info := items[1]? | fail s!"entry {index} has no source info"
    match ← decodeInfo info with
    | .original leadingStart trailingStop =>
      return (index + 1, #[(leadingStart, trailingStop)])
    | .none =>
      -- The parser recorded no position for this leaf, so it owns no bytes and contributes no span.
      -- Verso spells a heading with three of them -- the level literal, `)` and `{` -- and a leaf
      -- that spells nothing cannot make the spans it does not appear in stop tiling the source.
      return (index + 1, #[])
    | .synthetic =>
      fail
          s!"entry {index} is a synthetic leaf, so its position is fabricated \
        rather than a projection of the source"
  | 1 => -- node
    let items ← entryArray entry s!"entry {index}"
    unless items.size == 4 do
      fail s!"entry {index} is a node with {items.size} fields, expected 4"
    let some kind := items[2]? |>.bind jsonNat? | fail s!"entry {index} has no kind"
    let some kindName :=
      walk.kinds[kind]? | fail s!"entry {index} names kind {kind} of {walk.kinds.size}"
    let some childCount := items[3]? |>.bind jsonNat? | fail s!"entry {index} has no child count"
    let mut cursor := index + 1
    let mut children : Array (Array (Nat × Nat)) := #[]
    for _ in [0:childCount] do
      let (next, spans) ← walk.subtree cursor
      cursor := next
      children := children.push spans
    if kindName == "choice" then
      -- Every alternative parses the same bytes, so only the first may contribute. This is what
      -- `terminalsFrom` assumes and `Syntax.reprint` verifies; here it is verified.
      let some first := children[0]? | fail s!"entry {index} is a choice node with no alternatives"
      for position in [1:children.size] do
        let other := children[position]!
        unless other == first do
          fail
              s!"entry {index}: choice alternative {position} spells {other.toList} where \
            alternative 0 spells {first.toList}"
      return (cursor, first)
    return (cursor, children.foldl (· ++ ·) #[])
  | other =>
    fail s!"unknown entry tag {other} at {index}"

/-- The measurements a successful check derives; the suite pins individual fields. -/
public structure Measurements where
  rawBytes : Nat
  normalizedBytes : Nat
  leaves : Nat
  entries : Nat
  kinds : Nat
  commands : Nat
  headerStop : Nat
  terminalStart : Nat
  tailBytes : Nat
  deriving Lean.ToJson

private def required (artifact : Lean.Json) (key : String) : IO Lean.Json :=
  match artifact.getObjVal? key with
  | .ok value => return value
  | .error _ => fail s!"artifact has no `{key}`"

private def requiredNat (artifact : Lean.Json) (key : String) : IO Nat := do
  let value ← required artifact key
  match jsonNat? value with
  | some n =>
    return n
  | none =>
    fail s!"artifact `{key}` is not a natural number"

/-- sha256 of a string's exact bytes, via `shasum` on stdin. -/
private def digestString (bytes : String) : IO String := do
  let result ← runProc "shasum" #["-a", "256"] (input? := some bytes)
  unless result.exitCode == 0 do
    fail s!"shasum failed: {result.stderr}"
  match result.stdout.splitOn " " with
  | hex :: _ =>
    return hex
  | [] =>
    fail "shasum produced no digest"

/-- Verify the projection against the file's raw bytes. Raises `IO.userError` on any violated
claim; returns measurements otherwise. `artifact` is the artifact object alone (not an envelope),
already schema-checked by `checkArtifact`. -/
private def checkProjection (syntaxData artifact : Lean.Json) (raw : String) : IO Measurements := do
  let normalized := raw.replace "\r\n" "\n"
  -- Identity. A consumer holds a file; the projection describes the string the parser saw.
  let claimedBytes ← requiredNat artifact "normalizedBytes"
  unless claimedBytes == normalized.utf8ByteSize do
    fail s!"normalizedBytes {claimedBytes} != {normalized.utf8ByteSize} actual bytes"
  let claimedDigest ← required artifact "normalizedDigest"
  let actualDigest ← digestString normalized
  unless claimedDigest == Lean.toJson actualDigest do
    fail "normalizedDigest does not match the normalized source"
  let some kindsJson :=
    (syntaxData.getObjVal? "kinds").toOption |>.bind
      (·.getArr?.toOption) | fail "syntaxData has no kinds"
  let some kinds := kindsJson.mapM (·.getStr?.toOption) | fail "syntaxData kinds are not strings"
  let some entries :=
    (syntaxData.getObjVal? "entries").toOption |>.bind
      (·.getArr?.toOption) | fail "syntaxData has no entries"
  let some commands :=
    (syntaxData.getObjVal? "commands").toOption |>.bind
      (·.getArr?.toOption) | fail "syntaxData has no commands"
  let some terminal :=
    (syntaxData.getObjVal? "terminal").toOption |>.bind jsonNat? | fail "syntaxData has no terminal"
  let walk : Walk := { entries, kinds }
  let mut spans : Array (Nat × Nat) := #[]
  let mut cursor := 0
  let mut previousStop := 0
  -- Ordinary commands, in source order. A command root begins where the previous root's subtree
  -- ended, so the array is a concatenation of whole trees with nothing between them.
  for position in [0:commands.size] do
    let root := commands[position]!
    let some rootEntry :=
      (root.getObjVal? "entry").toOption |>.bind jsonNat? | fail s!"command {position} has no entry"
    unless rootEntry == cursor do
      fail
          s!"command {position} claims entry {rootEntry} but the previous subtree ended at {cursor}"
    let some range := (root.getObjVal? "range").toOption | fail s!"command {position} has no range"
    let some start :=
      (range.getObjVal? "start").toOption |>.bind
        jsonNat? | fail s!"command {position} has no range start"
    let some stop :=
      (range.getObjVal? "stop").toOption |>.bind
        jsonNat? | fail s!"command {position} has no range stop"
    unless start <= stop && stop <= normalized.utf8ByteSize do
      fail s!"command {position} has range {start}..{stop} of {normalized.utf8ByteSize}"
    unless start >= previousStop do
      fail s!"command {position} starts at {start}, inside the previous command"
    previousStop := stop
    let (next, rootSpans) ← walk.subtree cursor
    cursor := next
    spans := spans ++ rootSpans
  -- The terminal command closes the modelled region. It is not in `commands`, and its subtree must
  -- be the last thing in the array -- otherwise entries exist that no root reaches.
  unless terminal == cursor do
    fail s!"terminal is entry {terminal} but the commands ended at {cursor}"
  let (afterTerminal, terminalSpans) ← walk.subtree terminal
  unless afterTerminal == entries.size do
    fail s!"the terminal subtree ends at {afterTerminal}, not the array boundary {entries.size}"
  let terminalStart := terminalSpans[0]?.map (·.1) |>.getD normalized.utf8ByteSize
  spans := spans ++ terminalSpans
  if spans.isEmpty then
    fail "the projection reconstructs no leaves at all"
  -- Reconstruction. Everything before the first leaf is header the parser consumed as the module
  -- preamble; everything after the last is tail it never parsed. Between them the leaves tile.
  let headerStop := spans[0]!.1
  unless headerStop <= normalized.utf8ByteSize do
    fail s!"the first leaf starts at {headerStop}, past {normalized.utf8ByteSize} bytes"
  let mut rebuilt := String.Pos.Raw.extract normalized 0 ⟨headerStop⟩
  let mut tileCursor := headerStop
  for index in [0:spans.size] do
    let (leadingStart, trailingStop) := spans[index]!
    unless leadingStart == tileCursor do
      let shape := if leadingStart > tileCursor then "a hole" else "an overlap"
      let size :=
        if leadingStart > tileCursor then leadingStart - tileCursor else tileCursor - leadingStart
      fail
          s!"leaf {index} owns {leadingStart}..{trailingStop} but the previous leaf stopped at \
        {tileCursor}: {shape} of {size} byte(s), so the projection is not a linear cover"
    unless trailingStop <= normalized.utf8ByteSize do
      fail s!"leaf {index} stops at {trailingStop}, past {normalized.utf8ByteSize} bytes"
    rebuilt := rebuilt ++ String.Pos.Raw.extract normalized ⟨tileCursor⟩ ⟨trailingStop⟩
    tileCursor := trailingStop
  let tailStart := tileCursor
  rebuilt := rebuilt ++ String.Pos.Raw.extract normalized ⟨tileCursor⟩ ⟨normalized.utf8ByteSize⟩
  unless rebuilt == normalized do
    fail "reconstruction is not byte-identical to the source"
  return {
      rawBytes := raw.utf8ByteSize
      normalizedBytes := normalized.utf8ByteSize
      leaves := spans.size
      entries := entries.size
      kinds := kinds.size
      commands := commands.size
      headerStop
      terminalStart
      tailBytes := normalized.utf8ByteSize - tailStart }

/-- Verify one artifact against the source file on disk: schema pin, no findings (an artifact
carries facts, never findings), syntaxData present, then the projection check. Raises
`IO.userError` on any violated claim. -/
public def checkArtifact (artifact : Lean.Json) (source : System.FilePath) : IO Measurements := do
  let schema := (artifact.getObjValAs? String "schema").toOption.getD ""
  unless schema == artifactSchema do
    fail s!"schema {schema} is not the {artifactSchema} encoding this decodes"
  if (artifact.getObjVal? "findings").isOk then
    fail "artifact carries findings; it must carry only facts"
  let some syntaxData :=
    (artifact.getObjVal? "syntaxData").toOption | fail "artifact carries no syntaxData"
  checkProjection syntaxData artifact (String.fromUTF8! (← IO.FS.readBinFile source))

/-- The envelope form: the artifact must be present, with diagnostics explaining any absence
surfaced in the error. -/
public def checkEnvelope (envelope : Lean.Json) (source : System.FilePath) : IO Measurements := do
  match (envelope.getObjVal? "artifact").toOption with
  | some artifact =>
    checkArtifact artifact source
  | none =>
    let diagnostics :=
      (envelope.getObjVal? "diagnostics").toOption |>.map Lean.Json.compress |>.getD "?"
    fail s!"envelope has no artifact: {diagnostics}"

end LeanFmt.Test.Projection
