module

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

private def ensure (condition : Bool) (message : String) : IO Unit :=
  unless condition do
    throw <| IO.userError message

private def testDigests : IO Unit := do
  ensure (toString (Digest.ofString "") ==
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    "SHA-256 empty-string vector failed"
  ensure (toString (Digest.ofString "abc") ==
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    "SHA-256 abc vector failed"
  ensure (toString (Digest.ofString
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    "SHA-256 multi-block vector failed"
  ensure (Digest.parse? (toString (Digest.ofString "abc"))).isSome
    "valid SHA-256 digest was rejected"
  ensure (Digest.parse?
    "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD").isNone
    "uppercase digest was accepted"
  ensure (Digest.parse? "abc").isNone "truncated digest was accepted"

/- Rules run on the normalized source, never on the file's bytes. That is not a convenience: the
parser normalizes before it assigns any offset, so findings measured against raw bytes would land in
a different coordinate system than the projection they share an artifact with. -/
private def testRules : IO Unit := do
  let raw := "def x := 1  \r\n#check x\t"
  let (normalized, lineEndings) := LosslessSource.normalize raw
  ensure (lineEndings == .crlf) "a CRLF source was not recognized as CRLF"
  ensure (normalized == "def x := 1  \n#check x\t") "normalization is not crlfToLf"
  ensure (LosslessSource.denormalize normalized lineEndings == raw)
    "denormalize is not the inverse of normalize on accepted source"
  ensure ((LosslessSource.normalize normalized) == (normalized, .lf))
    "normalization is not idempotent"

  -- Trailing-whitespace and final-newline normalization is the **formatter's** layout, not a lint rule
  -- (`ruff-11c` RDF-LAYOUT): both rules were retired, so the source rules are silent on both, even on
  -- this trailing-whitespace, no-final-newline fixture. The printer owns the normalization; that it does
  -- so soundly (never touching a string literal's interior) is proved in formatter/mode suites.
  --
  -- This once named the retired codes FMT001/FMT002 explicitly, in a `f.code != …` guard. The
  -- renumbering (`docs/rules/MIGRATION.md`) reassigned both codes to the live security rules, which
  -- would have turned that guard into "the security rules never fire" -- vacuously true on this
  -- fixture, and a silent hole exactly where the strongest rules are. The by-name guard is gone; the
  -- emptiness assertion below is what the case was always really claiming.
  let findings := runSourceRules normalized
  ensure (findings.isEmpty)
    "the default source rules should be silent on trailing whitespace and a missing final newline"

/-- `FMT001`/`FMT002`: forbidden control bytes and suspicious bidirectional controls. A control byte
or bidi mark only reaches accepted source inside a string literal or comment (bare occurrences are
parse errors, `notes/01-catalog.md` §2), so those are the positions exercised here; ranges are
byte-exact in normalized coordinates and both rules are report-only. -/
private def testSourceSecurityRules : IO Unit := do
  let ctl (n : Nat) : String := String.ofList [Char.ofNat n]
  -- NUL inside a string literal, RLO (U+202E) inside a line comment.
  let src := "def s := \"a" ++ ctl 0x00 ++ "b\"\n-- x" ++ ctl 0x202e ++ "y\n"
  let security := (runSourceRules src).filter fun f => f.code == "FMT001" || f.code == "FMT002"
  ensure (security.map (·.code) == #["FMT001", "FMT002"])
    "control/bidi coverage or sort order changed"
  ensure (security.all fun f => f.fix?.isNone)
    "a source-security rule produced a fix; both are report-only by construction"
  ensure (security.all fun f => f.severity == .warning) "source-security severity changed"
  ensure (security[0]!.range == { start := 11, stop := 12 } &&
      security[0]!.message == "forbidden control byte U+0000")
    "FMT001 range or message is not byte-exact"
  ensure (security[1]!.range == { start := 19, stop := 22 } &&
      security[1]!.message == "suspicious bidirectional control U+202E")
    "FMT002 range is not the mark's exact three-byte span, or its message changed"
  -- A two-byte mark (ALM U+061C) gets a two-byte range: width is the scalar's, not a constant.
  let alm := (runSourceRules ("-- " ++ ctl 0x061c ++ "\n")).filter (·.code == "FMT002")
  ensure (alm.size == 1 && alm[0]!.range == { start := 3, stop := 5 } &&
      alm[0]!.message == "suspicious bidirectional control U+061C")
    "FMT002 width or zero-padded hex is wrong for a two-byte mark"
  -- DEL (0x7F) is forbidden; TAB (0x09) and LF (0x0A) are not.
  ensure (((runSourceRules ("-- " ++ ctl 0x7f ++ "\n")).filter (·.code == "FMT001")).size == 1)
    "DEL (0x7F) was not flagged as a forbidden control byte"
  ensure ((runSourceRules "def a := 1\n\tx := 2\n").all fun f => f.code != "FMT001" && f.code != "FMT002")
    "TAB or LF was flagged as a forbidden control byte"

/- Property/fuzz boundary test for the two source-security scans.

The live scans are checked differentially against an *independent* oracle: FMT001 by an explicit byte
predicate, FMT002 by explicit codepoint-list membership — neither reuses `Rules.lean`'s private
`isForbiddenControl`/`isBidiControl`, so a drift in either the byte set or the offset arithmetic fails
here. The oracle sorts by the same (start, stop, code) key `findingOrder` uses, so the comparison also
pins the sort. Inputs are generated by a deterministic LCG over a pool that mixes forbidden controls,
allowed controls (TAB/LF), every bidi width, safe ASCII, and safe multibyte scalars up to four bytes,
so a mark's byte offset must be carried correctly for the ranges to line up. The scan is a pure
function of the string — acceptance decides only which strings can *reach* it, never what it computes —
so feeding arbitrary generated strings tests strictly more than accepted source would. -/
private def testSourceSecurityProperties : IO Unit := do
  let forbidden (n : Nat) : Bool := (n < 0x20 && n != 0x09 && n != 0x0a) || n == 0x7f
  let bidiSet : List Nat :=
    [0x061c, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069]
  -- Independent expectation: FMT001 per forbidden byte, FMT002 per bidi scalar, in findingOrder.
  let oracle (s : String) : Array (String × Nat × Nat) := Id.run do
    let mut acc : Array (String × Nat × Nat) := #[]
    let bytes := s.toUTF8
    for i in [0:bytes.size] do
      if forbidden (bytes.get! i).toNat then acc := acc.push ("FMT001", i, i + 1)
    let mut pos := 0
    for c in s.toList do
      if bidiSet.contains c.toNat then acc := acc.push ("FMT002", pos, pos + c.utf8Size)
      pos := pos + c.utf8Size
    return acc.qsort fun a b =>
      if a.2.1 != b.2.1 then a.2.1 < b.2.1
      else if a.2.2 != b.2.2 then a.2.2 < b.2.2
      else a.1 < b.1
  let actual (s : String) : Array (String × Nat × Nat) :=
    (runSourceRules s).filterMap fun f =>
      if f.code == "FMT001" || f.code == "FMT002" then some (f.code, f.range.start, f.range.stop)
      else none
  let check (s : String) : IO Unit := do
    ensure (actual s == oracle s)
      "a source-security scan disagreed with the independent oracle on a generated input"
    ensure ((runSourceRules s).all fun f =>
        (f.code != "FMT001" && f.code != "FMT002") || f.fix?.isNone)
      "a source-security rule emitted a fix on a generated input; both are report-only"
  -- Pool: forbidden controls, allowed controls, every bidi width, safe ASCII, safe 2/3/4-byte scalars.
  let pool : Array Nat :=
    #[0x00, 0x07, 0x1b, 0x1f, 0x7f, 0x09, 0x0a,
      0x061c, 0x200f, 0x202a, 0x202e, 0x2066, 0x2069,
      0x41, 0x20, 0x30, 0x22, 0x2f, 0xe9, 0x4e2d, 0x1f600]
  let mut seed : Nat := 0x9e3779b9
  for _ in [0:120] do
    seed := (seed * 1103515245 + 12345) % 2147483648
    let len := seed % 48
    let mut s := ""
    for _ in [0:len] do
      seed := (seed * 1103515245 + 12345) % 2147483648
      s := s.push (Char.ofNat pool[seed % pool.size]!)
    check s
  -- Targeted edges the LCG need not hit: empty, all-forbidden run, control adjacent to a bidi mark,
  -- and a mark at the final byte position.
  check ""
  check (String.ofList (List.replicate 8 (Char.ofNat 0x00)))
  check (String.ofList [Char.ofNat 0x00, Char.ofNat 0x202e, Char.ofNat 0x1b])
  check (String.ofList [Char.ofNat 0x41, Char.ofNat 0x4e2d, Char.ofNat 0x202e])

/-- Parse a surface header, refusing the `none` (parser-message) case the caller never intends. -/
private def parseHeader! (source : String) : IO Imports.HeaderModel := do
  match ← Imports.parseHeaderModel source with
  | some header => return header
  | none => throw <| IO.userError s!"header did not parse: {source}"

/-- `FMT003`/`FMT004`/`FMT005` and the organizer, tested directly — import rules live outside the
`RuleImpl` engine (`notes/01-semantics.md` §1b, §7), so the `runRulesOf` seam does not reach them; the
header rules are pure functions of the parsed surface header, and `redundantFindings` is pure over the
header plus a caller-supplied closure that stands in for the Lake graph. -/
private def testImports : IO Unit := do
  -- The surface header carries the modifier spelling, not the abstract import: `import all A` and
  -- `import A` are distinct statements, so neither is the other's duplicate (`notes` §3).
  let dup ← parseHeader! "import Foo.A\nimport Foo.A\n"
  let dupFindings := Imports.duplicateFindings dup "import Foo.A\nimport Foo.A\n"
  ensure (dupFindings.map (·.code) == #["FMT003"]) "exact duplicate did not fire FMT003 exactly once"
  ensure (dupFindings[0]!.fix?.map (·.applicability) == some .safe)
    "the duplicate-removal fix is not safe"
  -- The safe fix deletes the *later* whole line (the second `import Foo.A`, bytes [13, 26)).
  ensure (dupFindings[0]!.fix?.map (·.edits) == some #[{ range := { start := 13, stop := 26 }, replacement := "" }])
    "the duplicate fix does not delete the later line"

  -- `import all` is valid header syntax only under a `module` marker.
  let notDupSrc := "module\nimport Foo.A\nimport all Foo.A\n"
  let notDup ← parseHeader! notDupSrc
  ensure (Imports.duplicateFindings notDup notDupSrc).isEmpty
    "`import A` and `import all A` were wrongly treated as duplicates"

  -- A literal `import Init` twice is a surface duplicate — it is the phantom `Init` the abstract list
  -- injects that a surface rule can never see, not a written one (`notes` §1a).
  let dupInit ← parseHeader! "import Init\nimport Init\n"
  ensure ((Imports.duplicateFindings dupInit "import Init\nimport Init\n").size == 1)
    "a literal repeated `import Init` did not fire FMT003"

  -- FMT005 fires within one group; a blank line is a group boundary the canonical order never crosses.
  let unordered ← parseHeader! "import Foo.B\nimport Foo.A\n"
  ensure ((Imports.orderFindings unordered "import Foo.B\nimport Foo.A\n").map (·.code) == #["FMT005"])
    "out-of-order imports in one group did not fire FMT005"
  ensure ((Imports.orderFindings unordered "import Foo.B\nimport Foo.A\n")[0]!.fix?.isNone)
    "FMT005 must be report-only (no fix)"
  let grouped ← parseHeader! "import Foo.B\n\nimport Foo.A\n"
  ensure (Imports.orderFindings grouped "import Foo.B\n\nimport Foo.A\n").isEmpty
    "imports in different blank-line groups were wrongly reported out of order"

  -- FMT004: `Foo.B` is reachable via `Foo.A`'s closure, so the plain `import Foo.B` is a candidate.
  let redundant ← parseHeader! "import Foo.A\nimport Foo.B\n"
  let closure : Lean.Name → Option (Array Lean.Name) := fun name =>
    if name == `Foo.A then some #[`Foo.B] else none
  let (redFindings, redWithheld) := Imports.redundantFindings redundant closure
  ensure (redFindings.map (·.code) == #["FMT004"]) "a transitively-covered import did not fire FMT004"
  ensure (redFindings[0]!.fix?.isNone) "FMT004 must be report-only (no fix)"
  ensure (redWithheld == 0) "a plain covered import was wrongly withheld"

  -- Withholding: `import all Foo.B` under a `module` marker exposes data reachability cannot reason
  -- about, so it is withheld (counted), never reported.
  let withheld ← parseHeader! "module\nimport Foo.A\nimport all Foo.B\n"
  let (whFindings, whCount) := Imports.redundantFindings withheld closure
  ensure (whFindings.isEmpty) "an `import all` redundancy candidate was reported rather than withheld"
  ensure (whCount == 1) "the withheld-redundancy count was not recorded"
  ensure (!Imports.redundancyEligible withheld withheld.imports[1]!)
    "`import all` was judged redundancy-eligible"

  -- The organizer: dedup composed with per-group sort, everything else preserved. Text in, text out.
  let sortMe := "import Foo.B\nimport Foo.A\n"
  ensure (Imports.organize (← parseHeader! sortMe) sortMe == "import Foo.A\nimport Foo.B\n")
    "the organizer did not sort a group by module name"
  let dedupMe := "import Foo.A\nimport Foo.A\n"
  ensure (Imports.organize (← parseHeader! dedupMe) dedupMe == "import Foo.A\n")
    "the organizer did not remove a duplicate"

  -- RIR-FINAL: header rewrites preserve comments, modifiers, and group boundaries (`roadmap.md` §19).
  -- A comment is a group boundary: each group sorts independently and the comment survives verbatim.
  let twoGroups := "import Foo.D\nimport Foo.A\n-- section\nimport Foo.Z\nimport Foo.B\n"
  ensure (Imports.organize (← parseHeader! twoGroups) twoGroups ==
      "import Foo.A\nimport Foo.D\n-- section\nimport Foo.B\nimport Foo.Z\n")
    "the organizer did not sort each comment-delimited group while preserving the comment"
  -- A trailing inline comment forces a boundary: the two imports are not reordered across it.
  let trailing := "import Foo.B -- note\nimport Foo.A\n"
  ensure (Imports.organize (← parseHeader! trailing) trailing == trailing)
    "the organizer reordered across a trailing comment or dropped it"
  -- A modifier rides on the sliced statement bytes through a reorder (`import all` needs `module`).
  let modifier := "module\nimport all Foo.B\nimport Foo.A\n"
  ensure (Imports.organize (← parseHeader! modifier) modifier ==
      "module\nimport Foo.A\nimport all Foo.B\n")
    "the organizer dropped a modifier while reordering"

  -- A `prelude` file has no phantom `Init`: the surface model sees only the written imports (`notes` §1a).
  let prelude ← parseHeader! "prelude\nimport Foo.A\n"
  ensure (prelude.hasPrelude && prelude.imports.map (·.module) == #[`Foo.A])
    "the prelude header model does not match the written imports"

/-- `ruff-17` RLP-PROTOCOL, `notes/01-protocol.md` §4: the LSP position layer, characterized before
anything is built on it.

Two claims, both of which survive casual testing if they go untested. First, LSP columns are UTF-16
code units and `Application.PositionIndex`'s are codepoints, so the two disagree outside the BMP and
only outside it — reaching for `PositionIndex` in the server would be silently wrong on exactly the
inputs nobody types by hand. Second, `Lean.FileMap`'s conversion is a conversion and not a validator:
an out-of-range position produces an offset past the end of the document rather than an error, so the
server clamps every inbound position itself.

`𝔘` (U+1D518) is 4 UTF-8 bytes, 2 UTF-16 code units, and 1 codepoint, so one character separates all
three encodings. It is the same fixture `ruff-15` used for the reporting columns
(`tests/reporting/run.sh`, "codepoint columns are neither bytes nor UTF-16"). -/
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
  let codepointIndex := Application.PositionIndex.ofSource "A.lean" source
    #[{ code := "TEST", severity := .warning, message := "probe",
        range := { start := 24, stop := 25 }, fix? := none }]
  match (Application.PositionIndex.position? codepointIndex "A.lean" 24 :
      Option Application.Position) with
  | some reported =>
    -- Three distinct numbers for one offset: codepoint column 19 (what we report), UTF-16 column 20
    -- (what LSP means), byte column 25 (what neither means).
    ensure (reported.line == 1 && reported.column == 19)
      "the reported codepoint column moved"
    ensure (reported.column != afterAstral.character)
      "codepoint and UTF-16 columns agree here, so this fixture no longer pins the difference"
  | none => throw <| IO.userError "PositionIndex did not resolve an offset it was given"

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
  ensure ((rawMap.lspPosToUtf8Pos ⟨1, 0⟩).byteIdx == 12)
    "the raw CRLF line start moved"
  ensure ((normalizedMap.lspPosToUtf8Pos ⟨1, 0⟩).byteIdx == 11)
    "the normalized line start moved"

/-! ### The language server's document layer (`ruff-17` RLP-DOCUMENTS)

`notes/01-protocol.md` §4 and §6. The differential test below is obligation 2 of the freeze, and it is
the one obligation whose failure would corrupt a user's file rather than merely annoy them. -/

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
lines, then walk this line counting UTF-16 units. Clamped as `notes` §4 requires — line to the last
line, column to that line's UTF-16 width — because clamping is the frozen contract, not an
implementation detail of the operation under test. -/
private def naiveOffset (source : String) (position : Lean.Lsp.Position) : Nat := Id.run do
  let lines := lspLines source
  let line := min position.line (lines.size - 1)
  let mut offset := 0
  for index in [0:line] do
    offset := offset + lines[index]!.utf8ByteSize
  let body := lines[line]!
  let mut units := 0
  for c in body.toList do
    if c == '\n' then break
    if units >= position.character then break
    units := units + (if c.val ≤ 0xFFFF then 1 else 2)
    offset := offset + (String.singleton c).utf8ByteSize
  return offset

/-- The same change the server applies, resolved independently and spliced by byte offset. -/
private def naiveApply (source : String) :
    Lean.Lsp.TextDocumentContentChangeEvent → String
  | .rangeChange range newText =>
    let start := naiveOffset source range.start
    let stop := max start (naiveOffset source range.end)
    let bytes := source.toUTF8
    let slice (lo hi : Nat) := String.fromUTF8! (bytes.extract lo hi)
    slice 0 start ++ (LosslessSource.normalize newText).1 ++ slice stop bytes.size
  | .fullChange newText => (LosslessSource.normalize newText).1

private def rangeChange (startLine startCharacter stopLine stopCharacter : Nat)
    (newText : String) : Lean.Lsp.TextDocumentContentChangeEvent :=
  .rangeChange
    { start := ⟨startLine, startCharacter⟩, «end» := ⟨stopLine, stopCharacter⟩ } newText

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
  let documents : Array String := #[
    "def a := 1\ndef b := 2\n",
    "def α := 1\n-- a ligature: ﬁ\ndef b := 2\n",
    "def 𝔘 := 1\ndef b := 𝔘 + 𝔘\n",
    "def a := 1\r\ndef b := 2\r\n",
    "",
    "no trailing newline"
  ]
  let sequences : Array (Array Lean.Lsp.TextDocumentContentChangeEvent) := #[
    #[rangeChange 0 0 0 0 "-- header\n"],
    #[rangeChange 0 4 0 5 "renamed"],
    #[rangeChange 0 0 1 0 ""],
    #[rangeChange 0 10 1 0 " "],
    #[rangeChange 0 5 0 5 "𝔘", rangeChange 1 0 1 3 "let "],
    -- Inverted: the end precedes the start. Both must resolve it the same way.
    #[rangeChange 1 4 0 2 "X"],
    -- Out of range in both coordinates.
    #[rangeChange 0 9999 99 9999 "tail"],
    #[.fullChange "def replaced := 3\r\n"],
    #[rangeChange 0 0 0 0 "a", rangeChange 0 1 0 1 "b", rangeChange 0 2 0 2 "𝔘"]
  ]
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
      | .closed => return acc.push "closed"
      | .malformed detail => go (acc.push s!"malformed: {detail}") fuel
      | .message json => go (acc.push s!"message: {json.compress}") fuel
    go #[] 16

  let ok ← framesOf "Content-Length: 12\r\n\r\n{\"id\":true}\n"
  ensure (ok == #["message: {\"id\":true}", "closed"])
    s!"a well-formed frame no longer reads cleanly: {ok}"

  -- A bad header drains its own block, so the frame after it reads normally. Without the drain, the
  -- blank line terminating the bad block reads as end of input and the session stops early.
  let recovered ← framesOf
    "Content-Length: nope\r\nX-Other: 1\r\n\r\nContent-Length: 12\r\n\r\n{\"id\":true}\n"
  ensure (recovered.size == 3 && recovered[1]! == "message: {\"id\":true}" &&
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

private def findingWithEdit (range : SourceRange) (replacement : String)
    (applicability : Applicability := .safe) (code : String := "TEST") : Finding := {
  code
  severity := .warning
  message := "test edit"
  range
  fix? := some { applicability, edits := #[{ range, replacement }] }
}

private def requirePatch (source : String) (findings : Array Finding) : IO Patch :=
  match preparePatch source findings with
  | .ok patch => pure patch
  | .error error => throw <| IO.userError s!"valid patch was rejected: {error}"

private def requireRevert (patch : Patch) : IO String :=
  match patch.revert with
  | .ok source => pure source
  | .error error => throw <| IO.userError s!"checked inverse was rejected: {error}"

private def ensureRejected (source : String) (findings : Array Finding)
    (accept : PatchError → Bool) (message : String) : IO Unit :=
  match preparePatch source findings with
  | .error error => ensure (accept error) s!"{message}: wrong rejection: {error}"
  | .ok _ => throw <| IO.userError message

private def testEdits : IO Unit := do
  -- Patch assembly over multi-byte input (`α` is two UTF-8 bytes), independent of any rule: two disjoint
  -- synthetic safe edits exercise the offset math, `editCount`, `changed`, and `revert`. (Trailing
  -- whitespace and the final newline are the formatter's layout now, tested in formatter and
  -- tests/modes — not a source-rule fix.)
  let source := "def α := 1  \n#check α"
  let patch ← requirePatch source #[
    findingWithEdit { start := 11, stop := 13 } "" .safe "SYN_A",
    findingWithEdit { start := source.utf8ByteSize, stop := source.utf8ByteSize } "\n" .safe "SYN_B"]
  ensure (patch.formatted == "def α := 1\n#check α\n")
    "rule edits did not produce the expected UTF-8 output"
  ensure patch.changed "nonempty edit set was reported unchanged"
  ensure (patch.editCount == 2) "patch lost selected edits"
  ensure (patch.matchesSource source) "patch lost its immutable source identity"
  ensure (!(patch.matchesSource (source ++ "\n"))) "stale source matched a checked patch"
  ensure ((← requireRevert patch) == source) "checked patch did not exactly reverse"

  let ordered := #[
    findingWithEdit { start := 0, stop := 1 } "A",
    findingWithEdit { start := 1, stop := 2 } "B"
  ]
  let reverseOrder := #[ordered[1]!, ordered[0]!]
  let adjacent ← requirePatch "xy" ordered
  let adjacentReverse ← requirePatch "xy" reverseOrder
  ensure (adjacent.formatted == "AB" && adjacentReverse.formatted == "AB")
    "adjacent edits were rejected or input order changed output"

  ensureRejected "abc" #[findingWithEdit { start := 1, stop := 4 } "x"]
    (fun | .invalidRange .. => true | _ => false)
    "out-of-range edit was accepted"
  ensureRejected "αb" #[findingWithEdit { start := 1, stop := 2 } "x"]
    (fun | .invalidBoundary .. => true | _ => false)
    "non-boundary UTF-8 edit was accepted"
  ensureRejected "abc" #[
      findingWithEdit { start := 0, stop := 2 } "x",
      findingWithEdit { start := 1, stop := 3 } "y"
    ] (fun | .conflict .. => true | _ => false)
    "overlapping replacements were accepted"
  ensureRejected "abc" #[
      findingWithEdit { start := 1, stop := 1 } "x",
      findingWithEdit { start := 1, stop := 1 } "y"
    ] (fun | .conflict .. => true | _ => false)
    "competing insertions were accepted"

  let propertySource := "aαβz"
  let boundaries := #[0, 1, 3, 5, 6]
  let replacements := #["", "x", "λ"]
  for start in boundaries do
    for stop in boundaries do
      if start <= stop then
        for replacement in replacements do
          let patch ← requirePatch propertySource
            #[findingWithEdit { start, stop } replacement]
          ensure ((← requireRevert patch) == propertySource)
            s!"single-edit reversibility failed at {start}-{stop}"

private def findingWithEdits (edits : Array Edit) (applicability : Applicability := .safe)
    (code : String := "TEST") : Finding := {
  code
  severity := .warning
  message := "test multi-edit"
  range := edits[0]?.map (·.range) |>.getD { start := 0, stop := 0 }
  fix? := some { applicability, edits }
}

/-- Adversarial fix-all cases for `RFX-FINAL`: mixed insert/delete/replace conflicts, multi-edit fixes
inside one transaction, that applicability is never an edit property, and that a safe rule fix leaves a
comment's text intact. The atomic-publish crash/stale cases live in `tests/modes/run.sh`, where a real
temp-file-then-rename is exercised. -/
private def testFixAllAdversarial : IO Unit := do
  -- Insert / delete / replace mixing. An insertion strictly inside a replacement is a conflict;
  -- adjacency at a shared boundary is not; a deletion beside a replacement composes.
  ensureRejected "abc" #[
      findingWithEdit { start := 0, stop := 2 } "X",
      findingWithEdit { start := 1, stop := 1 } "!"
    ] (fun | .conflict .. => true | _ => false)
    "an insertion inside a replacement was accepted"
  let boundary ← requirePatch "abc" #[
      findingWithEdit { start := 0, stop := 2 } "X",
      findingWithEdit { start := 2, stop := 2 } "!"]
  ensure (boundary.formatted == "X!c") "an insertion at a replacement's end boundary was mishandled"
  let deleteReplace ← requirePatch "abcd" #[
      findingWithEdit { start := 0, stop := 1 } "",
      findingWithEdit { start := 1, stop := 2 } "X"]
  ensure (deleteReplace.formatted == "Xcd") "a deletion beside a replacement did not compose"

  -- One `Fix` may carry several edits; they are one transaction. Disjoint edits apply together and
  -- revert exactly; overlapping edits within a single fix still reject, naming that fix on both sides.
  let multi ← requirePatch "abcd" #[findingWithEdits #[
      { range := { start := 0, stop := 1 }, replacement := "X" },
      { range := { start := 2, stop := 3 }, replacement := "Y" }] .safe "MULTI"]
  ensure (multi.formatted == "XbYd") "a multi-edit fix did not apply as one transaction"
  ensure ((← requireRevert multi) == "abcd") "a multi-edit fix did not revert exactly"
  match preparePatch "abcd" #[findingWithEdits #[
      { range := { start := 0, stop := 2 }, replacement := "X" },
      { range := { start := 1, stop := 3 }, replacement := "Y" }] .safe "MULTI"] with
  | .error (.conflict left right _ _) =>
    ensure (left == "MULTI" && right == "MULTI") "an intra-fix conflict lost the fix's own provenance"
  | _ => throw <| IO.userError "overlapping edits within one fix were accepted"

  -- Mixed-tier conflict (`RYC-FINAL`): the conflict path carries no tier. A syntax-rule fix (`FMT011`)
  -- and an import-rule fix (`FMT003`) that overlap on the same original bytes reject and name BOTH
  -- rules. No file drives this — the shipped fixes are disjoint by design (the syntax `.safe` fixes edit
  -- paren/attribute ranges, FMT003 edits an import line, FMT012 renames a deprecated ident; none
  -- intersect), so the composition is exercised here at `preparePatch`, its owning layer. (After
  -- `ruff-11c` RDF-LAYOUT there is no source-tier fixable rule — trailing whitespace and the final
  -- newline are the formatter's layout, not lint rules.)
  match preparePatch "abc" #[
      findingWithEdit { start := 0, stop := 2 } "" .safe "FMT011",
      findingWithEdit { start := 1, stop := 3 } "" .safe "FMT003"] with
  | .error (.conflict left right _ _) =>
    ensure (#[left, right].qsort (· < ·) == #["FMT003", "FMT011"])
      "a mixed-tier syntax/import conflict did not name both rules distinctly"
  | _ => throw <| IO.userError "an overlapping syntax/import fix pair was accepted"

  -- Applicability governs admission, never bytes. The same edit safe or unsafe assembles identically;
  -- promotion/demotion decides whether `fix` applies it, upstream of the assembler.
  let asSafe ← requirePatch "abc" #[findingWithEdit { start := 0, stop := 1 } "X" .safe "R"]
  let asUnsafe ← requirePatch "abc" #[findingWithEdit { start := 0, stop := 1 } "X" .unsafe "R"]
  ensure (asSafe.formatted == asUnsafe.formatted && asSafe.formatted == "Xbc")
    "applicability changed the bytes a fix produces"

private def testConfig : IO Unit := do
  let directory ← IO.FS.createTempDir
  let configPath := directory / "lean-fmt.toml"
  -- Category/selector machinery is exercised on the source-tier `security` category (FMT001 control
  -- byte, FMT002 bidi mark), the sole source-tier vehicle after `ruff-11c` RDF-LAYOUT retired the
  -- `text` category (FMT001/FMT002) into the formatter. `redundancy` (FMT008/11/13, syntax) is the
  -- disjoint category that must select none of these findings.
  let ctl (n : Nat) : String := String.ofList [Char.ofNat n]
  let secBytes := "def s := \"a" ++ ctl 0x00 ++ "b\"\n-- x" ++ ctl 0x202e ++ "y\n"
  try
    IO.FS.writeFile configPath "\
include = [\"LeanFmt/**/*.lean\", \"Main.lean\"]\n\
exclude = [\"LeanFmt/Generated/**\"]\n\
select = [\"security\"]\n\
ignore = [\"FMT002\"]\n\
[per-file-ignores]\n\
\"LeanFmt/Legacy/*.lean\" = [\"FMT001\"]\n"
    let config ← FormatterConfig.load directory
    ensure (config.includesPath "LeanFmt/Internal/File.lean")
      "recursive include pattern did not match"
    ensure (config.includesPath "Main.lean") "root-file include pattern did not match"
    ensure (!(config.includesPath "LeanFmt/Generated/File.lean"))
      "exclude pattern did not win"
    ensure (!(config.includesPath "Other.lean")) "unmatched path was included"
    let .ok plan := config.rulePlan {}
      | throw <| IO.userError "valid configured selectors were rejected"
    -- Specificity precedence (`ruff-12`): config `ignore = [FMT002]` (exact) outranks `select = [security]`
    -- (category), so only FMT001 survives.
    ensure (plan.activeCount == 1) "configured ignore did not win"
    let findings := runSourceRules secBytes
    ensure ((plan.findings "LeanFmt/File.lean" findings).map (·.code) == #["FMT001"])
      "configured selector projection was wrong"
    ensure ((plan.findings "LeanFmt/Legacy/File.lean" findings).isEmpty)
      "per-file ignore did not win"
    let .ok cliPlan := config.rulePlan { select := #["FMT002"], ignore := #["FMT001"] }
      | throw <| IO.userError "valid CLI selectors were rejected"
    ensure (cliPlan.activeCount == 1 &&
      (cliPlan.findings "Main.lean" findings).map (·.code) == #["FMT002"])
      "CLI selection did not replace config selection or ignore precedence changed"
    ensure (match config.rulePlan { select := #["UNKNOWN"] } with | .error _ => true | .ok _ => false)
      "unknown CLI selector was accepted"
    -- The whole `security` category resolves through registry-derived category machinery — no hardcoded
    -- list. All security rules are stable, so no preview gate is needed to select them.
    let .ok secPlan := config.rulePlan { select := #["security"] }
      | throw <| IO.userError "the 'security' category selector was rejected"
    ensure ((secPlan.findings "A.lean" findings).map (·.code) == #["FMT001", "FMT002"])
      "the security category did not select both control-byte rules"
    -- Preview gate on a category selector (`ruff-12`), now over a MIXED category: `redundancy` holds
    -- FMT008 and FMT009 (preview) and FMT011 (stable, default-off — the `ruff-12b` "stable-optional"
    -- outcome). So the category resolves to exactly the stable member without preview mode, and to all
    -- three with it. The mixed case is the interesting one and did not exist before `ruff-12b`.
    let .ok gated := config.rulePlan { select := #["redundancy"] }
      | throw <| IO.userError "a partly-preview category was rejected"
    ensure (gated.selected == #["FMT011"])
      "the redundancy category did not resolve to exactly its stable member without preview mode"
    let .ok previewed := config.rulePlan { select := #["redundancy"], preview := true }
      | throw <| IO.userError "the preview category was rejected under preview mode"
    ensure (previewed.activeCount == 3) "preview mode did not unlock the redundancy category"
    -- `stable-optional`, stated directly (`ruff-12b` RGR-SPEC §1.1). FMT011 is reachable by `all`, by
    -- its category, and by its exact code with NO preview gate, and is absent from `default`. That
    -- combination is the whole outcome: promoted out of preview on correctness, kept off the default
    -- path on cost.
    ensure (match config.rulePlan { select := #["FMT011"] } with
      | .ok p => p.selected == #["FMT011"] | .error _ => false)
      "a stable default-off rule was not selectable by its exact code without preview mode"
    let .ok allSel := config.rulePlan { select := #["all"] }
      | throw <| IO.userError "the 'all' selector was rejected"
    ensure (allSel.selected.contains "FMT011")
      "'all' did not reach a stable default-off rule without preview mode"
    let .ok defSel := config.rulePlan { select := #["default"] }
      | throw <| IO.userError "the 'default' selector was rejected"
    ensure (!defSel.selected.contains "FMT011")
      "a stable default-off rule leaked into the default set"
    -- Explicit preview-code selection is still an error without preview mode, and succeeds with it.
    -- FMT008 carries this now that FMT011 is stable.
    ensure (match config.rulePlan { select := #["FMT008"] } with | .error _ => true | .ok _ => false)
      "an explicit preview-code selection was accepted without preview mode"
    ensure (match config.rulePlan { select := #["FMT008"], preview := true } with
      | .ok p => p.selected == #["FMT008"] | .error _ => false)
      "preview mode did not admit an explicit preview-code selection"
    -- Specificity keeps an exact select over a category ignore (the case flat subtraction dropped).
    let .ok keep := config.rulePlan { select := #["FMT011"], ignore := #["redundancy"] }
      | throw <| IO.userError "exact-vs-category precedence rejected a valid plan"
    ensure (keep.selected == #["FMT011"]) "an exact select did not outrank a category ignore"
    -- A retired code is accepted (non-breaking), selects no rule, and raises a notice -- REMOVED with
    -- the rest of the retired-code coverage (`docs/rules/MIGRATION.md`). It selected FMT001, which the
    -- renumbering turned into a live default security rule, so the case would now assert that
    -- selecting a live rule yields an empty plan. There is no code left that can exercise this path:
    -- with `reservedCodes` empty, `selectorsValid` rejects anything that is not live, so "accepted
    -- with a notice" has no possible input until a rule retires.
    -- Fixability axis: a selected rule made unfixable is still selected, but out of `fixableSelected`.
    let .ok unfix := config.rulePlan { select := #["FMT011"], unfixable := #["FMT011"] }
      | throw <| IO.userError "the unfixable axis rejected a valid plan"
    ensure (unfix.selected == #["FMT011"] && unfix.fixableSelected.isEmpty)
      "unfixable did not withhold FMT011's fix while keeping it selected"
    -- RRL-FINAL precedence matrix — the remaining lattice edges beyond the cases above.
    -- (a) Tie → ignore: an exact select and an exact ignore of the same code are equal specificity, so
    -- ignore wins and the rule is dropped.
    let .ok tie := config.rulePlan { select := #["FMT002"], ignore := #["FMT002"] }
      | throw <| IO.userError "an exact select/ignore tie was rejected"
    ensure (tie.activeCount == 0) "an exact select/ignore tie did not resolve to ignore"
    -- (b) `all` expands to the stable set; `default` expands to the default-ON set. Since `ruff-12b`
    -- these DIFFER — FMT011 is stable and default-off — and that divergence is the point of the
    -- `stable-optional` outcome, so it is asserted rather than assumed away. Neither admits a preview
    -- rule without the gate; `all` + preview unlocks the whole registry.
    let stableCount := (allRuleInfos.filter (·.lifecycle == .stable)).size
    let defaultCount := (allRuleInfos.filter (·.defaultEnabled)).size
    ensure (defaultCount < stableCount)
      "no stable rule is default-off, so the stable-optional outcome has no live instance"
    let .ok allPlan := config.rulePlan { select := #["all"] }
      | throw <| IO.userError "the 'all' selector was rejected"
    let .ok defPlan := config.rulePlan { select := #["default"] }
      | throw <| IO.userError "the 'default' selector was rejected"
    ensure (allPlan.activeCount == stableCount)
      "'all' did not expand to exactly the stable set without preview"
    ensure (defPlan.activeCount == defaultCount)
      "'default' did not expand to exactly the default-enabled set"
    let .ok allPreview := config.rulePlan { select := #["all"], preview := true }
      | throw <| IO.userError "'all' under preview was rejected"
    ensure (allPreview.activeCount == allRuleInfos.size)
      "'all' under preview did not unlock the whole registry"
    -- (c) `extend-select` always adds, across the CLI-owns-selection boundary: with no CLI `select`, the
    -- config selection (security minus the config's exact `ignore = [FMT002]`) still applies, and a CLI
    -- extend-select adds FMT011 on top (no preview gate needed since `ruff-12b`). Result: FMT001 + FMT011.
    let .ok extended := config.rulePlan { extendSelect := #["FMT011"] }
      | throw <| IO.userError "extend-select over the config selection was rejected"
    ensure (extended.selected == #["FMT001", "FMT011"])
      "extend-select did not add to the config selection while keeping the config ignore"
    IO.FS.writeFile configPath "unknown = true\n"
    let rejected ← try
      discard <| FormatterConfig.load directory
      pure false
    catch _ => pure true
    ensure rejected "unknown configuration key was accepted"
  finally
    IO.FS.removeDirAll directory

/-- Hierarchical configuration discovery (`ruff-13` RCD-IMPL; `notes/01-discovery.md` §3–§12).

Everything here is filesystem-real: a temporary tree with actual config files, actual `.gitignore`
files, and actual sources, walked by the same `Discovery.run` a real run uses. A unit test that hands a
hand-built `FormatterConfig` to the matcher would pass while discovery picked the wrong file, which is
the failure this stack exists to prevent.

`.gitignore` handling is asserted through `Discovery.run` rather than against the pattern compiler
directly, for the same reason: the compiler being right about `build/` is worth nothing if the walk
does not prune `build/` — and pruning, not per-file matching, is what git's directory-exclusion rule
licenses (§10). -/
private def testDiscovery : IO Unit := do
  let directory ← IO.FS.createTempDir
  let root ← IO.FS.realPath directory
  let write (relative content : String) : IO Unit := do
    let path := root / System.FilePath.mk relative
    if let some parent := path.parent then IO.FS.createDirAll parent
    IO.FS.writeFile path content
  try
    -- §3 both recognized names present is a hard error, never a silent precedence win.
    write ".lean-fmt.toml" "[lint]\nselect = [\"security\"]\n"
    write "lean-fmt.toml" "[lint]\nselect = [\"all\"]\n"
    let ambiguous ← try discard <| Discovery.run root none; pure false catch _ => pure true
    ensure ambiguous "two recognized configuration names in one directory were accepted"
    IO.FS.removeFile (root / "lean-fmt.toml")
    -- §5 the closest config wins outright: `sub` does not inherit the root's `exclude`, and the root
    -- does not acquire `sub`'s width. No implicit merging.
    write ".lean-fmt.toml" "\
exclude = [\"skipped\"]\n\
[format]\n\
line-width = 60\n"
    write "sub/.lean-fmt.toml" "[format]\nline-width = 42\n"
    write "A.lean" "module\n"
    write "sub/B.lean" "module\n"
    write "skipped/C.lean" "module\n"
    write "sub/skipped/D.lean" "module\n"
    let discovery ← Discovery.run root none
    ensure ((discovery.configFor "A.lean").format.lineWidth == 60)
      "the root configuration did not govern a root file"
    ensure ((discovery.configFor "sub/B.lean").format.lineWidth == 42)
      "the closest configuration did not govern a nested file"
    ensure ((discovery.configFor "sub/B.lean").excludePatterns.isEmpty)
      "the nested configuration inherited the root's exclude — the hierarchy must not merge"
    ensure (discovery.explain "skipped/C.lean" == .configExclude)
      "an excluded directory's contents were not reported as configuration-excluded"
    ensure (discovery.explain "sub/skipped/D.lean" == .selected)
      "the root's exclude reached a subtree its own configuration governs"
    ensure (discovery.configKeyFor "A.lean" != discovery.configKeyFor "sub/B.lean")
      "two distinct effective configurations shared one plan key"
    -- §6 `extend` composes: scalars and base arrays replace, `extend-*` concatenates, and `extend`
    -- itself is not inherited. §7 patterns anchor at the *declaring* file's directory.
    write "base.toml" "\
[format]\n\
line-width = 90\n\
[lint]\n\
select = [\"security\"]\n\
extend-select = [\"FMT008\"]\n"
    write "sub/.lean-fmt.toml" "\
extend = \"../base.toml\"\n\
[format]\n\
line-width = 42\n\
[lint]\n\
extend-select = [\"FMT009\"]\n"
    let extended ← Discovery.run root none
    let child := extended.configFor "sub/B.lean"
    ensure (child.format.lineWidth == 42) "the extending file did not win a scalar"
    ensure (child.selectedSelectors == #["security"]) "the parent's base array was not inherited"
    ensure (child.extendSelectSelectors == #["FMT008", "FMT009"])
      "extend-select did not concatenate parent-then-child"
    ensure (child.contributingFiles.size == 2)
      "the extend chain did not record both contributing files"
    -- §6 a cycle terminates as an error rather than a hang or a depth-limit surprise.
    write "cycle-a.toml" "extend = \"cycle-b.toml\"\n"
    write "cycle-b.toml" "extend = \"cycle-a.toml\"\n"
    write "sub/.lean-fmt.toml" "extend = \"../cycle-a.toml\"\n"
    let cyclic ← try discard <| Discovery.run root none; pure false catch _ => pure true
    ensure cyclic "an extend cycle was accepted"
    IO.FS.removeFile (root / "sub" / ".lean-fmt.toml")
    -- §8.2 migration: a flat linter key still works and says so; setting it in both places is an
    -- error; `line-width` at the top level is an error rather than a silent no-op.
    write ".lean-fmt.toml" "select = [\"security\"]\n"
    let migrated ← Discovery.run root none
    ensure (migrated.fallback.selectedSelectors == #["security"])
      "a flat linter key stopped working"
    ensure (migrated.fallback.notices.any fun notice => (notice.splitOn "select").length > 1)
      "a flat linter key produced no deprecation notice"
    write ".lean-fmt.toml" "select = [\"security\"]\n[lint]\nselect = [\"all\"]\n"
    let both ← try discard <| Discovery.run root none; pure false catch _ => pure true
    ensure both "the same linter key set flat and under [lint] was accepted"
    write ".lean-fmt.toml" "line-width = 80\n"
    let misplaced ← try discard <| Discovery.run root none; pure false catch _ => pure true
    ensure misplaced "line-width at the top level was accepted"
    -- §9.3 the width bound is enforced at load, not at render.
    for width in ["0", "1001"] do
      write ".lean-fmt.toml" s!"[format]\nline-width = {width}\n"
      let bounded ← try discard <| Discovery.run root none; pure false catch _ => pure true
      ensure bounded s!"line-width = {width} was accepted outside 1..1000"
    -- §10 a `.gitignore` prunes, and a nearer file's negation wins over a farther file's exclusion.
    write ".lean-fmt.toml" "[format]\nline-width = 100\n"
    write ".gitignore" "build/\n*.tmp.lean\n"
    write ".git/HEAD" "ref: refs/heads/main\n"
    write "build/Generated.lean" "module\n"
    write "A.tmp.lean" "module\n"
    write "sub/.gitignore" "!*.tmp.lean\n"
    write "sub/A.tmp.lean" "module\n"
    let ignoring ← Discovery.run root none
    ensure (!ignoring.sources.contains "build/Generated.lean")
      "an ignored directory was walked"
    ensure (!ignoring.sources.contains "A.tmp.lean") "an ignored file was discovered"
    ensure (ignoring.sources.contains "sub/A.tmp.lean")
      "a nearer .gitignore negation did not re-include a file"
    ensure (ignoring.ignoreSources.any (·.endsWith ".gitignore"))
      "the ignore sources were not reported"
    -- §9.2 the sharp rule, asserted on the identity string itself: a `[format]` key moves it, a
    -- `[lint]` key never does. This is the whole reason the sections are separate keys and not one
    -- flat namespace.
    write ".lean-fmt.toml" "[format]\nline-width = 100\n[lint]\nselect = [\"security\"]\n"
    let lintOnly ← Discovery.run root none
    write ".lean-fmt.toml" "[format]\nline-width = 100\n[lint]\nselect = [\"all\"]\n"
    let lintOther ← Discovery.run root none
    ensure (lintOnly.fallback.format.identityString == lintOther.fallback.format.identityString)
      "a [lint] key changed the configuration identity"
    write ".lean-fmt.toml" "[format]\nline-width = 99\n[lint]\nselect = [\"all\"]\n"
    let formatOther ← Discovery.run root none
    ensure (lintOther.fallback.format.identityString != formatOther.fallback.format.identityString)
      "a [format] key did not change the configuration identity"
    -- §12 introspection is deterministic and records provenance, not just values.
    let described := formatOther.fallback.describe
    ensure (described == formatOther.fallback.describe) "config introspection was not deterministic"
    ensure (described.any fun (key, value, origin) =>
        key == "format.line-width" && value == "99" && origin.endsWith ".lean-fmt.toml:2")
      "config introspection lost a setting's file and line"
    ensure (described.any fun (key, _, origin) => key == "include" && origin == "default")
      "an unset setting was not reported as a default"
  finally
    IO.FS.removeDirAll directory

/-- Catalog metadata invariants (`ruff-12` RRL-IMPL; `notes/01-schema.md` §10). Pure over the registry:
unique/well-shaped codes, namespace disjointness, lifecycle/default coherence, and documentation
presence. The *executable*-example check (each `bad` fires, each fix yields `good?`) runs through the
real frontend in `tests/catalog/run.sh`; this test pins everything answerable without a projection. -/
private def testCatalogInvariants : IO Unit := do
  let infos := allRuleInfos
  let codes := infos.map (·.code)
  -- 1. Codes are `FMT` + exactly three digits, unique, and disjoint from reserved + meta codes.
  let isCodeShaped := fun (c : String) =>
    let chars := c.toList
    chars.length == 6 && c.startsWith "FMT" && (chars.drop 3).all Char.isDigit
  for info in infos do
    ensure (isCodeShaped info.code) s!"rule code is not FMT###: {info.code}"
    ensure ((codes.filter (· == info.code)).size == 1) s!"duplicate rule code: {info.code}"
    ensure (!isReservedCode info.code) s!"live rule reuses a reserved code: {info.code}"
    ensure (info.code != "FMT900" && info.code != "FMT901")
      s!"live rule reuses a suppression meta code: {info.code}"
  -- 2. Namespace disjointness: no category names a code or a reserved word.
  for info in infos do
    ensure (!info.category.isEmpty) s!"rule {info.code} has an empty category"
    ensure (!isCodeShaped info.category) s!"category collides with a code shape: {info.category}"
    ensure (info.category != "all" && info.category != "default" && info.category != "preview")
      s!"category collides with a reserved word: {info.category}"
  -- 3. Lifecycle / default coherence.
  for info in infos do
    if info.lifecycle == .preview then
      ensure (!info.defaultEnabled) s!"preview rule is default-enabled: {info.code}"
    if info.lifecycle == .deprecated then
      ensure (!info.defaultEnabled) s!"deprecated rule is default-enabled: {info.code}"
      let some r := info.replacement?
        | throw <| IO.userError s!"deprecated rule {info.code} has no replacement"
      ensure (codes.contains r || isReservedCode r)
        s!"deprecated rule {info.code} names an unknown replacement: {r}"
    else
      ensure info.replacement?.isNone s!"non-deprecated rule {info.code} carries a replacement"
  -- 3b. Every preview rule states what would graduate it, and no other rule pretends to
  --     (`ruff-12b` RGR-SPEC §4 DOC-3). Pinned in BOTH directions on purpose: a field that is merely
  --     *allowed* is a field that goes unset, and "not yet" with no condition is how a preview rule
  --     becomes permanent.
  for info in infos do
    if info.lifecycle == .preview then
      match info.previewPath? with
      | none => throw <| IO.userError s!"preview rule {info.code} states no path out of preview"
      | some p => ensure (!p.isEmpty) s!"preview rule {info.code} has an empty path out of preview"
    else
      ensure info.previewPath?.isNone
        s!"non-preview rule {info.code} carries a path out of preview"
  -- 4. Documentation: nonempty explanation always; ≥1 example unless exempt; a fixable non-exempt rule
  --    ships a bad→good example so its fix is testable.
  for info in infos do
    ensure (!info.explanation.isEmpty) s!"rule {info.code} has no explanation"
    if exampleExemptCodes.contains info.code then
      ensure info.examples.isEmpty s!"exempt rule {info.code} unexpectedly ships an example"
    else
      ensure (!info.examples.isEmpty) s!"rule {info.code} ships no example and is not exempt"
      ensure (info.examples.all (!·.bad.isEmpty)) s!"rule {info.code} has an empty example"
      if info.fixable then
        ensure (info.examples.any (·.good?.isSome))
          s!"fixable rule {info.code} has no bad→good example to test its fix"
      else
        ensure (info.examples.all (·.good?.isNone))
          s!"report-only rule {info.code} has a `good` example but nothing to fix"
  -- 5. Reserved integrity. `reservedCodes` is EMPTY after the pre-release renumbering
  -- (`docs/rules/MIGRATION.md`), which reused the retired FMT001/FMT002. So the old form of this
  -- check -- "FMT001 and FMT002 are reserved and not live" -- is not merely failing, it asserts the
  -- opposite of what now holds, and it is gone rather than adjusted.
  --
  -- What survives is the invariant that does not depend on the table having entries: whatever is in
  -- it is disjoint from the live catalog. That is vacuously true today. It is asserted anyway, so the
  -- day a rule genuinely retires, the check is already here and already correct.
  --
  -- Deliberately NOT done: adding a placeholder retired code so this has something to bite on. A
  -- fixture invented to keep a test green proves the fixture exists, not that the machinery works.
  -- The reserved branches in `Config.selectorsValid` and `Suppression.apply` are untested until a
  -- real retirement, and `reservedCodes`' own docstring says so where someone will read it.
  for (code, _) in reservedCodes do
    ensure (!codes.contains code) s!"reserved code {code} reappeared as a live rule"
  -- 6. Generated docs are nonempty and one per live rule plus an index and the config schema (drift is
  -- checked in the harness). The schema enumerates exactly the selector vocabulary `selectorsValid` accepts.
  ensure (catalogDocs.size == infos.size + 2) "generated docs count does not match the catalog"
  ensure (catalogDocs.all (!·.2.isEmpty)) "a generated doc page is empty"
  ensure (catalogDocs.any (·.1 == "schema.json")) "the generated config schema is missing"
  for info in infos do
    ensure (selectorVocabulary.contains info.code)
      s!"live code {info.code} is absent from the schema selector vocabulary"
    ensure (selectorVocabulary.contains info.category)
      s!"category {info.category} is absent from the schema selector vocabulary"
  for (code, _) in reservedCodes do
    ensure (selectorVocabulary.contains code)
      s!"reserved code {code} is absent from the schema selector vocabulary"

private def testApplicability : IO Unit := do
  -- Admission: safe always, unsafe iff opted in, display-only never.
  ensure (Applicability.safe.admitted false && Applicability.safe.admitted true)
    "a safe fix was not admitted"
  ensure (!Applicability.unsafe.admitted false && Applicability.unsafe.admitted true)
    "unsafe admission did not track the opt-in"
  ensure (!Applicability.displayOnly.admitted false && !Applicability.displayOnly.admitted true)
    "a display-only fix was admitted"

  -- Wire round-trip and stable spellings.
  for (a, wire) in #[(Applicability.safe, "safe"), (.unsafe, "unsafe"), (.displayOnly, "display-only")] do
    ensure (a.toWire == wire) s!"applicability wire spelling changed for {wire}"
    ensure (match (Lean.fromJson? (Lean.toJson a) : Except String Applicability) with
      | .ok decoded => decoded == a | .error _ => false) s!"applicability did not round-trip: {wire}"
  ensure (match (Lean.fromJson? (.str "bogus") : Except String Applicability) with
    | .error _ => true | _ => false) "an unknown applicability wire value was accepted"

  -- Per-rule reclassification, resolved as a plan projection. Codes are opaque to `effectiveApplicability`;
  -- surviving fixable rules (`FMT011` syntax, `FMT012` semantic) stand in for the retired FMT001/FMT002.
  let plan : RulePlan := { selected := #["FMT011", "FMT012"], perFileIgnores := #[], extendSafe := #["FMT011"], extendUnsafe := #["FMT012"] }
  ensure (plan.effectiveApplicability "FMT011" .unsafe == .safe) "extend-safe-fixes did not promote"
  ensure (plan.effectiveApplicability "FMT011" .safe == .safe) "promotion changed an already-safe fix"
  ensure (plan.effectiveApplicability "FMT012" .safe == .unsafe) "extend-unsafe-fixes did not demote"
  ensure (plan.effectiveApplicability "FMT999" .safe == .safe) "an unlisted rule was reclassified"
  -- Display-only is a floor no promotion can lift.
  ensure (plan.effectiveApplicability "FMT011" .displayOnly == .displayOnly)
    "extend-safe-fixes promoted a display-only fix"

  -- `RulePlan.findings` carries the effective applicability onto the reported fix. Driven by a synthetic
  -- `.safe` fix (no source-tier fixable rule survives RDF-LAYOUT), which `extend-unsafe-fixes` demotes.
  let demote : RulePlan := { selected := #["FMT011"], perFileIgnores := #[], extendSafe := #[], extendUnsafe := #["FMT011"] }
  let projected := demote.findings "A.lean" #[findingWithEdit { start := 0, stop := 1 } "" .safe "FMT011"]
  ensure (projected.size == 1 && (projected[0]!.fix?.map (·.applicability)) == some .unsafe)
    "the findings projection did not demote a safe fix"

  -- Conflict provenance names both rules, not array indices.
  match preparePatch "abc" #[
      findingWithEdit { start := 0, stop := 2 } "x" .safe "RULE_A",
      findingWithEdit { start := 1, stop := 3 } "y" .safe "RULE_B"
    ] with
  | .error error =>
    let rendered := toString error
    ensure ((rendered.splitOn "RULE_A").length == 2 && (rendered.splitOn "RULE_B").length == 2)
      s!"conflict error did not name both rules: {rendered}"
  | .ok _ => throw <| IO.userError "overlapping fixes were accepted"

  -- Contradiction: a rule in both extend lists is rejected at plan construction.
  let directory ← IO.FS.createTempDir
  try
    let configPath := directory / "lean-fmt.toml"
    IO.FS.writeFile configPath "extend-safe-fixes = [\"FMT011\"]\nextend-unsafe-fixes = [\"FMT011\"]\n"
    let config ← FormatterConfig.load directory
    ensure (match config.rulePlan {} with | .error _ => true | _ => false)
      "a rule in both extend lists was accepted"
  finally
    IO.FS.removeDirAll directory

private def testCacheIdentity : IO Unit := do
  let base : CacheIdentity := {
    source := Digest.ofString "source"
    toolchain := "toolchain"
    environment := Digest.ofString "environment"
    formatter := Digest.ofString "formatter"
    configuration := Digest.ofString "configuration"
    closure := Digest.ofString "closure"
  }
  let original := cacheIdentityDigest base
  let changes := #[
    cacheIdentityDigest { base with source := Digest.ofString "other-source" },
    cacheIdentityDigest { base with toolchain := "other-toolchain" },
    cacheIdentityDigest { base with environment := Digest.ofString "other-environment" },
    cacheIdentityDigest { base with formatter := Digest.ofString "other-formatter" },
    cacheIdentityDigest { base with configuration := Digest.ofString "other-configuration" },
    -- `ruff-16b` `RCI-IMPL`: the grammar a module was parsed under is an identity component, so a
    -- change in the import closure's artifacts must move the key on its own. Without this row the
    -- suite would pass under the naive fix that rekeys on nothing but the module's own bytes.
    cacheIdentityDigest { base with closure := Digest.ofString "other-closure" }
  ]
  ensure (changes.all (· != original))
    "a semantic cache identity component did not invalidate the key"
  ensure (changes.toList.Pairwise (· != ·))
    "distinct cache identity components collided in the test fixture"

/- The projection of `def x := 1\n`, written out by hand so the tiling invariant is legible: every
token's span and trivia runs abut, covering `[headerStop, terminalStop)` exactly once.

    byte 0    3 4 5 6  8 9 10 11
         |def | |x| |:=| |1 |\n|
-/
private def fixtureSourceText : String := "def x := 1\n"

private def fixtureLosslessSource (mainModule := "Test") : LosslessSource := {
  schema := losslessSourceSchema
  mainModule
  normalizedBytes := fixtureSourceText.utf8ByteSize
  normalizedDigest := Digest.ofString fixtureSourceText
  headerStop := 0
  terminalStop := fixtureSourceText.utf8ByteSize
  kinds := #["Lean.Parser.Command.declaration"]
  nodes := #[{ kind := 0, parent := none, range := { start := 0, stop := 10 } }]
  tokens := #[
    { node := 0, start := 0, stop := 3, trailing := #[{ kind := .whitespace, stop := 4 }] },
    { node := 0, start := 4, stop := 5, trailing := #[{ kind := .whitespace, stop := 6 }] },
    { node := 0, start := 6, stop := 8, trailing := #[{ kind := .whitespace, stop := 9 }] },
    { node := 0, start := 9, stop := 10, trailing := #[{ kind := .whitespace, stop := 11 }] }
  ]
}

/-! ## The engine, exercised at both tiers

`ruff-10` shipped `syntax`-tier product rules, so `ruleRegistry` now mixes tiers — but it still cannot
exercise the *adversarial* seam this section pins: a `syntax` finding sorting **ahead** of a `source`
one despite being registered **after** it, and a `syntax` rule skipped cleanly when only `source`
facts are on hand. Pinning those needs two rules at controlled codes and ranges, which product rules
do not guarantee. `RRE-FINAL`'s work order asks for "a representative rule at each tier"; its stop
rule says "do not retain fake product rules merely for coverage". Both hold at once only if the
representative rules live here and never enter `ruleRegistry` — which is what `runRulesOf` and
`requiredTierOf` take an array for.

These rules are deliberately trivial and deliberately adversarial about order: `probeSyntax` is
registered **last** and its findings land **first**, so an engine that concatenated in registry order
would fail every assertion below. -/

/-- `syntax`-tier: reports the projection's first token. Registered last, finds earliest. -/
private def probeSyntax : Rule := {
  info := {
    code := "TST900", category := "test", summary := "probe: first token"
    fixable := false, defaultEnabled := false, lifecycle := .preview
    explanation := "probe", examples := #[]
  }
  impl := .syntax fun facts =>
    match facts.projection.tokens[0]? with
    | none => #[]
    | some token => #[{
        code := "TST900", severity := .warning, message := "first token"
        range := { start := token.start, stop := token.stop }
      }]
}

/-- `source`-tier: reports the whole file. Shares its range with `probeTie` to pin tie-breaking. -/
private def probeSource : Rule := {
  info := {
    code := "TST901", category := "test", summary := "probe: whole file"
    fixable := false, defaultEnabled := false, lifecycle := .preview
    explanation := "probe", examples := #[]
  }
  impl := .source fun facts => #[{
    code := "TST901", severity := .warning, message := "whole file"
    range := { start := 0, stop := facts.bytes.size }
  }]
}

/-- `source`-tier, same range as `probeSource`, registered after it but ordering before it by code. -/
private def probeTie : Rule := {
  info := {
    code := "TST900", category := "test", summary := "probe: tie"
    fixable := false, defaultEnabled := false, lifecycle := .preview
    explanation := "probe", examples := #[]
  }
  impl := .source fun facts => #[{
    code := "TST900", severity := .warning, message := "tie"
    range := { start := 0, stop := facts.bytes.size }
  }]
}

/- Characterization of the Lake module trace facts `ruff-16b` `RCI-IMPL` will consume.

This test exists because the currency design rests on a reading of Lake's trace format that is not
documented and was, in this stack's first draft, **wrong**. The roadmap and
`notes/01-what-is-provable.md` both described the check as comparing `B`'s recorded
`["A transitive imports (all)", h]` against `A`'s current value. Measurement refuted that: editing `A`
so its `.olean` changed left every `"A transitive imports (all)"` entry in `A`'s own dependents
untouched, because that key hashes the closure of `A`'s *imports* and excludes `A` itself. The key
that carries `A`'s own artifacts is the sibling `["A:importAllArts", h]`.

`Lake/Build/Module.lean` `computeExportInfo` defines it as

    allArtsTrace := BuildTrace.nil "{mod.name}:importAllArts"
      |>.mix olean |>.mix oleanServer |>.mix oleanPrivate |>.mix irSig |>.mix ir

with `BuildTrace.nil`'s hash being `Hash.nil` and the caption not entering the hash. Each mixed value
is the content hash Lake also writes as the leading 16 hex digits of the corresponding entry in that
module's own `outputs`. So a dependent's recorded expectation for `A` is recomputable from `A`'s own
trace file alone — no import resolution and no closure walk, which is what this stack's stop rules
forbid.

The assertion runs over every (importer, importee) pair the build tree actually contains, so it does
not encode one hard-coded pair that a refactor would silently drop. If Lake changes the mix, its
order, or the `outputs` shape, this fails here rather than as a stale hit in the cache. -/
private structure TraceFacts where
  moduleName : String
  /-- Content hashes of this module's own artifacts, in Lake's mix order: `o…`, then `rs`, then `r`. -/
  artifactHashes : Array Lake.Hash
  /-- Recorded `"X:importAllArts"` expectations, one per direct in-workspace import. -/
  importAllArts : Array (String × Lake.Hash)
  deriving Inhabited

private def parseTraceFacts? (json : Lean.Json) : Option TraceFacts := do
  let outputs ← (json.getObjVal? "outputs").toOption
  let hashOf (value : Lean.Json) : Option Lake.Hash := do
    let text ← value.getStr?.toOption
    Lake.Hash.ofString? (text.take 16).toString
  let mut artifactHashes := #[]
  -- `o` is `[olean]` for a legacy module and `[olean, olean.server, olean.private]` under the module
  -- system; `rs`/`r` are absent in the legacy case. Folding whatever is present, in this order,
  -- reproduces both branches of `computeExportInfo`.
  if let some oleans := (outputs.getObjVal? "o").toOption then
    let some entries := oleans.getArr?.toOption | none
    for entry in entries do
      artifactHashes := artifactHashes.push (← hashOf entry)
  for key in ["rs", "r"] do
    if let some value := (outputs.getObjVal? key).toOption then
      artifactHashes := artifactHashes.push (← hashOf value)
  let some inputs := (json.getObjVal? "inputs").toOption | none
  let some inputEntries := inputs.getArr?.toOption | none
  let mut moduleName := ""
  let mut importAllArts := #[]
  for input in inputEntries do
    let some pair := input.getArr?.toOption | none
    unless pair.size == 2 do continue
    let some key := pair[0]!.getStr?.toOption | none
    if let some suffix := key.dropPrefix? "Module.name: " then
      moduleName := suffix.toString
    if key == "deps" then
      -- `deps` is a list of named groups; `imports` is an array of pairs when the module has
      -- in-workspace imports and the scalar nil hash when it has none. Both shapes occur in this
      -- repository (`LeanFmt.Digest` has no project import), so a consumer must tolerate both.
      let some groups := pair[1]!.getArr?.toOption | none
      for group in groups do
        let some groupPair := group.getArr?.toOption | none
        unless groupPair.size == 2 do continue
        unless (groupPair[0]!.getStr?.toOption) == some "imports" do continue
        let some recorded := groupPair[1]!.getArr?.toOption | continue
        for entry in recorded do
          let some entryPair := entry.getArr?.toOption | none
          unless entryPair.size == 2 do continue
          let some entryKey := entryPair[0]!.getStr?.toOption | none
          let some importee := entryKey.dropSuffix? ":importAllArts" | continue
          let some text := entryPair[1]!.getStr?.toOption | none
          let some hash := Lake.Hash.ofString? text | none
          importAllArts := importAllArts.push (importee.toString, hash)
  guard <| !moduleName.isEmpty
  return { moduleName, artifactHashes, importAllArts }

private def recomputeImportAllArts (facts : TraceFacts) : Lake.Hash :=
  facts.artifactHashes.foldl (init := Lake.Hash.nil) Lake.Hash.mix

private def testLakeTraceCharacterization : IO Unit := do
  let root : System.FilePath := ".lake" / "build" / "lib" / "lean"
  unless ← root.isDir do
    throw <| IO.userError s!"characterization needs a built tree; run `lake build` from the repository \
      root before `lake exe lean-fmt-tests` (missing {root})"
  let traces := (← root.walkDir).filter (·.extension == some "trace")
  let mut byName : Std.HashMap String TraceFacts := {}
  for path in traces do
    let contents ← IO.FS.readFile path
    let .ok json := Lean.Json.parse contents | continue
    let some facts := parseTraceFacts? json | continue
    byName := byName.insert facts.moduleName facts
  ensure (byName.size > 1)
    "no module traces parsed; the Lake trace shape this stack consumes may have changed"
  let mut checked := 0
  for (_, importer) in byName do
    for (importee, recorded) in importer.importAllArts do
      -- Only in-workspace modules get a trace here; toolchain imports (`Lake.*`, `Lean.*`) are absent
      -- from `deps.imports` entirely and are covered by the separate `"Lean <version>, commit …"`
      -- input instead. That absence is itself part of what this test pins down.
      let some importeeFacts := byName[importee]? | continue
      ensure (!importeeFacts.artifactHashes.isEmpty)
        s!"{importee} recorded no artifact hashes in its own trace outputs"
      ensure (recomputeImportAllArts importeeFacts == recorded)
        s!"Lake's importAllArts mix no longer reproduces from the importee's own trace outputs: \
          {importer.moduleName} records {recorded} for {importee}, recomputed \
          {recomputeImportAllArts importeeFacts}. A **stale trace** says this too: `lake build` \
          skips non-default targets, so editing a module that `check-modules` imports leaves its \
          old trace on disk and this walk reads it. Run `lake build check-modules` and retry before \
          concluding Lake's trace shape changed."
      checked := checked + 1
  ensure (checked > 0)
    "no (importer, importee) pair was checked; the deps.imports shape may have changed"

private def testEngineTiers : IO Unit := do
  let normalized := fixtureSourceText
  let projection := fixtureLosslessSource
  let syntaxFacts := Facts.syntax (SyntaxFacts.of normalized projection)
  let sourceFacts := Facts.source (SourceFacts.of normalized)
  let registry := #[probeSource, probeSyntax]

  -- Mixed tiers, sorted by position and not by registry order. `probeSource` covers [0, 11) and
  -- `probeSyntax` finds the `def` token at [0, 3): same start, so the shorter range wins the tie.
  let mixed := runRulesOf registry syntaxFacts
  ensure (mixed.map (·.code) == #["TST900", "TST901"])
    "mixed-tier findings are not byte-sorted independently of registry order"
  ensure (mixed.map (fun finding => (finding.range.start, finding.range.stop)) == #[(0, 3), (0, 11)])
    "mixed-tier ranges are wrong or not sorted by stop within one start"

  -- The same registry against facts that cannot serve the `syntax` rule: it is skipped, not guessed
  -- at, not defaulted, and not an error. `requiredTierOf` is what makes the skip sound — it is what
  -- decided to obtain these facts, and it reads the same array.
  let skipped := runRulesOf registry sourceFacts
  ensure (skipped.map (·.code) == #["TST901"])
    "source facts did not skip exactly the syntax-tier rule"

  -- Ties inside one position break on the code, so registry order cannot decide output.
  let tied := runRulesOf #[probeSource, probeTie] sourceFacts
  ensure (tied.map (·.code) == #["TST900", "TST901"])
    "findings at one identical range are ordered by registry position rather than by code"
  let tiedReversed := runRulesOf #[probeTie, probeSource] sourceFacts
  ensure (tied == tiedReversed) "reordering the registry changed the output"

  -- A rule's tier is its implementation's, and `ToJson` derives `input` from it rather than reading
  -- a field. This is the drift `RuleInfo.input` allowed and `RuleImpl` makes unrepresentable.
  ensure (probeSyntax.tier == .syntax && probeSource.tier == .source) "Rule.tier is not RuleImpl.tier"
  let encoded := Lean.toJson probeSyntax
  ensure ((encoded.getObjValAs? String "input").toOption == some "syntax")
    "the rules wire shape does not derive input from the implementation"
  -- `ruff-10` shipped the first `.syntax`-tier rules (FMT006–FMT011) and `ruff-11` the first
  -- `.semantic`-tier ones (FMT012–FMT015), so the registry now spans the whole lattice. The seams that
  -- once assumed it was uniformly source-tier are all tier-aware: `ofArtifact?` tags its cache entry
  -- with the tier the facts reached (`.semantic` for a demanded artifact, else `.syntax`) and the
  -- source-only shortcut tags `.source`, and `cacheHitServes` serves an entry only when
  -- `result.tier.satisfies plan.requiredTier` — so a narrow shortcut entry cannot answer a syntax or
  -- semantic `--select`. This asserts the shape: all three tiers now ship.
  ensure (ruleRegistry.any (·.tier == .source) && ruleRegistry.any (·.tier == .syntax) &&
      ruleRegistry.any (·.tier == .semantic))
    "ruleRegistry lost a tier: ruff-10 shipped source+syntax, ruff-11 added semantic (FMT012–FMT015)"

  -- The lattice gained `semantic` above `syntax` (`ruff-05b`): richer facts serve any cheaper
  -- requirement, and the cheaper cannot serve the dearer. `ruff-11`'s FMT012–FMT015 are the first
  -- shipped `.semantic`-tier rules, so both demanders now reach that tier — a `.semantic`-rule
  -- selection (below) and the canonical-rendering mode (`RulePlan.demandedTier`).
  ensure (Tier.satisfies .semantic .syntax && Tier.satisfies .semantic .source)
    "semantic facts failed to serve a cheaper requirement"
  ensure (!Tier.satisfies .syntax .semantic && !Tier.satisfies .source .semantic)
    "a cheaper tier was accepted for a semantic requirement"
  ensure (Tier.satisfies .semantic .semantic) "semantic facts did not serve a semantic requirement"
  ensure (Tier.max .syntax .semantic == .semantic && Tier.max .semantic .source == .semantic)
    "Tier.max disagrees with the source ≤ syntax ≤ semantic chain"

/-- Selection derives what a run must *obtain*, and nothing else.

The completion contract's first clause — selection "never selects worker, artifact, cache, or
scheduling strategy" — has two halves. This is the half about cost: what a selection is allowed to
make a run pay for. The other half, that selection stays out of cache identity, is
`tests/check/run.sh`'s one-entry-two-selections check, which needs a real cache and a real project.

`plan.selected` is what the fold reads, so these plans are built directly rather than through
`FormatterConfig.rulePlan`: the probe codes are not in `ruleRegistry` and `selectorsValid` would
rightly reject them. That is the seam working as intended — no fake rule is reachable from config. -/
private def testMixedSelection : IO Unit := do
  let registry := #[probeSource, probeSyntax]
  let plan (selected : Array String) : RulePlan :=
    { selected, perFileIgnores := #[], extendSafe := #[], extendUnsafe := #[] }

  ensure ((plan #[]).requiredTierOf registry == .source)
    "selecting nothing did not cost source facts"
  ensure ((plan #["TST901"]).requiredTierOf registry == .source)
    "selecting only a source rule cost more than source facts"
  ensure ((plan #["TST900"]).requiredTierOf registry == .syntax)
    "selecting a syntax rule did not require syntax facts"
  -- The point of `Tier.max`: one syntax rule in a mixed selection decides the whole batch, and its
  -- position in the array cannot matter.
  ensure ((plan #["TST900", "TST901"]).requiredTierOf registry == .syntax)
    "a mixed selection did not take the maximum of its rules' tiers"
  ensure ((plan #["TST901", "TST900"]).requiredTierOf #[probeSyntax, probeSource] == .syntax)
    "requiredTierOf depends on registry or selection order"
  -- An unselected syntax rule cannot make a run pay for facts nothing will read. This is the
  -- property that makes `--select` free: turning a rule off can never rebuild or re-elaborate.
  ensure ((plan #["TST901"]).requiredTierOf #[probeSyntax, probeSource] == .source)
    "an unselected syntax rule still cost the run its facts"
  -- And the derivation must agree with what the engine will actually run, or a batch obtains facts
  -- for rules it skips, or skips rules it obtained facts for.
  ensure ((runRulesOf registry (.source (SourceFacts.of fixtureSourceText))).map (·.code) ==
      #["TST901"])
    "requiredTierOf and runRulesOf disagree about what source facts can answer"
  -- Selecting exactly one shipped rule must cost exactly that rule's own tier — no more (paying for
  -- facts it will not read) and no less (skipping facts it needs). `ruff-10`'s syntax rules make the
  -- `.syntax` side of this non-vacuous; before them every shipped rule was `.source`.
  ensure (ruleRegistry.all (fun rule => ({ selected := #[rule.code], perFileIgnores := #[], extendSafe := #[], extendUnsafe := #[] } : RulePlan).requiredTier == rule.tier))
    "a shipped rule's single selection costs a different tier than the rule's own"

  -- Formatting does not demand semantic rule facts. Only the selected rules determine the tier.
  let shippedPlan : RulePlan :=
    { selected := #["FMT001"], perFileIgnores := #[], extendSafe := #[], extendUnsafe := #[] }
  ensure (shippedPlan.demandedTier == .source)
    "a non-rendering run demanded more than its rules needed"
  -- `ruff-11`: selecting a shipped `.semantic`-tier rule demands the semantic fact on its own, with no
  -- rendering — the second demander the mode is not. This is what makes a `check --select FMT012` run
  -- capture the compiler diagnostics rather than serve a syntax-only artifact that never held them.
  let semanticPlan : RulePlan :=
    { selected := #["FMT012"], perFileIgnores := #[], extendSafe := #[], extendUnsafe := #[] }
  ensure (semanticPlan.demandedTier == .semantic)
    "selecting a semantic rule did not demand the semantic fact without rendering"

private def fixtureArtifact : ModuleArtifact := {
  schema := artifactSchema
  mainModule := "Test"
  normalizedBytes := fixtureSourceText.utf8ByteSize
  normalizedDigest := Digest.ofString fixtureSourceText
  syntaxData := {
    kinds := #[`Lean.Parser.Command.declaration]
    entries := #[
      .node .none 0 4,
      .atom (.original 0 0 3 4) none,
      .atom (.original 4 4 5 6) none,
      .atom (.original 6 6 8 9) none,
      .atom (.original 9 9 10 11) none,
      .atom (.synthetic fixtureSourceText.utf8ByteSize fixtureSourceText.utf8ByteSize true) (some "")]
    commands := #[{
      entry := 0
      options := 0
      range := ⟨0, fixtureSourceText.utf8ByteSize⟩ }]
    terminal := 5
    options := #[{ entries := #[] }]
  }
}

/- Every rejection below is an ordinary miss, not an error: a consumer that cannot authenticate a
projection must fall back to the exact frontend rather than trust it or fail the run. -/
private def testLosslessSource : IO Unit := do
  let source := fixtureLosslessSource
  ensure source.structurallyValid "a correctly tiled projection was rejected"
  ensure (source.validFor fixtureSourceText) "the projection rejected its own source"

  -- The recorded CRLF defect: the parser normalizes before it assigns any offset, so the CRLF and
  -- LF forms of one module share a projection. Digesting raw bytes made every CRLF file a
  -- permanent silent miss.
  ensure (source.validFor "def x := 1\r\n")
    "the CRLF form of the projected module was not recognized"
  ensure (!(source.validFor "def x := 2\n")) "a different source matched the projection"
  ensure (!(source.validFor "def x := 1")) "a truncated source matched the projection"

  -- `#exit` ends the token stream before end of file. `terminalStop` is where the terminal command
  -- begins, so the tail covers `#exit` and Lean's never-parsed remainder alike; no token may claim
  -- to describe bytes the parser never read. Recording the terminal's *end* instead left `#exit`
  -- itself covered by nothing, and every file containing one failed to validate at all.
  let tailText := fixtureSourceText ++ "#exit\nnever parsed at all\n"
  let withTail : LosslessSource :=
    { source with normalizedBytes := tailText.utf8ByteSize
                  normalizedDigest := Digest.ofString tailText }
  ensure withTail.structurallyValid "a projection with an unparsed tail was rejected"
  ensure (withTail.validFor tailText) "the tail projection rejected its own source"
  ensure (withTail.terminalStop < withTail.normalizedBytes) "the tail fixture records no tail"

  let rejects (label : String) (broken : LosslessSource) : IO Unit :=
    ensure (!broken.structurallyValid) s!"{label} was accepted as a valid projection"
  rejects "a stale schema" { source with schema := "lean-fmt.lossless-source.v0" }
  rejects "a gap between tokens"
    { source with tokens := source.tokens.set! 1 { source.tokens[1]! with start := 5 } }
  rejects "overlapping tokens"
    { source with tokens := source.tokens.set! 1 { source.tokens[1]! with start := 3 } }
  rejects "a token whose span is inverted"
    { source with tokens := source.tokens.set! 0 { source.tokens[0]! with start := 3, stop := 0 } }
  let longTrailing := { source.tokens[0]! with trailing := #[{ kind := .whitespace, stop := 5 }] }
  rejects "trivia running past the next token"
    { source with tokens := source.tokens.set! 0 longTrailing }
  rejects "a token stream that stops short of the terminal"
    { source with terminalStop := source.terminalStop + 1 }
  rejects "a terminal past the end of the source"
    { source with terminalStop := source.normalizedBytes + 1 }
  rejects "a header past the terminal" { source with headerStop := source.terminalStop + 1 }
  rejects "a token owned by a nonexistent node"
    { source with tokens := source.tokens.set! 0 { source.tokens[0]! with node := 9 } }
  rejects "a node with a nonexistent kind"
    { source with nodes := source.nodes.set! 0 { source.nodes[0]! with kind := 9 } }
  rejects "a node with a nonexistent parent"
    { source with nodes := source.nodes.set! 0 { source.nodes[0]! with parent := some 9 } }
  rejects "a fabricated token position"
    { source with tokens := source.tokens.set! 0 { source.tokens[0]! with info := .synthetic } }

  let decoded : Except String LosslessSource := Lean.fromJson? (Lean.toJson source)
  match decoded with
  | .ok actual => ensure (actual == source) "lossless-source JSON round trip failed"
  | .error message => throw <| IO.userError s!"lossless-source JSON decode failed: {message}"

private def testStore : IO Unit := do
  let artifact := fixtureArtifact
  ensure (structurallyValid artifact) "valid module artifact was rejected"
  ensure (!(structurallyValid { artifact with schema := "other-schema" }))
    "schema change did not reject the artifact"
  -- A `v1` payload left in an `.olean` describes the superseded command-kind projection.
  ensure (!(structurallyValid { artifact with schema := "lean-fmt.module-artifact.v1" }))
    "a stale v1 artifact was accepted by the current reader"
  -- An artifact is now nothing but its schema and its projection, so this is the only remaining way
  -- for one to be structurally wrong. The check that used to live here bounded every finding's range
  -- by `normalizedBytes`; there are no findings to bound.
  ensure (!(structurallyValid { artifact with
      syntaxData := { artifact.syntaxData with terminal := artifact.syntaxData.entries.size + 1 } }))
    "an artifact whose projection is itself invalid was accepted"
  ensure (!(artifact.validFor `Other fixtureSourceText)) "a wrong-module artifact was accepted"
  ensure (!(artifact.validFor `Test "other source")) "a wrong-source artifact was accepted"
  ensure (artifact.validFor `Test fixtureSourceText) "a valid artifact was rejected for its source"
  let decoded : Except String ModuleArtifact := Lean.fromJson? (Lean.toJson artifact)
  match decoded with
  | .ok actual => ensure (actual == artifact) "module-artifact JSON round trip failed"
  | .error message => throw <| IO.userError s!"module-artifact JSON decode failed: {message}"
  let directory ← IO.FS.createTempDir
  let path := directory / "nested" / "Test.json"
  try
    writeArtifactAtomic path artifact
    let hash ← Lake.computeFileHash path (text := true)
    let facet : Lake.Artifact := {
      descr := Lake.artifactWithExt hash "json"
      path
      mtime := 0
    }
    ensure ((← readFacet? facet `Test fixtureSourceText) == some artifact)
      "trusted facet artifact round trip failed"
    ensure (← readFacet? facet `Test "other source").isNone
      "source mismatch did not reject the facet artifact"
    ensure (← readFacet? facet `Other fixtureSourceText).isNone
      "module mismatch did not reject the facet artifact"
    IO.FS.writeFile path (Lean.toJson { artifact with schema := "other-schema" }).compress
    ensure (← readFacet? facet `Test fixtureSourceText).isNone
      "tampered facet artifact did not fail its content hash"
    writeArtifactAtomic path artifact
    IO.FS.writeFile (directory / "nested" / "Test.json.tmp-interrupted") "partial"
    ensure ((← readFacet? facet `Test fixtureSourceText) == some artifact)
      "an interrupted temporary write damaged the committed artifact"
    IO.FS.removeFile path
    ensure (← readFacet? facet `Test fixtureSourceText).isNone
      "missing facet artifact was not an ordinary miss"
  finally
    IO.FS.removeDirAll directory

/-- An artifact carrying one surfaced compiler diagnostic. -/
private def fixtureSemanticArtifact : ModuleArtifact :=
  { fixtureArtifact with semantic := some {
      diagnostics := #[
        { kind := "linter.unusedVariables", range := { start := 0, stop := 3 },
          severity := .warning, message := "unused variable `x`" }] } }

/- The semantic fact is additive and demand-gated. The pre-release syntax-artifact replacement has no
legacy decoder: old lossy payloads fail decoding and therefore become ordinary facet misses. -/
private def testSemanticArtifact : IO Unit := do
  ensure (structurallyValid fixtureSemanticArtifact)
    "a v9 artifact carrying the semantic fact was rejected"
  let decoded : Except String ModuleArtifact := Lean.fromJson? (Lean.toJson fixtureSemanticArtifact)
  match decoded with
  | .ok actual => ensure (actual == fixtureSemanticArtifact) "v9 semantic artifact JSON round trip failed"
  | .error message => throw <| IO.userError s!"v9 semantic artifact decode failed: {message}"

  -- The plugin producer emits `semantic = none`; that shape is valid and round-trips too.
  ensure (fixtureArtifact.semantic.isNone) "the plugin-shaped fixture already carried a semantic fact"
  ensure (structurallyValid fixtureArtifact) "a v9 artifact with semantic = none was rejected"
  let noneDecoded : Except String ModuleArtifact := Lean.fromJson? (Lean.toJson fixtureArtifact)
  match noneDecoded with
  | .ok actual => ensure (actual == fixtureArtifact) "v9 semantic = none artifact JSON round trip failed"
  | .error message => throw <| IO.userError s!"v9 semantic = none artifact decode failed: {message}"

  -- A stale `v4` payload is a clean miss, the same discipline as the `v1` miss in `testStore`.
  ensure (!(structurallyValid { fixtureArtifact with schema := "lean-fmt.module-artifact.v4" }))
    "a stale v4 artifact was accepted by the current reader"
  -- Faithful to a `v4` payload with the deleted lossy source projection and no syntax payload.
  let v4none := Lean.Json.mkObj
    [("schema", "lean-fmt.module-artifact.v4"), ("source", Lean.toJson fixtureLosslessSource)]
  match (Lean.fromJson? v4none : Except String ModuleArtifact) with
  | .ok _ => throw <| IO.userError "the v9 decoder retained the deleted v4 payload shape"
  | .error _ => pure ()
/- The shipped semantic-tier rules (`ruff-11` FMT012–FMT015) surface the compiler's own diagnostics:
each keys on one stable `kind` tag and re-emits it as a report-only finding under its own code,
preserving the compiler's message, severity, and range. This exercises the whole engine seam over
`.semantic` facts without the exact frontend — the production `runRulesOf` reads `SemanticFacts`
built directly, so the mapping is pinned as pure data. `tests/semantic/run.sh` proves the *capture*
half against Lean's own emission; this proves the *rule* half.

Every assertion is about the shipped `ruleRegistry`, not a probe, because these are real shipped rules
(the reason `testEngineTiers`' representative rules could not be semantic before). -/
private def testSemanticRules : IO Unit := do
  let mkDiag (kind : String) (start stop : Nat) (message : String) : Diagnostic :=
    { kind, range := { start, stop }, severity := .warning, message }
  -- One diagnostic per surfaced kind, plus one kind no rule owns. Distinct starts pin byte-ordering.
  let diagnostics := #[
    mkDiag "Lean.Linter.deprecatedAttr"       0 4 "`oldName` is deprecated",
    mkDiag "linter.unusedVariables"           5 6 "unused variable `x`",
    mkDiag "linter.unusedSectionVars"         7 8 "unused section variable `inst`",
    mkDiag "linter.constructorNameAsVariable" 9 10 "`true` resembles a constructor",
    mkDiag "linter.unownedByAnyRule"          2 3 "no rule surfaces this kind"]
  let facts := Facts.semantic (SemanticFacts.of fixtureSourceText fixtureLosslessSource diagnostics)
  let findings := runRulesOf ruleRegistry facts

  -- Each surfaced kind maps to exactly its code, preserving the compiler's own range/severity/message.
  let expect : Array (String × String × Nat × Nat) := #[
    ("FMT012", "`oldName` is deprecated", 0, 4),
    ("FMT013", "unused variable `x`", 5, 6),
    ("FMT014", "unused section variable `inst`", 7, 8),
    ("FMT015", "`true` resembles a constructor", 9, 10)]
  for (code, message, start, stop) in expect do
    match findings.filter (·.code == code) with
    | #[f] =>
      ensure (f.message == message) s!"{code} did not preserve the compiler's message"
      ensure (f.range.start == start && f.range.stop == stop) s!"{code} did not preserve the diagnostic range"
      ensure (f.severity == .warning) s!"{code} did not preserve the diagnostic severity"
      ensure (f.fix?.isNone) s!"{code} is report-only but carried a fix"
    | other => throw <| IO.userError s!"expected exactly one {code} finding, got {other.size}"

  -- A kind no rule owns yields no finding: the rules read only the tags they name, never everything
  -- the artifact happens to carry. (Capture already filters to `surfacedDiagnosticKinds`; this pins
  -- that the rule side is closed the same way — an unowned kind fed in directly is still dropped.)
  ensure (surfacedDiagnosticKinds.size == 4) "surfacedDiagnosticKinds no longer lists exactly the four rules"
  ensure ((findings.filter (fun f => #["FMT012", "FMT013", "FMT014", "FMT015"].contains f.code)).size == 4)
    "the surfaced rules produced other than one finding per owned kind (the unowned kind leaked)"

  -- The engine skips semantic rules cleanly when only cheaper facts are on hand — not guessed at, not
  -- defaulted, not an error — exactly as it skips a syntax rule on source facts. `requiredTierOf` is
  -- what makes the skip sound (it decided not to obtain these diagnostics), and it reads one registry.
  let semanticCodes := #["FMT012", "FMT013", "FMT014", "FMT015"]
  let onSyntax := runRulesOf ruleRegistry (.syntax (SyntaxFacts.of fixtureSourceText fixtureLosslessSource))
  ensure (onSyntax.all (fun f => !semanticCodes.contains f.code))
    "a semantic rule fired on syntax facts that never carried a diagnostic"
  let onSource := runRulesOf ruleRegistry (.source (SourceFacts.of fixtureSourceText))
  ensure (onSource.all (fun f => !semanticCodes.contains f.code))
    "a semantic rule fired on source facts that never carried a diagnostic"

/- The owned FMT012 rename fix (`ruff-11b`, ROS-IMPL). The report is surfaced from the diagnostic
(unchanged, always cheap); the `unsafe` rename fix is attached from the owned occurrence fact — and
only when a *fixable* occurrence sits at the surfaced finding's own range with a `newName?`. This pins
the rule half as pure data: the report never changes across the occurrence cases, only `fix?` does, so
a `check` (empty occurrences) is byte-identical to the surfaced-only `ruff-11` behavior. `run.sh` proves
the fix *applies* end to end through canonical re-projection; this pins the *attachment* predicate. -/
private def testOwnedDeprecationFix : IO Unit := do
  let depRange : SourceRange := { start := 0, stop := 4 }
  let diag : Diagnostic :=
    { kind := "Lean.Linter.deprecatedAttr", range := depRange, severity := .warning,
      message := "`oldName` is deprecated" }
  -- Run the shipped registry over `.semantic` facts carrying one deprecation diagnostic and a chosen
  -- set of occurrences; return the single FMT012 finding (there is exactly one surfaced diagnostic).
  let fmt014 (occurrences : Array DeprecatedOccurrence) : IO Finding := do
    let facts := Facts.semantic
      (SemanticFacts.of fixtureSourceText fixtureLosslessSource #[diag] occurrences)
    match (runRulesOf ruleRegistry facts).filter (·.code == "FMT012") with
    | #[f] => return f
    | other => throw <| IO.userError s!"expected exactly one FMT012 finding, got {other.size}"
  -- The report an occurrence set must never perturb: same code/severity/message/range every time.
  let reportUnchanged (f : Finding) (label : String) : IO Unit := do
    ensure (f.severity == .warning && f.message == "`oldName` is deprecated" && f.range == depRange)
      s!"FMT012 report was perturbed by the {label} occurrence set"

  let fixable : DeprecatedOccurrence :=
    { range := depRange, declName := "oldName", newName? := some "newName",
      since? := some "1.0", text? := none, fixable := true }

  -- A. A fixable occurrence at the finding's range with a `newName?` attaches an `unsafe` rename whose
  -- one edit replaces exactly that range with the new name.
  let a ← fmt014 #[fixable]
  reportUnchanged a "fixable"
  match a.fix? with
  | some fix =>
    ensure (fix.applicability == .unsafe) "FMT012 rename fix must be unsafe (unproven textual swap)"
    ensure (fix.edits == #[{ range := depRange, replacement := "newName" }])
      "FMT012 fix did not replace the occurrence range with the deprecation's newName"
  | none => throw <| IO.userError "a fixable deprecation occurrence attached no fix"

  -- B. A non-bare occurrence (`fixable := false`) stays report-only — the capture-side predicate, not
  -- the rule, decides bareness, and the rule offers no fix without it.
  let b ← fmt014 #[{ fixable with fixable := false }]
  reportUnchanged b "non-fixable"
  ensure (b.fix?.isNone) "FMT012 attached a fix to a non-fixable (non-bare-identifier) occurrence"

  -- C. A `newName? = none` occurrence (deprecation with no replacement) stays report-only: there is no
  -- name to substitute, so no rename can be offered even though the use is bare.
  let c ← fmt014 #[{ fixable with newName? := none }]
  reportUnchanged c "no-replacement"
  ensure (c.fix?.isNone) "FMT012 attached a fix to a deprecation with no replacement name"

  -- D. An occurrence at a *different* range does not match the surfaced finding — the fix attaches by
  -- range identity, never by position or count, so a stray occurrence cannot mis-fix another finding.
  let d ← fmt014 #[{ fixable with range := { start := 100, stop := 104 } }]
  reportUnchanged d "range-mismatch"
  ensure (d.fix?.isNone) "FMT012 attached a fix from an occurrence at a different range"

  -- E. No occurrences (the `check` path, or any run that did not demand the capability): report-only,
  -- byte-identical to the surfaced-only behavior FMT012 shipped with in `ruff-11`.
  let e ← fmt014 #[]
  reportUnchanged e "empty"
  ensure (e.fix?.isNone) "FMT012 was not report-only when no occurrences were captured"
  ensure (e == { a with fix? := none })
    "the surfaced-only FMT012 finding is not the fixable one minus its fix (report drifted)"

/- `SemanticCaps.subset` and the `needsOccurrences`↔tier invariant. The subset gate is what makes a
report-only `.semantic` cache entry miss a fixable-FMT012 demand rather than serve a false
clean; the invariant is what keeps the capability from rotting into an unenforced field. -/
private def testSemanticCaps : IO Unit := do
  let all : SemanticCaps := { occurrences := true }
  let cheap : SemanticCaps := {}
  let occ : SemanticCaps := { occurrences := true }
  -- `{}` demands nothing, so a source/syntax run is served by any entry.
  ensure (SemanticCaps.subset {} all && SemanticCaps.subset {} {}) "the empty demand is not a subset of everything"
  -- A full entry serves every demand; the demand serves itself.
  ensure (SemanticCaps.subset occ all && SemanticCaps.subset occ occ) "occurrences demand not served by an entry that has it"
  -- The load-bearing miss: an occurrences demand against a report-only entry is not a subset, so
  -- `cacheHitServes` recomputes rather than serving a false clean.
  ensure (!SemanticCaps.subset occ cheap && !SemanticCaps.subset occ {})
    "a fixable-FMT012 demand was (wrongly) served by an entry that captured no occurrences"
  -- The empty demand is served by an occurrence-bearing entry (superset), orthogonal to the tier.
  ensure (SemanticCaps.subset cheap all) "the cheap sub-facts are not a subset of the full capability set"

  -- The invariant: a `needsOccurrences` rule is `.semantic` (its fix reads an info-tree fact), and only
  -- FMT012 declares it today. A declared-but-unenforced capability would rot exactly as a tier field
  -- would; this ties it to the tier the registry actually derives from the constructor.
  for rule in ruleRegistry do
    if rule.info.needsOccurrences then
      ensure (rule.tier == .semantic)
        s!"{rule.info.code} needs occurrences but is not a semantic-tier rule"
  ensure ((ruleRegistry.filter (·.info.needsOccurrences)).map (·.info.code) == #["FMT012"])
    "exactly FMT012 must declare needsOccurrences (a new owner needs its own capture + tests)"

private def sliceOf (source : String) (start stop : Nat) : String :=
  String.Pos.Raw.extract source ⟨start⟩ ⟨stop⟩

/- Check a projection against the real parser output it claims to describe.

`structurallyValid` proves the spans tile; that is cheap and content-blind. What it cannot see is
whether the recorded spans mean what they say. So this walks the projection independently, slices
the source at every recorded boundary, and reads the bytes back:

- reconstruction concatenates header, every token with its trivia, and the tail, and compares the
  result to the whole file;
- each trivia run must actually contain the form its kind names.

Contiguity makes each trivia run's start the previous stop, so the walk below is the only place that
recovers those starts — if the codec ever recorded a stop that disagreed with the bytes, this is
what would catch it. -/
private def checkProjection (source : LosslessSource) (raw : String) : IO Unit := do
  let normalized := (LosslessSource.normalize raw).1
  ensure source.structurallyValid "the compiler produced a projection that does not tile"
  ensure (source.validFor raw) "the compiler projection does not match its own source"

  let triviaHolds (kind : TriviaKind) (text : String) : Bool :=
    match kind with
    | .whitespace => text.all Char.isWhitespace
    | .lineComment => text.startsWith "--" && !(text.contains '\n')
    | .blockComment => text.startsWith "/-" && text.endsWith "-/"
  let checkTrivia (runs : Array Trivia) (start : Nat) : IO Nat := do
    let mut cursor := start
    for run in runs do
      let text := sliceOf normalized cursor run.stop
      ensure (triviaHolds run.kind text)
        s!"a trivia run classified {repr run.kind} does not contain one: {repr text}"
      cursor := run.stop
    return cursor

  let mut rebuilt := sliceOf normalized 0 source.headerStop
  let mut cursor := source.headerStop
  for token in source.tokens do
    let leadingStop ← checkTrivia token.leading cursor
    ensure (leadingStop == token.start) "leading trivia does not reach its token"
    rebuilt := rebuilt ++ sliceOf normalized cursor token.trailingStop
    cursor := token.trailingStop
    let _ ← checkTrivia token.trailing token.stop
  rebuilt := rebuilt ++ sliceOf normalized source.terminalStop source.normalizedBytes
  ensure (rebuilt == normalized) "the projection does not reconstruct its source byte-for-byte"
  -- The module linter never receives the header, so `headerStop` is the one boundary the projection
  -- asserts rather than observes. Every tracked fixture opens with `module`.
  ensure ((sliceOf normalized 0 source.headerStop).startsWith "module")
    "the recorded header is not the module header"

private unsafe def verifyPluginArtifact (moduleName : Lean.Name)
    (sourcePath : System.FilePath) : IO Unit := do
  Lean.enableInitializersExecution
  Lean.initSearchPath (← Lean.findSysroot)
  let environment ← Lean.importModules #[{ module := moduleName }] {}
    (trustLevel := 1024) (loadExts := true) (level := .exported)
  let source ← IO.FS.readFile sourcePath
  let some artifact := fromEnvironment? environment moduleName
    | throw <| IO.userError "module has no matching lean-fmt payload in its `.olean`"
  ensure (artifact.validFor moduleName source) "plugin payload does not match the source"
  ensure (artifact.schema == artifactSchema) "plugin emitted the wrong schema"
  ensure (artifact.syntaxData.kinds.contains `commandEmit_local_command)
    "plugin lost file-local command syntax"
  -- The fixture's `{ first, second }` parses two ways over one byte range. `checkProjection` is
  -- what proves only one alternative spells those bytes; this proves the case is not vacuous.
  ensure (artifact.syntaxData.kinds.contains Lean.choiceKind)
    "the fixture's ambiguous parse produced no choice node"
  let .ok materialized := artifact.materialize source
    | throw <| IO.userError "plugin syntax artifact did not reconstruct"
  checkProjection materialized.source source
  -- The roadmap asks for a compact representation. What grows with a file is the token and node
  -- tables, so bound their cost per element; the fixed schema strings and two digests dominate a
  -- small module and say nothing about compactness (a 34-byte module measures 29x its source and
  -- is not thereby extravagant). Derived field-name JSON measured 114 bytes per token and 54 per
  -- node on this fixture, against 28 and 13 for the array wire format.
  let encoded := (Lean.toJson artifact).compress
  let elements := artifact.syntaxData.entries.size
  ensure (encoded.utf8ByteSize < 1024 + 128 * elements)
    s!"plugin artifact is not compact: {encoded.utf8ByteSize} bytes for {elements} elements"

private def verifyFacetArtifact (path sourcePath : System.FilePath)
    (expectedHash : Lake.Hash) : IO Unit := do
  let source ← IO.FS.readFile sourcePath
  let facet : Lake.Artifact := {
    descr := Lake.artifactWithExt expectedHash "json"
    path
    mtime := 0
  }
  let some artifact ← readFacet? facet `LocalSyntax source
    | throw <| IO.userError "facet artifact failed integrity or semantic validation"
  ensure (artifact.mainModule == "LocalSyntax") "facet artifact lost module identity"
  let .ok materialized := artifact.materialize source
    | throw <| IO.userError "facet syntax artifact did not reconstruct"
  checkProjection materialized.source source

/-- The registered facet, end to end, plus the agreement the product had no test for.

`RRE-SPEC` §2 proved `check` and `format` could report different findings for one unchanged file,
because each spelled the rule configuration its own way and only one path was ever tested. The
assertion this ends on is that regression: the same file, both product paths, byte-identical
findings. It is not a tautology — the two paths reach `runRules` through different `Facts`, and the
source-only shortcut in `availableAnalysis` never touches the artifact. If a future source-tier rule
ever consults the projection, or the shortcut's `normalized` ever drifts from the artifact's, this is
what notices. -/
private def verifyOfficialFacet (root sourcePath : System.FilePath) : IO Unit := do
  let root ← IO.FS.realPath root
  let discovery ← Discovery.run root none
  let project ← Project.load root discovery #[sourcePath]
  let some target := project.targets[0]?
    | throw <| IO.userError "official-facet test did not select exactly one source"
  unless project.targets.size == 1 do
    throw <| IO.userError "official-facet test did not select exactly one source"
  let artifacts ← Application.officialArtifacts project.workspace #[target]
  let some (some artifact) := artifacts[0]?
    | throw <| IO.userError "registered official facet was unavailable or invalid"
  let some semantic := SemanticAnalysis.ofArtifact? target.source (some artifact)
    | throw <| IO.userError "registered official facet did not produce a semantic result"
  let normalized := (LosslessSource.normalize target.source).1
  let .ok materialized := artifact.materialize target.source
    | throw <| IO.userError "official syntax artifact did not reconstruct"
  -- The artifact path runs the whole registry against the projection and tags the result `.syntax`,
  -- with source-suppression directives collected from the same projection. The direct construction
  -- has to spell all three or it is comparing against a differently-shaped value — the `.syntax` tier
  -- and collected `suppression` are exactly what `ofArtifact?` attaches (`Semantic.lean`).
  ensure (semantic == SemanticAnalysis.success normalized
      (runRules (.syntax (SyntaxFacts.of normalized materialized.source)))
      (tier := .syntax) (suppression := Suppression.collect materialized.source normalized))
    "registered official facet differed from direct product semantics"
  let some artifactResult := semantic.result?
    | throw <| IO.userError "registered official facet produced no result to compare"
  -- The source-only shortcut computes `runSourceRules`; the artifact path computes the whole
  -- registry. They agree on a file only when it triggers no `syntax`-tier rule, and `LocalSyntax`
  -- carries none (no duplicate attribute/deriving, `set_option`, unclosed scope, or nested paren) —
  -- so the full-registry findings still coincide with the source-only ones here. This is the
  -- cross-path agreement `RRE-SPEC` §2 demanded; the tier tag on the cache entry, not finding
  -- equality, is what keeps the paths honest when a file *does* trigger a syntax rule.
  ensure (artifactResult.findings == runSourceRules normalized)
    "the artifact path and the source-only shortcut disagree about one unchanged file"

/-! ## Layout

`RLC-SPEC` froze the contract these check, and its numbers came from `experiments/layout-core/`, which
shares no module with this one. Several assertions below deliberately re-assert an exact figure from
that experiment: if the product and the prototype ever disagree about margin 13, one of them is wrong
and this is where it surfaces. -/

private def hugeWidth : Nat := 1000000

private def stripLayout (s : String) : String :=
  s.foldl (fun acc c => if c == '\n' || c == ' ' then acc else acc.push c) ""

private def lineCount (s : String) : Nat := (s.splitOn "\n").length

/-- The text at a byte range. `Mark.output` and `Comment.range` are byte-indexed, like every other
offset in the projection, so a test that reads one back must slice by bytes too. -/
private def slice (s : String) (start stop : Nat) : String :=
  (Substring.Raw.mk s ⟨start⟩ ⟨stop⟩).toString

private def nextRand (seed : Nat) : Nat := (seed * 1103515245 + 12345) % 2147483648

/-- A letters-only atom: no space and no newline, so `stripLayout` cannot eat part of one. -/
private def atomFor (r : Nat) : String :=
  String.ofList (List.replicate (r % 6 + 1) (Char.ofNat (97 + r % 26)))

private structure GeneratedDoc where
  document : Doc
  flat : String
  atoms : String
  nextSeed : Nat
  deriving Inhabited

/-- A deterministic document generator with an independent expected flat spelling and literal-atom
model. Seeded rather than random so a failure is reproducible from the printed seed alone; `hard`,
`verbatim`, and registered leaves are excluded because these properties concern custom groups. -/
private partial def genDoc (depth : Nat) (seed : Nat) : GeneratedDoc :=
  let r := nextRand seed
  if depth == 0 then
    match r % 3 with
    | 0 => { document := .empty, flat := "", atoms := "", nextSeed := r }
    | 1 =>
      let atom := atomFor r
      { document := .text atom, flat := atom, atoms := atom, nextSeed := r }
    | _ =>
      let flat := if r % 2 == 0 then " " else ""
      { document := .line flat, flat, atoms := "", nextSeed := r }
  else
    match r % 7 with
    | 0 =>
      let atom := atomFor r
      { document := .text atom, flat := atom, atoms := atom, nextSeed := r }
    | 1 => { document := .line " ", flat := " ", atoms := "", nextSeed := r }
    | 2 => { document := .line "", flat := "", atoms := "", nextSeed := r }
    | 3 =>
      let left := genDoc (depth - 1) r
      let right := genDoc (depth - 1) left.nextSeed
      {
        document := .cat left.document right.document
        flat := left.flat ++ right.flat
        atoms := left.atoms ++ right.atoms
        nextSeed := right.nextSeed }
    | 4 =>
      let generated := genDoc (depth - 1) r
      { generated with document := .nest 2 generated.document }
    | 5 =>
      let generated := genDoc (depth - 1) r
      { generated with document := .group generated.document }
    | _ =>
      let generated := genDoc (depth - 1) r
      { generated with document := .mark ⟨r % 100, r % 100 + 5⟩ generated.document }

private def testDoc : IO Unit := do
  -- The case the whole model was chosen for. A `do` block is `do act1; act2` flat and drops the
  -- separator when broken. Measured in `experiments/layout-core`: Oppen *and* `Std.Format` both
  -- render `do\n  act1;\n  act2` here and strand the semicolon, because their break carries blanks
  -- only. This is the one thing `line (flat)` buys, so it is the first thing checked.
  let doBlock : Doc :=
    .text "do" ++ .nest 2 (.group (.line " " ++ .text "act1" ++ .line "; " ++ .text "act2"))
  ensure (renderText 40 doBlock == "do act1; act2") "the flat do block lost its separator"
  ensure (renderText 12 doBlock == "do\n  act1\n  act2") "the broken do block stranded its separator"

  -- A group is decided against the line, not against itself: `f(arg)` is 6 columns but the line it
  -- would produce is 14. The flip at 13/14 is the exact figure `experiments/layout-core` records.
  let tail : Doc :=
    .group (.text "f(" ++ .nest 2 (.line "" ++ .text "arg") ++ .line "" ++ .text ")") ++ .text " => tail"
  ensure (renderText 14 tail == "f(arg) => tail") "a group that fits its line was broken"
  ensure (renderText 13 tail == "f(\n  arg\n) => tail") "a group whose line overflows stayed flat"
  -- A margin is not a guarantee: `) => tail` is atomic, so no margin makes this line shorter.
  ensure (renderText 5 tail == "f(\n  arg\n) => tail") "an unbreakable atom was broken anyway"

  -- Nested groups decide independently: the outer breaks, the inner still fits.
  let nested : Doc := .group (.text "aaaa" ++ .line " " ++ .group (.text "b" ++ .line " " ++ .text "c"))
  ensure (renderText 6 nested == "aaaa\nb c") "an inner group broke because its parent did"

  -- `hard` forces every enclosing group open. This is why a line comment is safe: `--` swallows its
  -- line, so a group must never flatten one onto the same line as the code that follows it.
  ensure (renderText hugeWidth (.group (.text "a" ++ .hard ++ .text "b")) == "a\nb")
    "a group containing a hard break was flattened"
  ensure (renderText hugeWidth (.nest 2 (.group (.text "a" ++ .hard ++ .text "b"))) == "a\n  b")
    "a hard break ignored the current indentation"
  ensure (renderText hugeWidth (.nest 2 (.text "a" ++ .blank ++ .text "b")) == "a\n\n  b")
    "a structural blank line contained indentation whitespace"

  -- `verbatim` is the constructor `RLC-IMPL` added, and this is the reason: a block comment's
  -- interior is content, and `hard` would re-indent it. `Std.Format` re-indents it too.
  let block : Doc := .nest 4 (.hard ++ .verbatim "/- a\n b -/" ++ .hard ++ .text "x")
  ensure (renderText hugeWidth block == "\n    /- a\n b -/\n    x")
    "verbatim text was re-indented, rewriting its content"
  -- After a multi-line verbatim the column is its last line, not the old column plus its width.
  ensure (renderText 12 (.group (.verbatim "aa\nbbb" ++ .line " " ++ .text "cc")) == "aa\nbbb\ncc")
    "a multi-line verbatim was treated as flat"

  -- `text` claims to be one line, and the claim is checkable rather than conventional.
  ensure (Doc.wellFormed doBlock) "a well-formed document was rejected"
  ensure (!Doc.wellFormed (.text "a\nb")) "a text holding two lines was accepted"
  ensure (!Doc.wellFormed (.line "a\nb")) "a break with a multi-line flat spelling was accepted"
  ensure (Doc.wellFormed (.verbatim "a\nb")) "verbatim is how a newline is stated and was rejected"
  ensure (!Doc.wellFormed (.mark ⟨20, 10⟩ (.text "x"))) "a reversed source mark was accepted"

  -- Columns are codepoints, as in Lean's native renderer. Six CJK codepoints plus a space and `x`
  -- fit at eight despite occupying more terminal cells, and fail at seven.
  let unicode : Doc := .group (.text "世界世界世界" ++ .line " " ++ .text "x")
  ensure (renderText 8 unicode == "世界世界世界 x") "Unicode columns were counted as bytes or cells"
  ensure (renderText 7 unicode == "世界世界世界\nx") "a Unicode group did not break at its codepoint width"

  -- A registered formatter result remains opaque and is interpreted at the active column. Its
  -- native group therefore sees the two columns already emitted by the custom prefix.
  let native := Std.Format.group ("a" ++ Std.Format.line ++ "b")
  let hybrid : Doc := .text "x " ++ .registered native
  let wideHybrid := renderDetailed 5 hybrid
  let narrowHybrid := renderDetailed 4 hybrid
  ensure (wideHybrid.text == "x a b") "an opaque registered document ignored its active column"
  ensure (narrowHybrid.text == "x a\nb") "an opaque registered document did not reflow"
  ensure (wideHybrid.metrics.nativeEvents > 0 && narrowHybrid.metrics.nativeEvents > 0)
    "the registered document was not interpreted through the native renderer"

  -- Source map. Output ranges are bytes; `mark` carries no width and renders exactly as its body.
  let marked : Doc := .text "a" ++ .mark ⟨10, 20⟩ (.text "bcd") ++ .text "e"
  let (out, marks) := render hugeWidth marked
  ensure (out == "abcde") "mark changed the rendering"
  ensure (marks == #[{ source := ⟨10, 20⟩, output := ⟨1, 4⟩ }]) "the source map recorded the wrong range"
  ensure (slice out 1 4 == "bcd") "the recorded output range does not hold the marked text"

  -- Marks complete innermost-first, so the array is in completion order rather than source order.
  let (_, nestedMarks) := render hugeWidth (.mark ⟨1, 2⟩ (.text "x" ++ .mark ⟨3, 4⟩ (.text "y")))
  ensure (nestedMarks == #[{ source := ⟨3, 4⟩, output := ⟨1, 2⟩ }, { source := ⟨1, 2⟩, output := ⟨0, 2⟩ }])
    "nested marks were not recorded innermost-first"

  -- A mark spanning a break still bounds exactly what it produced.
  let (spanOut, spanMarks) := render 4 (.mark ⟨0, 9⟩ (.group (.text "aaa" ++ .line " " ++ .text "bbb")))
  ensure (spanOut == "aaa\nbbb") "a marked group did not break"
  ensure (spanMarks.size == 1 && slice spanOut spanMarks[0]!.output.start spanMarks[0]!.output.stop == spanOut)
    "a mark spanning a break lost part of its output"

  -- `RSF-SPEC` (`ruff-14`) characterization: **when is a rendered unit's bytes independent of what
  -- follows it?** Range formatting reports an actual range and promises the text outside it is
  -- byte-identical, so it may only expand to a unit whose rendering the rest of the document cannot
  -- re-decide. That is not a property of commands — it is a property of `fits`, which walks the
  -- *tail* of the work list (`Doc.lean:168-188`). A group at the end of a unit therefore measures
  -- itself against whatever comes after, unless something between them stops the walk.
  --
  -- Exactly one thing does: a `verbatim` holding a newline, which `fits` treats like `hard`
  -- (`Doc.lean:174-176`). So "ends in trivia containing a newline" is the frozen unit boundary
  -- condition, and `notes/01-stream-range.md` §4 states it as such.
  let unitEndingIn (trailing : String) : Doc :=
    .group (.text "aaaa" ++ .line " " ++ .text "bbbb") ++ .verbatim trailing
  -- At margin 10 the group is 9 columns and fits flat on its own either way.
  ensure (renderText 10 (unitEndingIn "\n") == "aaaa bbbb\n") "the newline-terminated unit did not fit flat"
  ensure (renderText 10 (unitEndingIn " ") == "aaaa bbbb ") "the space-terminated unit did not fit flat"
  -- Newline-terminated: no tail, however long, can reach back through it.
  ensure ((renderText 10 (unitEndingIn "\n" ++ .text "yyyyyyyyyyyyyyyy")).startsWith
      (renderText 10 (unitEndingIn "\n")))
    "a newline-terminated unit's layout depended on the document after it"
  -- Not newline-terminated: a one-character tail is enough to rebreak the unit before it. This is
  -- the same-line case (`def a := 1 def b := 2`), and it is why a range must expand to a newline.
  ensure (renderText 10 (unitEndingIn " " ++ .text "x") == "aaaa\nbbbb x")
    "a space-terminated unit was not rebroken by the text after it — the fit walk no longer runs into \
     the tail, so the range-expansion boundary condition needs restating"

  -- Properties over 400 generated documents. The seed is printed on failure, and generation is
  -- deterministic, so a counterexample is reproducible from that number alone.
  let mut seed := 20260716
  for i in [0:400] do
    let generated := genDoc 5 seed
    seed := generated.nextSeed
    let wrapped : Doc := .group generated.document
    ensure (Doc.wellFormed wrapped) s!"generated document {i} (seed {seed}) was not well formed"
    -- At an unreachable margin every group is flat, so the renderer must agree with an
    -- independently defined flat rendering. This is what pins `line`'s flat text end to end.
    ensure (renderText hugeWidth wrapped == generated.flat)
      s!"flat rendering diverged on document {i} (seed {seed})"
    -- At margin 0 every group with any width breaks, so only the literal atoms survive. Nothing may
    -- be dropped, duplicated, or reordered by breaking.
    ensure (stripLayout (renderText 0 wrapped) == generated.atoms)
      s!"breaking lost or duplicated text on document {i} (seed {seed})"
    for width in [0, 1, 40, 80, 100, 1000] do
      -- Rendering is a function, not a process with state.
      let rendered := renderDetailed width wrapped
      ensure (renderDetailed width wrapped == rendered)
        s!"rendering at width {width} was not deterministic on document {i} (seed {seed})"
      -- Every recorded range must address real output.
      for mark in rendered.sourceMap do
        ensure (mark.output.start <= mark.output.stop && mark.output.stop <= rendered.text.utf8ByteSize)
          s!"document {i} (seed {seed}) recorded an out-of-bounds output range at width {width}"
      -- A document can emit no more custom commands than a fixed multiple of its nodes and marks.
      ensure (rendered.metrics.workSteps <= 2 * Doc.size wrapped + 1)
        s!"document {i} (seed {seed}) exceeded its work-step bound at width {width}"
      ensure (lineCount rendered.text <= Doc.size wrapped + 1)
        s!"document {i} (seed {seed}) produced more lines than nodes at width {width}"

/-- `ruff-14` RSF-IMPL: unit selection and splicing over a layout source map.

Driven with a hand-built map rather than a real render, because the questions here are about the
selection algebra — which units a request reaches, when the forward extension fires, what the actual
range is, and whether the splice keeps the caller's bytes — and a synthetic map states each case in
one line. `tests/modes/run.sh` drives the same code through the real printer. -/
private def testRangeSelection : IO Unit := do
  -- Three units over a 24-byte source. Unit 1's *output* does not end in a newline, which is the
  -- same-line-commands shape (`def a := 1 def b := 2`) the forward extension exists for.
  --   source:   [0,8) [8,16) [16,24)
  --   rendered: [0,8) [8,15) [15,23)
  let normalized := "AAAAAAA\nBBBBBBB\nCCCCCCC\n"
  let rendered := "aaaaaaa\n" ++ "bbbbbb " ++ "ccccccc\n"
  let marks : Array Mark := #[
    { source := ⟨0, 8⟩,   output := ⟨0, 8⟩ },
    { source := ⟨8, 16⟩,  output := ⟨8, 15⟩ },
    { source := ⟨16, 24⟩, output := ⟨15, 23⟩ }]
  let run (start stop : Nat) : Option Application.RangeResult :=
    Application.sliceRange normalized rendered marks ⟨start, stop⟩

  -- A request inside unit 0 formats unit 0 and nothing else: its output ends in a newline, so the
  -- extension does not fire, and units 1-2 keep their source bytes verbatim.
  let some first := run 2 4 | ensure false "a request inside unit 0 selected no unit"; return
  ensure (first.actual == ⟨0, 8⟩) s!"unit 0 request reported actual range {repr first.actual}"
  ensure (first.text == "aaaaaaa\nBBBBBBB\nCCCCCCC\n")
    s!"unit 0 splice did not keep the later units' source bytes: {repr first.text}"

  -- A request inside unit 1 must drag unit 2 in: unit 1's output ends in a space, so its layout was
  -- decided by what follows it, and reporting `[8,16)` would be a promise the bytes do not keep.
  let some second := run 9 10 | ensure false "a request inside unit 1 selected no unit"; return
  ensure (second.actual == ⟨8, 24⟩)
    s!"the forward extension did not fire on a unit ending mid-line: {repr second.actual}"
  ensure (second.text == "AAAAAAA\nbbbbbb ccccccc\n")
    s!"unit 1-2 splice is wrong: {repr second.text}"

  -- Full range reproduces the whole render byte for byte. This is the roadmap's whole-file /
  -- full-range equivalence, stated where the splice can be held to it.
  let some whole := run 0 24 | ensure false "the full range selected no unit"; return
  ensure (whole.text == rendered) s!"full range did not reproduce the render: {repr whole.text}"
  ensure (whole.actual == ⟨0, 24⟩) s!"full range reported {repr whole.actual}"

  -- An empty request is a cursor position: it selects the unit holding that offset. On a boundary it
  -- takes the unit that *starts* there, not the one that ends there.
  let some empty := run 3 3 | ensure false "an empty request selected no unit"; return
  ensure (empty.actual == ⟨0, 8⟩) s!"an empty request in unit 0 reported {repr empty.actual}"
  let some boundary := run 8 8 | ensure false "a boundary request selected no unit"; return
  ensure (boundary.actual == ⟨8, 24⟩)
    s!"an empty request on the 0/1 boundary did not take the unit starting there: {repr boundary.actual}"
  -- At end of file there is no unit starting there, so the last one answers.
  let some eof := run 24 24 | ensure false "an end-of-file request selected no unit"; return
  ensure (eof.actual == ⟨16, 24⟩) s!"an end-of-file request reported {repr eof.actual}"

  -- Reported output ranges must index the text the caller was handed, not the pre-splice render.
  ensure (second.marks.size == 2) s!"the 1-2 request reported {second.marks.size} units"
  let body := second.marks[0]!
  ensure (slice second.text body.output.start second.marks[1]!.output.stop == "bbbbbb ccccccc\n")
    "the re-based output ranges do not bound the formatted text"

  -- A map with no units at all cannot answer, and says so rather than inventing an empty range.
  ensure ((Application.sliceRange normalized rendered #[] ⟨0, 4⟩).isNone) "an empty source map produced a result"

/-- Project suppression directives over findings, and recover directives from the module header.

`apply` is a pure projection over `Array Finding`; the first block checks it in isolation, with
hand-built facts, so the scope arithmetic is tested without a parser. The second block is the
regression that `RSP-IMPL` found and fixed: a directive in the module header `[0, headerStop)` — the
natural home for `ignore-file` — is invisible to artifact trivia, so `collect` scans the header
itself. A hand-built single-command projection puts a directive above the first command and asserts it
is both parsed and, when malformed, reported rather than dropped. -/
private def testSuppression : IO Unit := do
  -- `apply` in isolation. `src` supplies real bytes for the `FMT900` removal fix's range math.
  let src := "module\n-- lean-fmt: ignore-file\ndef x := 1  \n"
  let bytes := src.toUTF8
  let mkFinding (code : String) (start stop : Nat) : Finding :=
    { code, severity := .warning, message := "x", range := ⟨start, stop⟩ }
  -- Synthetic findings drive the code-agnostic suppression machinery. `f013` is a line-range finding;
  -- `f014` is an empty range on the file's upper bound (the shape a rule can still produce, e.g. an
  -- end-of-file diagnostic), kept to prove an empty finding on a scope boundary is caught.
  let f013 := mkFinding "FMT011" 42 44
  let f014 := mkFinding "FMT012" 44 44
  let mkDir (scope : DirectiveScope) (codes? : Option (Array String))
      (scopeRange : SourceRange) : Directive :=
    { scope, codes?, scopeRange, commentRange := ⟨7, 31⟩ }
  let facts (ds : Array Directive) : SuppressionFacts := { directives := ds, malformed := #[] }

  -- File-scope blanket suppresses every finding in the file.
  let blanket := Suppression.apply (facts #[mkDir .file none ⟨0, bytes.size⟩]) bytes #[f013, f014]
  ensure (blanket.kept.isEmpty && blanket.suppressed == 2 && blanket.unused.isEmpty)
    "file blanket did not suppress every finding"

  -- Code selector suppresses only the named code; the other survives.
  let named := Suppression.apply (facts #[mkDir .file (some #["FMT011"]) ⟨0, bytes.size⟩]) bytes #[f013, f014]
  ensure (named.kept.map (·.code) == #["FMT012"] && named.suppressed == 1 && named.unused.isEmpty)
    "code selector suppressed the wrong set"

  -- Suppression is a projection over codes, so the source-security codes flow through it like any
  -- other. A report-only FMT002 finding is suppressed by a directive that names it.
  let f004 := mkFinding "FMT002" 42 45
  let bidiSuppressed := Suppression.apply (facts #[mkDir .file (some #["FMT002"]) ⟨0, bytes.size⟩]) bytes #[f004]
  ensure (bidiSuppressed.kept.isEmpty && bidiSuppressed.suppressed == 1)
    "a directive naming FMT002 did not suppress the report-only security finding"

  -- A directive whose scope holds no matching finding is unused: FMT900 with a safe removal fix.
  let dead := Suppression.apply (facts #[mkDir .line (some #["FMT011"]) ⟨7, 31⟩]) bytes #[f013]
  ensure (dead.kept.size == 1 && dead.suppressed == 0) "an out-of-scope directive still suppressed"
  ensure (dead.unused.map (·.code) == #["FMT900"]) "an unused directive did not emit FMT900"
  ensure (dead.unused[0]!.fix?.map (·.applicability) == some .safe) "the FMT900 removal fix is not safe"
  -- The removal edit is a *clean line* deletion: a directive alone on its line takes the whole line
  -- and its terminating newline (`⟨7, 32⟩` over `src` — `-- …-file` is `[7, 31)`, the `\n` is `31`),
  -- and replaces with nothing. Applying it must leave `module\ndef x := 1  \n`, not a blank line.
  let removal := dead.unused[0]!.fix?.bind (·.edits[0]?)
  ensure (removal.map (·.range) == some ⟨7, 32⟩ && removal.map (·.replacement) == some "")
    "the FMT900 removal fix does not delete exactly the directive line and its newline"

  -- A list with one live and one dead code suppresses the live one and reports the dead one.
  let mixed := Suppression.apply (facts #[mkDir .file (some #["FMT011", "FMT999"]) ⟨0, bytes.size⟩]) bytes #[f013]
  ensure (mixed.suppressed == 1 && mixed.unused.map (·.code) == #["FMT900"])
    "a mixed live/dead code list did not both suppress and report"

  -- `ruff-12` §7's non-breaking floor -- a retired/reserved code is inert in a suppression: it
  -- suppresses nothing but is never flagged unused, unlike a genuinely-unknown code (FMT999 above,
  -- which does raise FMT900) -- HAD three cases here. They used FMT001 as their retired instance.
  --
  -- The pre-release renumbering (`docs/rules/MIGRATION.md`) made FMT001 a *live* security rule and
  -- emptied `reservedCodes`, so those three cases would have kept running and kept passing while
  -- testing something else entirely: a live rule that happened not to fire. A test that still passes
  -- after its subject has been redefined underneath it is worse than a deleted one, so they are
  -- deleted rather than repointed.
  --
  -- The production branches they covered are still there and still reachable the moment a rule
  -- retires. They are currently UNTESTED, which `reservedCodes`' docstring states at the definition.
  -- Restoring coverage needs a real retirement, not a placeholder entry invented to have something to
  -- assert against.

  -- The empty finding sits exactly on a file scope's upper bound and must still be caught.
  let eof := Suppression.apply (facts #[mkDir .file none ⟨0, 44⟩]) bytes #[f014]
  ensure (eof.suppressed == 1) "a file scope ending at EOF did not catch the empty finding"

  -- Header recovery. `headerStop` is the first command's start, so the directive on line 2 lives in
  -- `[0, headerStop)`, which the artifact omits and `collect` must scan for itself.
  let mkProj (text : String) (headerStop : Nat) : LosslessSource :=
    let size := text.utf8ByteSize
    let tokenStop := headerStop + 3
    {
      schema := losslessSourceSchema
      mainModule := "Test"
      normalizedBytes := size
      normalizedDigest := Digest.ofString text
      headerStop
      terminalStop := size
      kinds := #["Lean.Parser.Command.declaration"]
      nodes := #[{ kind := 0, parent := none, range := ⟨headerStop, size⟩ }]
      tokens := #[{ node := 0, start := headerStop, stop := tokenStop, trailing := #[{ kind := .whitespace, stop := size }] }]
    }
  let headerFacts := Suppression.collect (mkProj src 32) src
  ensure (headerFacts.directives.size == 1) "collect missed a directive in the module header"
  ensure (headerFacts.directives[0]!.scope == .file) "the header directive parsed with the wrong scope"
  ensure (headerFacts.directives[0]!.scopeRange == ⟨0, src.utf8ByteSize⟩)
    "the header ignore-file scope is not the whole file"
  ensure headerFacts.malformed.isEmpty "a well-formed header directive was flagged malformed"

  -- A malformed header directive is reported (FMT901, display-only), never silently dropped.
  let badSrc := "module\n-- lean-fmt: nope\ndef x := 1\n"
  let badFacts := Suppression.collect (mkProj badSrc 25) badSrc
  ensure (badFacts.directives.isEmpty && badFacts.malformed.map (·.code) == #["FMT901"])
    "a malformed header directive was not reported as FMT901"
  ensure (badFacts.malformed[0]!.fix?.map (·.applicability) == some .displayOnly)
    "the FMT901 fix is not display-only"

/-- Report live-syntax ownership captured inside the exact frontend lifetime. -/
private def commentSummaryReport (envelopePath : String) : IO UInt32 := do
  let .ok json := Lean.Json.parse (← IO.FS.readFile envelopePath)
    | throw <| IO.userError s!"{envelopePath} is not JSON"
  let .ok (envelope : AnalysisEnvelope) := Lean.fromJson? json
    | throw <| IO.userError s!"{envelopePath} is not an analysis envelope"
  let some summary := envelope.commentSummary?
    | throw <| IO.userError "exact frontend captured no comment ownership summary"
  ensure summary.valid "comment ownership did not assign every extracted payload exactly once"
  IO.println <| (Lean.toJson summary).compress
  return 0
/- Layout cost, including the zero-width shapes that exposed the former renderer's suffix-rescan
defect. `docStepCounts` is the durable assertion; `docBench` remains a non-gating local timing probe.

Construction is deliberately outside every timed region, and every timed region forces its result: a
pure `let` in Lean is not evaluated where it is written, and an unforced `render` measures 166 ns for
any `n` — which is how this benchmark first lied. -/

/-- **The adversary.** `n` sibling groups that never spend a column and never offer a break. The old
fit walk rescanned the whole tail for each group; cached work summaries now make every decision
constant-time. -/
private def zeroWidthSiblings (n : Nat) : Doc := Id.run do
  let mut d := Doc.text "x"
  for _ in [0:n] do
    d := .cat (.group (.nest 1 .empty)) d
  return d

/-- **Adversarial nesting**: `n` zero-width groups deep, complementary to sibling width. -/
private def zeroWidthNesting (n : Nat) : Doc := Id.run do
  let mut d := Doc.text "x"
  for _ in [0:n] do
    d := .group (.nest 1 d)
  return d

/-- A Lean-shaped call, `f(a0, a1, ...)`: one group, `n` arguments, every argument carrying text. This
is the shape a real printer emits, and the difference from `zeroWidthSiblings` is only that the text is
there. -/
private def callArgs (n : Nat) : Doc := Id.run do
  let mut inner := Doc.empty
  for i in [0:n] do
    let arg := Doc.text s!"a{i}"
    inner := if i == 0 then arg else .cat inner (.cat (.text ",") (.cat (.line " ") arg))
  return .group (.cat (.text "f(") (.cat (.nest 2 (.cat (.line "") inner)) (.cat (.line "") (.text ")"))))

/-- `n` nested calls, `f(f(f(...)))` — the depth axis rather than the width axis. -/
private def nestedCalls (n : Nat) : Doc := Id.run do
  let mut d := Doc.text "x"
  for _ in [0:n] do
    d := .group (.cat (.text "f(") (.cat (.nest 2 (.cat (.line "") d)) (.cat (.line "") (.text ")"))))
  return d

/-- `callArgs` with every argument marked, which is what a real printer does: one mark per token. The
cost of `mark` is the open question `RLC-IMPL` left to this prompt. -/
private def markedCallArgs (n : Nat) : Doc := Id.run do
  let mut inner := Doc.empty
  for i in [0:n] do
    let arg := Doc.mark ⟨i, i + 1⟩ (.text s!"a{i}")
    inner := if i == 0 then arg else .cat inner (.cat (.text ",") (.cat (.line " ") arg))
  return .group (.cat (.text "f(") (.cat (.nest 2 (.cat (.line "") inner)) (.cat (.line "") (.text ")"))))

private def benchOne (label : String) (n : Nat) (d : Doc) : IO Unit := do
  -- Force construction before the clock starts, so building the fixture is not in the measurement.
  if d.size == 0 then throw (IO.userError "the fixture is empty")
  let start ← IO.monoNanosNow
  let (out, marks) := render 80 d
  -- `utf8ByteSize` is O(1) and forces the render; `String.length` would walk the output and bill the
  -- walk to the renderer.
  if out.utf8ByteSize + marks.size == 999999999 then throw (IO.userError "impossible")
  let stop ← IO.monoNanosNow
  IO.println s!"{label} n={n} nodes={d.size} ms={(Float.ofNat (stop - start)) / 1000000.0} \
out_bytes={out.utf8ByteSize} marks={marks.size}"

/-- Every generated document rendered at every margin, as text.

This exists to settle equivalence claims about the renderer by diffing two builds, rather than by
arguing that a change "should not" alter output. `results/03-acceptance.md` records the one it settled. -/
private def docDump : IO UInt32 := do
  let mut seed : Nat := 20260716
  for i in [0:400] do
    let generated := genDoc 4 seed
    seed := generated.nextSeed
    for w in [0:41] do
      IO.println s!"{i} {w} {String.intercalate "⏎" ((renderText w generated.document).splitOn "\n")}"
  return 0

/-! ## Source-security microbenchmark (`RSR-FINAL`)

The two source-security scans are linear in source size: `FMT001` is one pass over the byte array,
`FMT002` one fold over the codepoints carrying a running offset. This measures that claim the way
`docBench` measures the printer — by growth *ratio* over doubling inputs, not a wall-clock budget,
because linear and quadratic differ by the size step (here 8×) and mean the same thing on any machine.
`tests/security/bench.sh` asserts the ratios.

The measured input is scan-clean — no control or bidi byte — so the shared post-scan `qsort` over
findings (`Rules.findingOrder`), which every rule pays and is O(m log m) in the finding count m rather
than anything new to these rules, contributes nothing and the number reported is the scan cost itself.
The block carries three-byte CJK scalars so the `FMT002` fold's per-character `utf8Size` offset
arithmetic is exercised across widths, not just one-byte ASCII. A separate dense input confirms the
scans still produce findings at scale. This runs in the single test process — there is no worker, no
child, and no project setup, because a source-tier rule reads only the string it is handed. -/
private def securityCleanBlock : String :=
  -- ASCII plus four 3-byte CJK scalars, no trailing whitespace, newline-terminated so the joined
  -- input is whitespace/newline-clean and the timing is the scan alone.
  "def value : Nat := 42 -- 注释 中文\n"

/-- One control byte (NUL) and one bidi mark (U+202E), inside a string literal, per short block. -/
private def securityDenseBlock : String :=
  "def x := \"a" ++ String.ofList [Char.ofNat 0x00] ++ "b" ++ String.ofList [Char.ofNat 0x202e] ++
    "c\"\n"

/-- Grow `block` to at least `targetBytes` by doubling, so construction is O(size) — a linear join of
`k` copies would be O(size²) and would swamp the scan it is meant to feed. -/
private def repeatTo (block : String) (targetBytes : Nat) : String := Id.run do
  let mut s := block
  for _ in [0:64] do
    if s.utf8ByteSize ≥ targetBytes then break
    s := s ++ s
  return s

private def securityBenchOne (label : String) (input : String) : IO Unit := do
  if input.utf8ByteSize == 0 then throw (IO.userError "the bench input is empty")
  let start ← IO.monoNanosNow
  let findings := runSourceRules input
  -- Force the scan; a size comparison walks nothing but pins the array.
  if findings.size == 999999999 then throw (IO.userError "impossible")
  let stop ← IO.monoNanosNow
  IO.println s!"{label} bytes={input.utf8ByteSize} \
ms={(Float.ofNat (stop - start)) / 1000000.0} findings={findings.size}"

private def securityBench : IO UInt32 := do
  -- A ~2 MB scan-clean base, then exact doublings to 4/8/16 MB. Each doubling is built outside the
  -- timed region, so a ~2× step in ms across a 2× step in bytes is the linear claim.
  let mut input := repeatTo securityCleanBlock 2000000
  for label in ["clean-1x", "clean-2x", "clean-4x", "clean-8x"] do
    securityBenchOne label input
    input := input ++ input
  -- Findings do scale: a dense ~256 KB input reports two per block. This is deliberately not part of
  -- the linear assertion — its cost is dominated by the engine's shared O(m log m) finding-sort
  -- (`Rules.findingOrder`), which every rule pays and is not the scan. It proves only that the scans
  -- still fire at size, worker-free.
  securityBenchOne "dense" (repeatTo securityDenseBlock 256000)
  return 0

/-! ## Frontend-native formatter contract harness

`tests/formatter/oracle.py` owns the independent comparison. This one test-only command exposes the
already-shipped lossless header parser so the oracle compares Lean's parsed ordered imports rather
than approximating the header with a regular expression. It returns facts only; the Python harness
decides whether two signatures agree. -/

private def formatterHeader (sourcePath : String) : IO UInt32 := do
  let raw ← IO.FS.readFile sourcePath
  let normalized := (LosslessSource.normalize raw).1
  let some header ← Imports.parseHeaderModel normalized
    | do
      IO.eprintln s!"header did not parse: {sourcePath}"
      return 1
  let imports := header.imports.map fun stmt => Lean.Json.mkObj [
    ("module", .str stmt.module.toString),
    ("all", stmt.importAll),
    ("meta", stmt.isMeta),
    ("public", stmt.isPublic),
    ("exported", stmt.isExported)
  ]
  IO.println <| (Lean.Json.mkObj [
    ("module", header.hasModule),
    ("prelude", header.hasPrelude),
    ("imports", .arr imports)
  ]).compress
  return 0

private def docBench : IO UInt32 := do
  for n in [1000, 2000, 4000, 8000] do
    benchOne "zero-width-siblings" n (zeroWidthSiblings n)
  for n in [1000, 2000, 4000, 8000] do
    benchOne "zero-width-nesting" n (zeroWidthNesting n)
  for n in [1000, 10000, 100000] do
    benchOne "call-args" n (callArgs n)
  -- Capped at 10,000: `nest` is unclamped by contract (§4.6), so depth `n` at unit 2 emits Θ(n²)
  -- *bytes* — 200 MB here, and 20 GB at n=100,000. That cost is the output, not the fit test, which is
  -- why the assertion in `bench.sh` is per output byte rather than per node.
  for n in [100, 1000, 10000] do
    benchOne "nested-calls" n (nestedCalls n)
  for n in [1000, 10000, 100000] do
    benchOne "marked-call-args" n (markedCallArgs n)
  return 0

/-- Machine-independent renderer work for the adversarial and Lean-shaped documents. One custom
node is visited once and each mark adds exactly one close sentinel; no fit decision walks a suffix. -/
private def docStepCounts : IO UInt32 := do
  let report (label : String) (n : Nat) (document : Doc) : IO Unit := do
    let rendered := renderDetailed 80 document
    IO.println s!"doc-steps label={label} n={n} nodes={rendered.metrics.documentNodes} \
steps={rendered.metrics.workSteps} marks={rendered.sourceMap.size} native={rendered.metrics.nativeEvents}"
  for n in [1000, 8000] do
    report "zero-width-siblings" n (zeroWidthSiblings n)
    report "zero-width-nesting" n (zeroWidthNesting n)
    report "call-args" n (callArgs n)
    report "marked-call-args" n (markedCallArgs n)
  return 0

private def validatorMapNegative : IO UInt32 := do
  let base : FormatDraft := {
    text := "abc"
    headerContract := #[]
    commentContract := #[]
    metrics := default
    sourceDigest := ""
    sourceBytes := 3
    headerStop := 0
    terminalStop := 3
    sourceMap := #[{ source := ⟨0, 3⟩, output := ⟨0, 3⟩ }] }
  ensure (Validator.validateMap base).isOk "a complete source map was rejected"
  let defects : Array (String × FormatDraft) := #[
    ("missing source tail", { base with
      sourceMap := #[{ source := ⟨0, 2⟩, output := ⟨0, 3⟩ }] }),
    ("overlapping source units", { base with sourceMap := #[
      { source := ⟨0, 2⟩, output := ⟨0, 2⟩ },
      { source := ⟨1, 3⟩, output := ⟨2, 3⟩ }] }),
    ("out-of-order source units", { base with sourceMap := #[
      { source := ⟨1, 2⟩, output := ⟨0, 1⟩ },
      { source := ⟨0, 1⟩, output := ⟨1, 2⟩ },
      { source := ⟨2, 3⟩, output := ⟨2, 3⟩ }] }),
    ("inverted source unit", { base with
      sourceMap := #[{ source := ⟨2, 1⟩, output := ⟨0, 3⟩ }] }),
    ("inverted output unit", { base with
      sourceMap := #[{ source := ⟨0, 3⟩, output := ⟨2, 1⟩ }] }),
    ("short output tail", { base with
      sourceMap := #[{ source := ⟨0, 3⟩, output := ⟨0, 2⟩ }] })]
  for (label, defect) in defects do
    match Validator.validateMap defect with
    | .error failure => ensure (failure.gate == .sourceMap) "wrong source-map rejection gate"
    | .ok _ => throw <| IO.userError s!"an invalid source map was admitted: {label}"
  IO.println s!"validator-map-negative cases={defects.size}"
  return 0

private def incrementalSource (middle : String := "def beta : Nat := alpha + 2")
    (tail : String := "#check gamma") : String :=
  s!"module\nimport Lean\n\nnamespace IncrementalFixture\n\nsyntax \"twice \" term : term\nmacro_rules\n  | `(twice $value) => `($value + $value)\n\ndef alpha : Nat := 1\n{middle}\ndef gamma : Nat := twice beta\n\n{tail}\n\nend IncrementalFixture\n"

private def sameEnvelope (left right : AnalysisEnvelope) : Bool :=
  (Lean.toJson left).compress == (Lean.toJson right).compress

private def residentKiB : IO Nat := do
  let pid ← IO.Process.getPID
  let output ← IO.Process.output { cmd := "ps", args := #["-o", "rss=", "-p", toString pid] }
  return output.stdout.trimAscii.toString.toNat?.getD 0

/-! A focused executable-level contract for the persistent frontend session. The edit table varies
one concern at a time and compares the full JSON envelope with a fresh one-shot frontend, not merely
the formatted text. Pointer-sharing counts are observations of Lean's actual snapshot DAG. -/
private unsafe def incrementalAnalyzerSpec (setupPath sourcePath : String) : IO UInt32 := do
  let .ok setupJson := Lean.Json.parse (← IO.FS.readFile setupPath) | return 2
  let .ok (setup : Lean.ModuleSetup) := Lean.fromJson? setupJson | return 2
  let path : System.FilePath := sourcePath
  let analyzer ← IncrementalAnalyzer.open
  let base := incrementalSource
  let opened ← analyzer.analyze setup base path
  let freshBase ← analyzeExact setup base path
  ensure (sameEnvelope opened.envelope freshBase) "initial incremental analysis differs from fresh"
  ensure (opened.retainedSnapshots == 1 && opened.invalidated)
    "open did not retain exactly one snapshot or establish a fresh lineage"

  let cases : Array (String × String × Bool × Bool) := #[
    ("tail", incrementalSource (tail := "#check gamma\n#check beta"), true, false),
    ("middle", incrementalSource "def beta : Nat := alpha + 3" "#check gamma\n#check beta", true, false),
    ("start", (incrementalSource "def beta : Nat := alpha + 3" "#check gamma\n#check beta").replace
      "def alpha : Nat := 1" "def alpha : Nat := 4", false, false),
    ("comment", (incrementalSource "def beta : Nat := alpha + 3" "#check gamma\n#check beta").replace
      "#check beta" "#check beta -- tail comment", true, false),
    ("declaration", incrementalSource "def beta : Nat := alpha * 5" "#check gamma", true, false),
    ("syntax", (incrementalSource "def beta : Nat := alpha * 5").replace
      "syntax \"twice \" term : term" "syntax \"twice \" term : term\nsyntax \"thrice \" term : term", false, false),
    ("header", (incrementalSource "def beta : Nat := alpha * 5").replace
      "import Lean" "import Lean\nimport Lean.Data.Json", false, true)]
  for (label, source, expectReuse, expectInvalidation) in cases do
    let result ← analyzer.analyze setup source path
    let fresh ← analyzeExact setup source path (loadDynlibs := false)
    ensure (sameEnvelope result.envelope fresh) s!"{label} incremental envelope differs from fresh"
    ensure (result.retainedSnapshots == 1) s!"{label} retained snapshot bound changed"
    ensure (result.invalidated == expectInvalidation) s!"{label} invalidation classification changed"
    if expectReuse then
      ensure (result.reusedCommands > 0) s!"{label} edit reused no command prefix"

  let alternateSetup := { setup with name := `IncrementalFixtureAlternate }
  let setupChanged ← analyzer.analyze alternateSetup (incrementalSource "def beta : Nat := alpha * 5") path
  let setupFresh ← analyzeExact alternateSetup (incrementalSource "def beta : Nat := alpha * 5") path
    (loadDynlibs := false)
  ensure (sameEnvelope setupChanged.envelope setupFresh && setupChanged.invalidated &&
      setupChanged.reusedCommands == 0)
    "module/setup identity crossed the snapshot reuse boundary"

  let lastGood := incrementalSource "def beta : Nat := alpha * 5"
  let restored ← analyzer.analyze setup lastGood path
  ensure restored.envelope.artifact?.isSome "last-good fixture did not elaborate"
  let malformed := lastGood.replace "def gamma : Nat := twice beta" "def gamma : Nat :="
  let failed ← analyzer.analyze setup malformed path
  ensure (failed.envelope.artifact?.isNone && failed.retainedSnapshots == 1)
    "malformed update replaced or discarded the last-good snapshot"
  let repaired ← analyzer.analyze setup lastGood path
  let repairedFresh ← analyzeExact setup lastGood path (loadDynlibs := false)
  ensure (sameEnvelope repaired.envelope repairedFresh && repaired.reusedCommands > 0)
    "repair did not resume from the last-good snapshot"

  let formatted ← analyzer.format setup lastGood path 72
  let formattedFresh ← analyzeExact setup lastGood path (validateFormatDraft := true)
    (formatWidth := 72) (loadDynlibs := false)
  ensure (sameEnvelope formatted.envelope formattedFresh)
    "incremental format differs from fresh validated formatting"

  let mut rss : Array Nat := #[]
  for i in [0:100] do
    let value := if i % 2 == 0 then "6" else "7"
    let source := incrementalSource s!"def beta : Nat := alpha + {value}"
    let result ← analyzer.analyze setup source path
    ensure (result.retainedSnapshots == 1) "hundred-edit run retained snapshot history"
    if i == 24 || i == 49 || i == 74 || i == 99 then
      rss := rss.push (← residentKiB)
  ensure (rss.size == 4 && rss[3]! < 8 * 1024 * 1024)
    "hundred-edit process crossed the 8 GiB memory stop"
  ensure (rss[3]! <= rss[1]! + 256 * 1024)
    "resident memory did not stabilize over the final fifty updates"

  let mut slow := incrementalSource
  for i in [0:4000] do
    slow := slow ++ s!"def cancellation_{i} : Nat := {i}\n"
  let task ← IO.asTask (analyzer.analyze setup slow path)
  let rec waitForFlight (fuel : Nat) : IO Unit := do
    if fuel == 0 then return
    if ← analyzer.isRunning then return
    IO.sleep 1
    waitForFlight (fuel - 1)
  waitForFlight 1000
  analyzer.cancel
  let .ok cancelled := task.get
    | throw <| IO.userError "cancelled analyzer task raised an infrastructure error"
  ensure cancelled.cancelled "in-flight update did not observe cancellation"
  ensure (cancelled.retainedSnapshots == 1) "cancelled update poisoned last-good state"
  let afterCancel ← analyzer.analyze setup lastGood path
  ensure afterCancel.envelope.artifact?.isSome "session did not recover after cancellation"

  let counters ← analyzer.counters
  ensure (counters.updates >= 110 && counters.reusedCommands > 0 &&
      counters.failed == 1 && counters.cancelled == 1 && counters.invalidated >= 2)
    "incremental counters do not account for the exercised lifecycle"
  analyzer.close
  let rejected ← try
      let _ ← analyzer.analyze setup base path
      pure false
    catch error =>
      pure (error.toString.contains "closed")
  ensure rejected "closed analyzer accepted an update or failed for an unrelated reason"
  IO.println s!"incremental updates={counters.updates} reused={counters.reusedCommands} \
invalidated={counters.invalidated} failed={counters.failed} cancelled={counters.cancelled} \
rss_kib={rss} retained=1"
  return 0

/-! ## Report renderer scale (`ruff-15` RRF-FINAL)

`evidence/02-renderer-cost.md` measured the six renderers at 109 findings and the append pattern in
isolation, and recorded what neither covered: `Lean.Json.pretty`, SARIF's serializer, at scale. This
is that measurement. It is synthetic on purpose — the point is to vary report size by three orders of
magnitude while holding everything else fixed, which no real project offers.

The fixture is built and forced *before* the clock starts, and so is the `PositionIndex`: both belong
to `LeanFmt.Application`, and billing them to a renderer would report the wrong thing. -/

section ReportBench
open LeanFmt.Internal.Application LeanFmt.Internal.Cli

private def benchLine : String := "theorem synthetic_placeholder : True := trivial\n"

/-- `count` findings over a synthetic file whose lines are all `benchLine`, so finding `i` sits on
line `i + 1` at a known byte offset. The codes cycle through four live rules, which is what makes the
SARIF descriptor set and its `codes.contains` scan realistic rather than singular. -/
private def benchFile (index : Nat) (count : Nat) : FileReport × String := Id.run do
  let width := benchLine.utf8ByteSize
  let codes := #["FMT001", "FMT002", "FMT008", "FMT011"]
  let mut source := ""
  let mut findings : Array Finding := #[]
  for i in [0:count] do
    source := source ++ benchLine
    findings := findings.push {
      code := codes[i % codes.size]!
      severity := if i % 3 == 0 then .error else .warning
      message := s!"synthetic finding {i} in file {index}"
      range := { start := i * width, stop := i * width + 7 }
      fix? := if i % 2 == 0 then some { applicability := .safe, edits := #[] } else none }
  return ({ path := s!"synthetic/File{index}.lean", status := "findings", findings }, source)

/-- `PositionIndex.ofSource` is a one-file constructor, because the one production caller that needs it
is the single-buffer stdin surface. A multi-file synthetic report needs the union, which `import all`
makes reachable here without widening the production interface for a benchmark. -/
private def mergePositions (index : PositionIndex) (path : String) (source : String)
    (findings : Array Finding) : PositionIndex :=
  ⟨(PositionIndex.ofSource path source findings).entries.fold
    (init := index.entries) fun acc key value => acc.insert key value⟩

private def reportBench : IO UInt32 := do
  for n in [100, 1000, 10000, 100000] do
    -- ~500 findings per file, so the file loop and the per-file work scale with the report too
    -- rather than degenerating to one enormous file.
    let perFile := 500
    let fileCount := max 1 ((n + perFile - 1) / perFile)
    let mut files : Array FileReport := #[]
    let mut positions := PositionIndex.empty
    let mut emitted := 0
    for f in [0:fileCount] do
      let count := min perFile (n - emitted)
      emitted := emitted + count
      let (file, source) := benchFile f count
      files := files.push file
      positions := mergePositions positions file.path source file.findings
    let report : RunReport := {
      mode := "check", files, findings := n, changed := 0, written := 0, broken := 0, rejected := 0,
      withheldUnsafe := 0, suppressed := 0, withheldRedundant := 0, infrastructureFailures := #[] }
    -- Force the fixture and the index before any clock starts.
    if report.files.size + positions.entries.size == 999999999 then
      throw (IO.userError "impossible")
    for format in ([.text, .concise, .json, .github, .sarif, .junit] : List ReportFormat) do
      let start ← IO.monoNanosNow
      let out := formatReport format positions "file:///synthetic/" report
      -- `utf8ByteSize` is O(1) and forces the render.
      if out.utf8ByteSize == 999999999 then throw (IO.userError "impossible")
      let stop ← IO.monoNanosNow
      IO.println s!"report-bench format={format} findings={n} files={fileCount} \
ms={(Float.ofNat (stop - start)) / 1000000.0} out_bytes={out.utf8ByteSize}"
  return 0

end ReportBench

/- `NativeLayout` refuses a `choice` node whose alternatives do not spell the same source, rather than
taking `children[0]?` on faith the way `terminalsFrom` used to. The parser does not build a
disagreeing `choice`, so no fixture reaches that refusal from a file and no suite under `tests/` can
prove it fires. Without this the gate is unreachable code. The `Syntax` is hand-built for exactly that
reason. -/
private def choiceAtom (start stop : Nat) (val : String) : Lean.Syntax :=
  .atom (.original "".toRawSubstring ⟨start⟩ "".toRawSubstring ⟨stop⟩) val

private def testChoiceVerification : IO Unit := do
  let source := "alpha beta"
  let agree := Lean.Syntax.node .none Lean.choiceKind
    #[choiceAtom 0 5 "alpha", choiceAtom 0 5 "alpha"]
  ensure (Formatter.NativeLayout.choiceDisagreement? source agree).isNone
    "a choice node whose alternatives spell the same source was refused"
  let disagree := Lean.Syntax.node .none Lean.choiceKind
    #[choiceAtom 0 5 "alpha", choiceAtom 6 10 "beta"]
  let some (range, alternative, _, _) := Formatter.NativeLayout.choiceDisagreement? source disagree
    | throw (IO.userError "a choice node whose alternatives spell different source was accepted")
  ensure (alternative == 1) s!"expected the disagreement at alternative 1, got {alternative}"
  ensure (range == ⟨0, 10⟩)
    s!"expected the choice node's own range, got {range.start}:{range.stop}"
  -- The outer alternatives agree -- both spell bytes 0..5, because the wrapper's own terminals come
  -- from the inner choice's first alternative. The disagreement is one level down, inside outer
  -- alternative 1, which is precisely where `terminalsFrom` never looks. A gate that descended the
  -- way the walk does would report this file clean.
  let nested := Lean.Syntax.node .none Lean.choiceKind
    #[choiceAtom 0 5 "alpha",
      Lean.Syntax.node .none `wrapper
        #[Lean.Syntax.node .none Lean.choiceKind
            #[choiceAtom 0 5 "alpha", choiceAtom 6 10 "beta"]]]
  ensure (Formatter.NativeLayout.choiceSpelling source nested[0]! ==
      Formatter.NativeLayout.choiceSpelling source nested[1]!)
    "the nested case is vacuous: its outer alternatives already disagree"
  ensure (Formatter.NativeLayout.choiceDisagreement? source nested).isSome
    "a disagreement nested below the first alternative was missed"

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | ["artifact-projection", artifactPath, sourcePath] =>
    let .ok json := Lean.Json.parse (← IO.FS.readFile artifactPath) | return 2
    let .ok (artifact : ModuleArtifact) := Lean.fromJson? json | return 2
    let source ← IO.FS.readFile sourcePath
    let .ok materialized := artifact.materialize source | return 2
    IO.println (Lean.toJson materialized.source).compress
    return 0
  | ["comment-summary", envelopePath] => commentSummaryReport envelopePath
  | ["doc-bench"] => docBench
  | ["doc-step-counts"] => docStepCounts
  | ["validator-map-negative"] => validatorMapNegative
  | ["incremental-analyzer", setupPath, sourcePath] =>
    incrementalAnalyzerSpec setupPath sourcePath
  | ["doc-properties"] => testDoc; return 0
  | ["report-bench"] => reportBench
  | ["doc-dump"] => docDump
  | ["security-bench"] => securityBench
  | ["formatter-header", sourcePath] => formatterHeader sourcePath
  | [] =>
    testDigests
    testRules
    testSourceSecurityRules
    testSourceSecurityProperties
    testImports
    testEngineTiers
    testMixedSelection
    testLspPositions
    testLanguageServerDocuments
    testLanguageServerFrames
    testEdits
    testFixAllAdversarial
    testConfig
    testDiscovery
    testCatalogInvariants
    testApplicability
    testCacheIdentity
    testLakeTraceCharacterization
    testLosslessSource
    testStore
    testSemanticArtifact
    testSemanticRules
    testOwnedDeprecationFix
    testSemanticCaps
    testDoc
    testRangeSelection
    testChoiceVerification
    testSuppression
    IO.println "lean-fmt module-artifact tests passed"
    return 0
  | ["verify-plugin-artifact", moduleName, sourcePath] =>
    verifyPluginArtifact moduleName.toName sourcePath
    IO.println "lean-fmt compiler payload verified"
    return 0
  | ["verify-facet-artifact", path, sourcePath, expectedHash] =>
    let some expectedHash := Lake.Hash.ofString? expectedHash
      | do
      IO.eprintln "EXPECTED_HASH must be a Lake content hash"
      return 2
    verifyFacetArtifact path sourcePath expectedHash
    IO.println "lean-fmt compiler artifact verified"
    return 0
  | ["print-lake-hash", path] =>
    IO.println (← Lake.computeFileHash path (text := true))
    return 0
  | ["verify-official-facet", root, sourcePath] =>
    verifyOfficialFacet root sourcePath
    IO.println "lean-fmt registered compiler facet verified"
    return 0
  | _ =>
    IO.eprintln "usage: lean-fmt-tests [artifact-projection ARTIFACT SOURCE | \
      verify-plugin-artifact MODULE SOURCE | \
      verify-facet-artifact ARTIFACT SOURCE EXPECTED_HASH | \
      verify-official-facet ROOT SOURCE | \
      comment-summary ENVELOPE | \
      doc-bench | \
      doc-step-counts | \
      doc-properties | \
      incremental-analyzer SETUP SOURCE | \
      security-bench | \
      formatter-header SOURCE | \
      print-lake-hash ARTIFACT]"
    return 2
