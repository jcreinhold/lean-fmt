/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Lean

/- The two bracketed `sepByIndentSemicolon` families, `tacticSeqBracketed` and `convSeqBracketed`,
and the one layout they cannot yet survive.

Hugged against `{` on its row, the list's first item sits at the column `sepByIndent`'s inner
`withPosition` saves -- `withoutPosition` does not clear it, because `sepByIndent` re-saves
(`Lean/Parser/Basic.lean:1558`, `Lean/Parser/Extra.lean:202-204`). At a width where the list must
break, Lean's document breaks the `;` at the row's own nest column, left of the first item, and the
reparse reads the dedented item as the end of the sequence. The validator refuses rather than
publish it.

Baseline note (layout-redesign prompt 01): at width 100 both theorems format and validate; at
width 20 both refuse at the `diagnostics` gate. That refusal is the pinned baseline defect this
file exists to characterize, and the reason this file is not in the admission `fixtures` array.
Prompt 10 owns the structural replacement: it must put the break where the first item's column is
preserved (or open the list onto its own rows, as the unbracketed carriers already do) and turn the
width-20 case into admission. Until then the suite pins the refusal, so a rank that changes it must
say so. -/

public section

namespace NativeLayoutBracketedSequences

/- The tactic spelling: `by { ... }` hugs at width 100, refuses at width 20. -/
theorem tacticBracketedBreak (a : Nat) : a + 0 = a := by { skip; rw [Nat.add_zero a] }

/- The conv spelling: same list, same hug, same refusal. -/
theorem convBracketedBreak (a : Nat) : a + 0 = a := by conv => { lhs; rw [Nat.add_zero] }

end NativeLayoutBracketedSequences
