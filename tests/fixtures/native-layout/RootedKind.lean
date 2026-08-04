/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Lean.LabelAttribute

/- A command whose syntax node kind names no constant, and the one escape from it.

`Lean/LabelAttribute.lean:84` spells `macro (name := _root_.Lean.Parser.Command.registerLabelAttr)`
inside `namespace Lean`. The two ends of that one declaration disagree about what `_root_` means: the
parser constant is `Lean.Parser.Command.registerLabelAttr`, and the node kind is
`(← getCurrNamespace) ++ declName.getId` (`Lean/Elab/Syntax.lean:465`), which is
`Lean._root_.Lean.Parser.Command.registerLabelAttr`. Every node this parser produces carries a kind
naming no constant, so no formatter can be resolved for it.

This file is not in the `fixtures` array with the others: it is the one fixture here that must
*not* format. §6a asserts the refusal names the declaration rather than whichever lookup failed
first, and that the directive above leaves the command verbatim -- the only way a file holding one
of these can be formatted at all. Three mathlib files use one of the four toolchain declarations
spelled this way. -/

/- Baseline note (layout-redesign prompt 01): the named refusal and the directive escape hold for
the whole stack. Prompt 12 may change how this file is routed, never whether it refuses. -/

public section

def beforeTheRootedCommand : Nat := 0

register_label_attr leanFmtRootedKindFixture
