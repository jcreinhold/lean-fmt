module

public import LeanFmt.Analysis
public import LeanFmt.Application
public import LeanFmt.ArtifactStore
public import LeanFmt.Cache
public import LeanFmt.Cli
public import LeanFmt.Comments
public import LeanFmt.Config
public import LeanFmt.Discovery
public import LeanFmt.Doc
public import LeanFmt.Edit
public import LeanFmt.Formatter.NativeLayout
public import LeanFmt.Imports
public import LeanFmt.LanguageServer
public import LeanFmt.Rules
public import LeanFmt.Suppression
public import Test

import all LeanFmt.Analysis
import all LeanFmt.Application
import all LeanFmt.ArtifactStore
import all LeanFmt.Cache
import all LeanFmt.Cli
import all LeanFmt.Comments
import all LeanFmt.Config
import all LeanFmt.Discovery
import all LeanFmt.Doc
import all LeanFmt.Edit
import all LeanFmt.Formatter.NativeLayout
import all LeanFmt.Imports
import all LeanFmt.LanguageServer
import all LeanFmt.Rules
import all LeanFmt.Suppression

import Lean.Data.Lsp

open LeanFmt LeanFmt.Internal

namespace LeanFmt.Test.Unit.Lsp

/-- The LSP position layer, characterized before
anything is built on it.

Two claims, both of which survive casual testing if they go untested. First, LSP columns are UTF-16
code units and `Application.PositionIndex`'s are codepoints, so the two disagree outside the BMP and
only outside it — reaching for `PositionIndex` in the server would be silently wrong on exactly the
inputs nobody types by hand. Second, `Lean.FileMap`'s conversion is a conversion and not a validator:
an out-of-range position produces an offset past the end of the document rather than an error, so the
server clamps every inbound position itself.

`𝔘` (U+1D518) is 4 UTF-8 bytes, 2 UTF-16 code units, and 1 codepoint, so one character separates all
three encodings. It is the same fixture used for the reporting columns
(the reporting suite, "codepoint columns are neither bytes nor UTF-16"). -/
private def testLspPositions : IO Unit := do
  let source := "theorem t : 𝔘 = 𝔘 := rfl\nsecond line\n"
  let fileMap := Lean.FileMap.ofString source
  ensure (source.utf8ByteSize == 43 && Lean.String.utf16Length source == 39 && source.length == 37)
      "the astral fixture no longer separates bytes, UTF-16 units, and codepoints"
  -- Byte 24 is the `:` of `:=`, with *two* astral characters before it on the line. One astral
  -- character is not enough to separate the two encodings here — at byte 16 both spellings answer 14,
  -- because 1-based codepoints and 0-based UTF-16 units differ by one in the other direction. Two are.
  let afterAstral := fileMap.utf8PosToLspPos ⟨24⟩
  ensure (afterAstral.line == 0 && afterAstral.character == 20)
      "the UTF-16 column after two astral characters moved"
  let codepointIndex :=
    Application.PositionIndex.ofSource "A.lean" source
      #[{ code := "TEST", severity := .warning, message := "probe",
          range := { start := 24, stop := 25 }, fix? := none }]
  match
    (Application.PositionIndex.position? codepointIndex "A.lean" 24 :
      Option Application.Position) with
  | some reported =>
    -- Three distinct numbers for one offset: codepoint column 19 (what we report), UTF-16 column 20
    -- (what LSP means), byte column 25 (what neither means).
    ensure (reported.line == 1 && reported.column == 19) "the reported codepoint column moved"
    ensure (reported.column != afterAstral.character)
        "codepoint and UTF-16 columns agree here, so this fixture no longer pins the difference"
  | none =>
    throw <| IO.userError "PositionIndex did not resolve an offset it was given"
  -- Not a validator. A 43-byte document answers a column of 9999 with an offset of 10003.
  let overrun := fileMap.lspPosToUtf8Pos ⟨0, 9999⟩
  ensure (overrun.byteIdx > source.utf8ByteSize)
      "out-of-range LSP columns are now clamped; the server's own clamp may be redundant"
  let pastEnd := fileMap.lspPosToUtf8Pos ⟨99, 0⟩
  ensure (pastEnd.byteIdx == source.utf8ByteSize)
      "an out-of-range line no longer saturates at the end of the document"
  -- A column interior to a surrogate pair snaps forward past the whole character rather than landing
  -- inside it. `def x := ` is 9 bytes, so `𝔘` is bytes 9-12 and columns 9-10.
  let small := Lean.FileMap.ofString "def x := 𝔘\n"
  ensure ((small.lspPosToUtf8Pos ⟨0, 9⟩).byteIdx == 9)
      "the column at an astral character no longer names its first byte"
  ensure ((small.lspPosToUtf8Pos ⟨0, 10⟩).byteIdx == 13)
      "a column splitting a surrogate pair no longer snaps forward past the character"
  -- Line starts diverge between raw CRLF and normalized text, which is why the document the server
  -- converts against is the normalized one (`CLAUDE.md`: every compiler-produced offset indexes
  -- `raw.crlfToLf`).
  let crlf := "def a := 1\r\ndef b := 2\r\n"
  let rawMap := Lean.FileMap.ofString crlf
  let (normalized, _) := LosslessSource.normalize crlf
  let normalizedMap := Lean.FileMap.ofString normalized
  ensure ((rawMap.lspPosToUtf8Pos ⟨1, 0⟩).byteIdx == 12) "the raw CRLF line start moved"
  ensure ((normalizedMap.lspPosToUtf8Pos ⟨1, 0⟩).byteIdx == 11) "the normalized line start moved"

/-! ### The language server's document layer

The differential test below covers the one failure that would corrupt a user's file rather than
merely annoy them. -/

section LanguageServerDocuments

open LeanFmt.Internal.LanguageServer

/-- LSP lines, as the specification defines them: the document split on `\n`, terminators kept, with a
final empty line after a trailing newline. Written out rather than reusing `FileMap` so the tests
below do not check an implementation against itself. -/
private def lspLines (source : String) : Array String :=
  let rec go (remaining : List Char) (current : String) (lines : Array String) : Array String :=
    match remaining with
    | [] => lines.push current
    | '\n' :: rest => go rest "" (lines.push (current.push '\n'))
    | c :: rest => go rest (current.push c) lines
  go source.toList "" #[]

/-- An independent resolution of an LSP position to a byte offset: sum the byte sizes of the preceding
lines, then walk this line counting UTF-16 units. Clamped as the contract requires — line to the last
line, column to that line's UTF-16 width — because clamping is the frozen contract, not an
implementation detail of the operation under test. -/
private def naiveOffset (source : String) (position : Lean.Lsp.Position) : Nat :=
  Id.run do
    let lines := lspLines source
    let line := min position.line (lines.size - 1)
    let mut offset := 0
    for index in [0:line]do
      offset := offset + lines[index]!.utf8ByteSize
    let body := lines[line]!
    let mut units := 0
    for c in body.toList do
      if c == '\n' then
        break
      if units >= position.character then
        break
      units := units + (if c.val ≤ 0xFFFF then 1 else 2)
      offset := offset + (String.singleton c).utf8ByteSize
    return offset

/-- The same change the server applies, resolved independently and spliced by byte offset. -/
private def naiveApply (source : String) : Lean.Lsp.TextDocumentContentChangeEvent → String
  | .rangeChange range newText =>
    let start := naiveOffset source range.start
    let stop := max start (naiveOffset source range.end)
    let bytes := source.toUTF8
    let slice (lo hi : Nat) := String.fromUTF8! (bytes.extract lo hi)
    slice 0 start ++ (LosslessSource.normalize newText).1 ++ slice stop bytes.size
  | .fullChange newText => (LosslessSource.normalize newText).1

private def rangeChange (startLine startCharacter stopLine stopCharacter : Nat) (newText : String) :
    Lean.Lsp.TextDocumentContentChangeEvent :=
  .rangeChange { start := ⟨startLine, startCharacter⟩, «end» := ⟨stopLine, stopCharacter⟩ } newText

private def testLanguageServerDocuments : IO Unit := do
  -- `lineBytes` excludes the terminator, and the terminator is one byte because the document is
  -- normalized. An astral character must not be counted as its byte width.
  let astral := Lean.FileMap.ofString "def 𝔘 := 1\nsecond\n"
  ensure (lineBytes astral 0 == (0, 13)) "the first line's byte range moved"
  ensure (lineBytes astral 1 == (14, 20)) "the second line's byte range moved"
  -- Clamping. The measured trap: without it, LSP (0,9999) resolves past the end of the buffer.
  let document := Lean.FileMap.ofString "theorem t : 𝔘 = 𝔘 := rfl\nsecond line\n"
  -- The line is 24 codepoints and 26 UTF-16 units; clamping is to the latter.
  ensure ((clampPosition document ⟨0, 9999⟩).character == 26)
      "an out-of-range column no longer clamps to the line's UTF-16 width"
  ensure ((clampPosition document ⟨99, 0⟩).line == 2)
      "an out-of-range line no longer clamps to the last line"
  ensure (offsetOf document ⟨0, 9999⟩ <= document.source.utf8ByteSize)
      "a clamped position still resolves past the end of the document"
  ensure (offsetOf document ⟨99, 99⟩ <= document.source.utf8ByteSize)
      "a doubly out-of-range position still resolves past the end of the document"
  -- Outward conversion, and the round trip on a boundary offset.
  ensure ((positionOf document 24).character == 20) "the outward UTF-16 column moved"
  ensure (offsetOf document (positionOf document 24) == 24)
      "a boundary offset no longer round-trips through an LSP position"
  -- **Obligation 2.** Every change sequence, applied incrementally, must equal the same sequence
  -- resolved and spliced independently. The documents cover ASCII, multi-byte BMP, astral, and CRLF;
  -- the sequences cover insert, delete, replace-across-lines, a change at a line boundary, an
  -- inverted range, and an out-of-range range.
  let documents : Array String :=
    #["def a := 1\ndef b := 2\n", "def α := 1\n-- a ligature: ﬁ\ndef b := 2\n",
      "def 𝔘 := 1\ndef b := 𝔘 + 𝔘\n", "def a := 1\r\ndef b := 2\r\n", "", "no trailing newline"]
  let sequences : Array (Array Lean.Lsp.TextDocumentContentChangeEvent) :=
    #[#[rangeChange 0 0 0 0 "-- header\n"], #[rangeChange 0 4 0 5 "renamed"],
      #[rangeChange 0 0 1 0 ""], #[rangeChange 0 10 1 0 " "],
      #[rangeChange 0 5 0 5 "𝔘", rangeChange 1 0 1 3 "let "],
      -- Inverted: the end precedes the start. Both must resolve it the same way.
      #[rangeChange 1 4 0 2 "X"],
      -- Out of range in both coordinates.
      #[rangeChange 0 9999 99 9999 "tail"], #[.fullChange "def replaced := 3\r\n"],
      #[rangeChange 0 0 0 0 "a", rangeChange 0 1 0 1 "b", rangeChange 0 2 0 2 "𝔘"]]
  for source in documents do
    let (normalized, _) := LosslessSource.normalize source
    for changes in sequences do
      let incremental := (applyChanges (Lean.FileMap.ofString normalized) changes).source
      let independent := changes.foldl naiveApply normalized
      ensure (incremental == independent)
          s!"incremental application diverged from an independent splice\n\
          source: {repr source}\n\
          incremental: {repr incremental}\n\
          independent: {repr independent}"
  -- A full change replaces the document and normalizes it, so a CRLF payload cannot smuggle raw
  -- bytes into the coordinate system every offset shares.
  let replaced := applyChange (Lean.FileMap.ofString "old\n") (.fullChange "a\r\nb\r\n")
  ensure (replaced.source == "a\nb\n") "a full change no longer normalizes its payload"

/-- Frame reading, over a buffer stream: the recovery behavior a line reader never needed and an
editor session cannot do without. -/
private def testLanguageServerFrames : IO Unit := do
  let framesOf (input : String) : IO (Array String) := do
    let buffer ← IO.mkRef { data := input.toUTF8, pos := 0 : IO.FS.Stream.Buffer }
    let stream := IO.FS.Stream.ofBuffer buffer
    let rec go (acc : Array String) : Nat → IO (Array String)
      | 0 => return acc.push "fuel"
      | fuel + 1 => do
        match ← readFrame stream with
        | .closed =>
          return acc.push "closed"
        | .malformed detail =>
          go (acc.push s!"malformed: {detail}") fuel
        | .message json =>
          go (acc.push s!"message: {json.compress}") fuel
    go #[] 16
  let ok ← framesOf "Content-Length: 12\r\n\r\n{\"id\":true}\n"
  ensure (ok == #["message: {\"id\":true}", "closed"])
      s!"a well-formed frame no longer reads cleanly: {ok}"
  -- A bad header drains its own block, so the frame after it reads normally. Without the drain, the
  -- blank line terminating the bad block reads as end of input and the session stops early.
  let recovered ←
    framesOf "Content-Length: nope\r\nX-Other: 1\r\n\r\nContent-Length: 12\r\n\r\n{\"id\":true}\n"
  ensure
      (recovered.size == 3 && recovered[1]! == "message: {\"id\":true}" &&
        recovered[2]! == "closed")
      s!"a malformed header no longer recovers at the next frame: {recovered}"
  let badBody ← framesOf "Content-Length: 3\r\n\r\n{,}Content-Length: 12\r\n\r\n{\"id\":true}\n"
  ensure (badBody.size == 3 && badBody[1]! == "message: {\"id\":true}")
      s!"an unparseable body no longer recovers at the next frame: {badBody}"
  -- A header block with no `Content-Length` is a malformed message, not end of input.
  let noLength ← framesOf "X-Other: 1\r\n\r\n"
  ensure (noLength == #["malformed: message header has no Content-Length", "closed"])
      s!"a header block without Content-Length no longer reports as malformed: {noLength}"
  -- A body shorter than its declared length is a truncated stream, not a message.
  let truncated ← framesOf "Content-Length: 64\r\n\r\n{\"id\":1}"
  ensure (truncated == #["closed"]) s!"a truncated body no longer ends the session: {truncated}"

end LanguageServerDocuments

/-- The cases this module contributes to the unit runner, in run order. -/
public def cases : Array Case :=
  #[{ name := "testLspPositions", run := testLspPositions },
    { name := "testLanguageServerDocuments", run := testLanguageServerDocuments },
    { name := "testLanguageServerFrames", run := testLanguageServerFrames }]

end LeanFmt.Test.Unit.Lsp
