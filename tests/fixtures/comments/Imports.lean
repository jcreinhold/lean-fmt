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

The layout-transparency fixture: a trailing comment's width must never split the import it
trails, an ordinary comment follows its row when the *code* alone overflows, and a pinned
comment (`shake: keep`) holds its row flat even then.
-/

def importsFixture : Nat := 1
