/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/-! The product's version, in a module that imports nothing.

It sits alone so anything may read it — the language server reports it to the editor — without
dragging a dependency along. -/

namespace LeanFmt

/-- The version this binary reports. It must equal `lakefile.lean`'s, and the boundary suite's
`package-identity` case fails when it does not: the two drifted to 0.1.0 against 0.1.3, and the
language server told every editor the wrong number until the gate existed. -/
def version : String := "0.1.3"

end LeanFmt
