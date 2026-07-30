/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/
module
public import Lean.Data.Json -- this trailing comment makes the line longer than one hundred characters and must not split the import row
public import Lean.Data.Json
public import Lean.PrettyPrinter.Delaborator.FieldNotation -- shake: keep (required by artifact evidence for this module)
public import Lean.PrettyPrinter.Delaborator.FieldNotation -- an ordinary comment
public import Lean.PrettyPrinter.Delaborator.FieldNotation

/-!
# Import rows with trailing comments

Import rows never split: an import cannot be shortened, so a row over the width overflows whole —
mathlib's longLine linter exempts whole import lines for exactly that reason. A trailing comment
of any length, ordinary or pinned (`shake: keep`), rides its row untouched at any width, and
`pinned-comments` cannot move what cannot break.

This fixture once pinned the opposite layout: before the mathlib-style compliance change made
import rows unbreakable, an over-width row split one token per line, the pinned row held flat,
and an ordinary comment followed the split. The never-break contract now lives in the
native-layout suite's mathlib-style case; the comment half lives here.
-/

def importsFixture : Nat := 1
