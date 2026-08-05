/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Lean

/- The two bracketed `sepByIndentSemicolon` families, `tacticSeqBracketed` and `convSeqBracketed`,
and the one layout that used to strand them.

Hugged against `{` on its row, the list's first item sits at the column `sepByIndent`'s inner
`withPosition` saves -- `withoutPosition` does not clear it, because `sepByIndent` re-saves
(`Lean/Parser/Basic.lean:1558`, `Lean/Parser/Extra.lean:202-204`). At a width where the list must
break, Lean's document broke the `;` at the row's own nest column, left of the first item, and the
reparse read the dedented item as the end of the sequence. The validator refused rather than
publish it.

Fixed in the layout-redesign stack, prompt 10 (`LAY-INDENTED-SEQUENCES`): an anchor interval
covers exactly the items of a multi-item bracketed sequence, and every break inside it re-bases to
the first item's column, wherever the hug lands it. At width 100 both theorems format and
validate, as they did at baseline; at width 20 the same two cases now ADMIT -- `{ skip;` breaks to
`rw` at `skip`'s column, `conv => {lhs;` breaks to `rw` at `lhs`'s -- and the suite pins the
anchored rows where it pinned the refusal. The pinned baseline refusal and the parse analysis
above survive in git history (prompt 01's record). -/

public section

namespace NativeLayoutBracketedSequences

/- The tactic spelling: `by { ... }` hugs at width 100, refuses at width 20. -/
theorem tacticBracketedBreak (a : Nat) : a + 0 = a := by { skip; rw [Nat.add_zero a] }

/- The conv spelling: same list, same hug, same refusal. -/
theorem convBracketedBreak (a : Nat) : a + 0 = a := by conv => { lhs; rw [Nat.add_zero] }

end NativeLayoutBracketedSequences
