module

/-
RSR-SPEC acceptance characterization. Reproduce with:

    lake env lean docs/projects/ruff-08-source-rules/evidence/01-acceptance.lean

Captured output: `01-acceptance.txt`. This pins the frontend acceptance boundary the source-rule
catalog rests on (`notes/01-catalog.md`). It is not tracked production code and imports Lean's
frontend directly; it exists only to be run and read.
-/

import Lean

open Lean Elab

/-- A control/format byte, built from a codepoint so control bytes need no source escapes. -/
def ctl (n : Nat) : String := String.ofList [Char.ofNat n]

/-- `true` iff `input` is rejected at the lexer/parser stage. Elaboration runs against an empty
prelude, so `Unknown constant` is expected noise and excluded: we ask only whether the *bytes* are
accepted, which is what "accepted source" means for the formatter's read contract. -/
def parseRejected (input : String) : IO Bool := do
  let ctx := Parser.mkInputContext input "<t>"
  let (header, state, msgs) ← Parser.parseHeader ctx
  let (env, msgs) ← processHeader header {} msgs ctx
  let s ← IO.processCommands ctx state (Command.mkState env msgs {})
  let errs := s.commandState.messages.toList.filter (·.severity == .error)
  let lexical ← errs.filterM fun m => do
    let t ← m.toString
    return !((t.splitOn "Unknown constant").length > 1)
  return !lexical.isEmpty

def q : String := ctl 0x22    -- double quote
def bom : String := ctl 0xFEFF
def rlo : String := ctl 0x202E
def nul : String := ctl 0x00
def cr : String := ctl 0x0D

/-- Each case: description, and whether the frontend rejects the bytes. -/
def cases : List (String × String) :=
  let clean := "def a := 1\n"
  [ ("clean                 ", clean),
    ("leading BOM           ", bom ++ clean),
    ("BOM before command    ", clean ++ bom ++ "def b := 2\n"),
    ("isolated CR           ", "def a := 1" ++ cr ++ "def b := 2\n"),
    ("bare NUL              ", "def a := 1 " ++ nul ++ " def b := 2\n"),
    ("bare RLO in ident     ", "def a" ++ rlo ++ "b := 1\n"),
    ("NUL in string literal ", "def s := " ++ q ++ "a" ++ nul ++ "b" ++ q ++ "\n"),
    ("NUL in line comment   ", "-- a" ++ nul ++ "b\ndef a := 1\n"),
    ("RLO in string literal ", "def s := " ++ q ++ "a" ++ rlo ++ "b" ++ q ++ "\n"),
    ("RLO in line comment   ", "-- a" ++ rlo ++ "b\ndef a := 1\n"),
    ("LF/CRLF intermixed    ", "def a := 1\ndef b := 2" ++ cr ++ "\n") ]

#eval do
  IO.println "== frontend acceptance (reject = not accepted source) =="
  for (name, input) in cases do
    IO.println s!"{name} reject={← parseRejected input}"
  IO.println ""
  IO.println "== byte facts the source scan rests on =="
  -- `crlfToLf` (the sole normalization) touches only CRLF: it preserves BOM, bidi, NUL, and an
  -- isolated CR, so anything that survives into accepted source survives into normalized source.
  let x := "x"
  let crlfBOM := (bom ++ x).crlfToLf == bom ++ x
  let crlfRLO := (x ++ rlo).crlfToLf == x ++ rlo
  let crlfNUL := (x ++ nul).crlfToLf == x ++ nul
  let crlfLoneCR := ("a" ++ cr ++ "b").crlfToLf == "a" ++ cr ++ "b"
  let crlfCollapse := ("a" ++ cr ++ "\n").crlfToLf == "a\n"
  IO.println s!"crlfToLf preserves BOM     : {crlfBOM}"
  IO.println s!"crlfToLf preserves RLO     : {crlfRLO}"
  IO.println s!"crlfToLf preserves NUL     : {crlfNUL}"
  IO.println s!"crlfToLf preserves lone CR : {crlfLoneCR}"
  IO.println s!"crlfToLf collapses CRLF    : {crlfCollapse}"
  -- These bytes are not trivia to the lexer, so a byte scan — not a trivia walk — is the right tool.
  IO.println s!"BOM isWhitespace           : {Char.isWhitespace (Char.ofNat 0xFEFF)}"
  IO.println s!"RLO isWhitespace           : {Char.isWhitespace (Char.ofNat 0x202E)}"
  IO.println s!"NUL isWhitespace           : {Char.isWhitespace (Char.ofNat 0x00)}"
  -- UTF-8 widths pinned so ranges in the catalog are exact.
  IO.println s!"BOM utf8 bytes             : {bom.toUTF8.toList.map (fun b : UInt8 => b.toNat)}"
  IO.println s!"RLO utf8 bytes             : {rlo.toUTF8.toList.map (fun b : UInt8 => b.toNat)}"
