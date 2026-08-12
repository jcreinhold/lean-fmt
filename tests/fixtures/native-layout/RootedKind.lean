/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Lean.LabelAttribute

/- A command whose syntax node kind names no constant, and how it is laid out anyway.

`Lean/LabelAttribute.lean:84` spells `macro (name := _root_.Lean.Parser.Command.registerLabelAttr)`
inside `namespace Lean`. The two ends of that one declaration disagree about what `_root_` means: the
parser constant is `Lean.Parser.Command.registerLabelAttr`, and the node kind is
`(← getCurrNamespace) ++ declName.getId` (`Lean/Elab/Syntax.lean:465`), which is
`Lean._root_.Lean.Parser.Command.registerLabelAttr`. Every node this parser produces carries a kind
naming no constant, and `formatCommand` used to die looking one up.

It no longer does. The parser descr upstream generated carries the *doubled* name too, so the only
end asking for the suffix is the formatter lookup: point that at the suffix, hand it the tree
untouched, and `checkKind` finds the two doubled names agree. `rootedKind?` in
`LeanFmt/Formatter/NativeLayout.lean` records why rewriting the tree instead does not work. Three
mathlib files use one of the four toolchain declarations spelled this way, for 24 commands.

This file is not in the `fixtures` array with the others, because §6a needs a file whose *other*
command is not already canonical: `beforeTheRootedCommand` is spelled on one line so that "the rooted
command was laid out" can be told apart from "the whole file came through verbatim". §6a asserts the
rooted command is laid out with nothing counted verbatim, that the strict flag changes neither, and
that the `format-ignore-next` directive still reaches a verbatim command deliberately.

A change may reroute this file; it may not make it refuse, and it may not make it spend a
degradation. -/

public section

def beforeTheRootedCommand : Nat := 0

register_label_attr leanFmtRootedKindFixture
