/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Typed exact islands. Each case is a syntax or range class whose payload is source data rather than
layout: a token whose bytes span lines, an interpolated string, and a quotation with an antiquotation.

The multiline cases are the ones that pin the dedent. `Std.Format` re-indents every newline inside a
text leaf to the ambient indentation, so a payload carrying its own absolute columns has to cancel
that indentation to reach column zero. Growing this list by spelling rather than by class is what the
route audit rejected. -/

public section

namespace NativeLayoutIslands

/- A string literal whose bytes span lines, with trailing spaces before the newline and a continuation
line that is indented in the source. Both are payload, not layout. -/
def multiline : String := "alpha
  beta
gamma"

/- The same payload one nesting level deeper, so the ambient indentation the dedent must cancel is
nonzero. -/
def nestedMultiline : Nat → String :=
  fun _ => "first
  second"

/-- A doc comment whose body spans lines.
Its second line owns its own column. -/
def documentedMultiline : Nat := 0

/- Interpolation is parsed source data: its holes are syntax and its chunks are bytes. -/
def interpolated (name : String) : String := s!"hello {name} and {name}"

/- A quotation containing an antiquotation. Formatting the quoted syntax is not the same operation as
formatting the quotation. -/
def quoted (value : Nat) : Lean.Syntax → Lean.MacroM Lean.Syntax := fun _ => `($(Lean.quote value))

end NativeLayoutIslands
