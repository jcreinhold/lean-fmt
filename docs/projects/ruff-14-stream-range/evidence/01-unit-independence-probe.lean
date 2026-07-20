module

import all LeanFmt.Doc

open LeanFmt.Internal

/-- Two "commands" concatenated. `unit1` ends in trailing trivia; `tail` is the next command. -/
def unit1 (trailing : String) : Doc :=
  .group (.text "aaaa" ++ .line " " ++ .text "bbbb") ++ .verbatim trailing

def tailShort : Doc := .text "x"
def tailLong  : Doc := .text "yyyyyyyyyyyyyyyy"

/-- Rendered bytes of unit1 alone, at margin `w`. -/
def solo (w : Nat) (trailing : String) : String :=
  (render w (unit1 trailing)).1

/-- Rendered bytes of unit1 when a tail follows it. -/
def withTail (w : Nat) (trailing : String) (t : Doc) : String :=
  (render w (unit1 trailing ++ t)).1

def report (label : String) (w : Nat) (trailing : String) : IO Unit := do
  let s := solo w trailing
  let a := withTail w trailing tailShort
  let b := withTail w trailing tailLong
  -- Does unit1's own rendering survive having a tail appended?
  
  IO.println s!"{label}: solo={repr s}"
  IO.println s!"  short-tail prefix stable = {a.startsWith s}"
  IO.println s!"  long-tail  prefix stable = {b.startsWith s}"
  IO.println s!"  with short tail = {repr a}"
  IO.println s!"  with long  tail = {repr b}"

public def main : IO Unit := do
  -- Margin 10: "aaaa bbbb" is 9 columns, so unit1 fits flat on its own.
  IO.println "margin 10"
  report "  newline-terminated trivia" 10 "\n"
  report "  same-line trivia (space)  " 10 " "
