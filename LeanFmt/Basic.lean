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

/-- The formatter release version this binary reports. It matches the Lake package version
and the release tag without its leading `v`. Formatter-only repairs include the `-fmt.N`
suffix. The boundary suite checks the package, README, and reported versions agree. -/
def version : String :=
  "4.36.0"

end LeanFmt
