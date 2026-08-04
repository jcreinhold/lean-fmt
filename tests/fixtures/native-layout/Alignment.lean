/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Terminal alignment must be total and positional. Every case here has a spelling that repeats, a
spelling Lean's formatter normalizes, or a spelling whose codepoints and bytes disagree; matching a
native leaf by its text instead of by its position gets each of them wrong. -/

/- Baseline note (layout-redesign prompt 01): these renders are pinned for the whole stack. The
prompt-05 oracle must reproduce them byte-for-byte; no rank may move them. -/

public section

namespace NativeLayoutAlignment

/- `value` appears four times in one expression and `+` three times. A by-spelling matcher cannot say
which occurrence a native leaf denotes; a positional one never has to. -/
def repeated (value : Nat) : Nat := value + value + value + value

/- Guillemet names, Greek binders, and arrow/compose operators are multibyte. Their column width and
their byte width differ, so a byte-indexed alignment that assumed one byte per column would drift
from here to the end of the command. -/
def «name with spaces» (α : Type) (compose : α → α) : α → α := compose ∘ compose

/- `0xff` and `0b1010` are the same values as `255` and `10`. The formatter is free to print either
spelling; the source spelling is the one that must survive. -/
def bases : Nat × Nat := (0xff, 0b1010)

/- Two identifiers that differ only in namespace prefix, plus a repeated projection, so a native leaf
spelled `succ` is ambiguous without its position. -/
def projections (pair : Nat × Nat) : Nat := Nat.succ pair.fst + Nat.succ pair.snd

/- A char literal, an escaped string, and a unicode string: three tokens whose native re-printing is
allowed to re-escape, and whose original bytes are the contract. -/
def literals : Char × String × String := ('α', "tab\there", "λ x → x")

/- The separator *between* two aligned terminals is the document's decision, not the source's, and
Lean decides it by re-lexing alone. `pushToken` (`Lean/PrettyPrinter/Formatter.lean:385-407`) inserts
a discretionary separator exactly when `parseToken (tk ++ leadWord)` would run past `tk`. `]` followed
by `do` does not, so the document holds `text"]" text"do"` with nothing between them; `list` followed
by `do` would re-lex as `listdo`, so that one gets a soft `line` -- trailing *inside* the operand's own
group, not at the seam. Both loops are here because the pair is the defect: a repair that adds the
missing separator must not also disturb the one Lean already gets right, and neither loop alone can
tell those apart. See §7. -/
def loops (list : List Nat) : Nat := Id.run do
  let mut total := 0
  for value in list do
    total := total + value
  for value in #[1, 2, 3] do
    total := total + value
  return total

end NativeLayoutAlignment
