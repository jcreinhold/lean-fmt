/- Position-conversion probe for `ruff-17-lsp` `RLP-PROTOCOL`.

Run from the repository root:

    lake env lean --run docs/projects/ruff-17-lsp/evidence/01-position-probe.lean

It characterizes the toolchain's own LSP position layer (`Lean.Data.Lsp.Utf16`) on the fixtures the
freeze reasons about: an astral-plane character, a byte offset interior to a codepoint, a column
interior to a surrogate pair, an out-of-range position, and a CRLF document against its normalized
twin. Nothing here is a lean-fmt interface; it is the measurement `notes/01-protocol.md` §4 quotes.

Deliberately not a `module` file: `--run` needs `main` reachable, and this is evidence, not
production. -/
import Lean.Data.Lsp

open Lean

/-- `𝔘` (U+1D518) is 4 UTF-8 bytes, 2 UTF-16 code units, 1 codepoint — it separates all three
encodings at once, as `ruff-15`'s reporting fixture does. -/
def astral : String := "theorem t : 𝔘 = 𝔘 := rfl\nsecond line\n"

/-- One astral character at a known offset: `def x := ` is 9 bytes, so `𝔘` occupies bytes 9–12 and
UTF-16 columns 9–10. -/
def small : String := "def x := 𝔘\n"

def crlf : String := "def a := 1\r\ndef b := 2\r\n"

def render (p : Lsp.Position) : String := s!"({p.line},{p.character})"

public def main : IO Unit := do
  let fm := FileMap.ofString astral
  IO.println s!"astral: bytes={astral.utf8ByteSize} utf16={astral.utf16Length} \
    codepoints={astral.length}"
  IO.println "-- utf8PosToLspPos: byte offset -> LSP position"
  for off in [0, 12, 16, 20, 24, 25, 9999] do
    IO.println s!"  utf8 {off} -> lsp {render (fm.utf8PosToLspPos ⟨off⟩)}"
  IO.println "-- lspPosToUtf8Pos: LSP position -> byte offset"
  for lc in [(0, 0), (0, 12), (0, 14), (0, 16), (0, 9999), (99, 0)] do
    IO.println s!"  lsp ({lc.1},{lc.2}) -> utf8 {(fm.lspPosToUtf8Pos ⟨lc.1, lc.2⟩).byteIdx}"

  IO.println "-- columns interior to a surrogate pair (𝔘 at bytes 9-12, columns 9-10)"
  let fs := FileMap.ofString small
  for c in [9, 10, 11, 12] do
    IO.println s!"  lsp (0,{c}) -> utf8 {(fs.lspPosToUtf8Pos ⟨0, c⟩).byteIdx}"

  IO.println "-- CRLF document against its normalized twin"
  let fc := FileMap.ofString crlf
  let fl := FileMap.ofString crlf.crlfToLf
  IO.println s!"  crlf bytes={crlf.utf8ByteSize} normalized bytes={crlf.crlfToLf.utf8ByteSize}"
  for off in [10, 11, 12] do
    IO.println s!"  crlf utf8 {off} -> lsp {render (fc.utf8PosToLspPos ⟨off⟩)}"
  for lc in [(0, 10), (0, 11), (1, 0)] do
    let raw := (fc.lspPosToUtf8Pos ⟨lc.1, lc.2⟩).byteIdx
    let normalized := (fl.lspPosToUtf8Pos ⟨lc.1, lc.2⟩).byteIdx
    IO.println s!"  lsp ({lc.1},{lc.2}) -> crlf utf8 {raw}, normalized utf8 {normalized}"

  IO.println "-- document URI conversion"
  IO.println s!"  file:///tmp/a%20b/X.lean -> \
    {repr ((System.Uri.fileUriToPath? "file:///tmp/a%20b/X.lean").map (·.toString))}"
  IO.println s!"  untitled:Untitled-1     -> \
    {repr ((System.Uri.fileUriToPath? "untitled:Untitled-1").map (·.toString))}"
  let spaced := System.Uri.pathToUri "/tmp/a b/X.lean"
  IO.println s!"  pathToUri /tmp/a b/X.lean -> {spaced}"
