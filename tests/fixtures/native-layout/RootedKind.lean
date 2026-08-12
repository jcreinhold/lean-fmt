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

This file is not in the `fixtures` array with the others: its last command is the one command here
that no formatter can lay out, so the file's canonical form is not the array's round trip. §6a
asserts the file formats regardless -- that command is emitted as its own bytes and counted as one
verbatim command, and the rest is laid out -- and that the `format-ignore-next` directive reaches
the same outcome deliberately. Three mathlib files use one of the four toolchain declarations
spelled this way.

The kind check in `NativeLayout.command` decides the *diagnosis*, not the outcome: without it the
constant lookup it pre-empts throws `Unknown constant` and the same command degrades, but which end
is asked first decides which name the message carries. A change may reroute this file; it may not
make it refuse. -/

public section

def beforeTheRootedCommand : Nat := 0

register_label_attr leanFmtRootedKindFixture
