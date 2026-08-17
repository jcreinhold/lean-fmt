# 9. Four toolchain parsers declare a node kind that names no constant

`register_label_attr`, `register_simp_attr`, `register_grind_attr` (and one more of the same shape) are declared with
`macro (name := _root_.A.B) …` inside a namespace. The two ends of each declaration disagree about what `_root_` means,
so every node such a parser produces carries a kind naming no constant, and `formatCommand` dies looking one up.

**Upstream:** the parser *constant* is elaborated as an ordinary declaration name, which honours `_root_`, and is `A.B`.
The node *kind* is `(← getCurrNamespace) ++ declName.getId` (`src/Lean/Elab/Syntax.lean:465`), which does not, and is
`N._root_.A.B`. Declared at `src/Lean/LabelAttribute.lean:84`, `src/Lean/Meta/Tactic/Simp/RegisterCommand.lean:16` and
`src/Lean/Meta/Tactic/Grind/RegisterCommand.lean:12`. A fourth, `src/Lean/Meta/Sym/Simp/RegisterCommand.lean:15`, is the
same shape and was not separately probed.

## Reproduce

```lean
import Lean
open Lean Parser PrettyPrinter

def tryFmt (label s : String) : CoreM Unit := do
  match runParserCategory (← getEnv) `command s with
  | .error _ => IO.println s!"{label}: parse error"
  | .ok stx =>
    try IO.println s!"{label}: OK -> {repr ((← formatCommand stx).pretty 100)}"
    catch e => IO.println s!"{label}: THREW: {← e.toMessageData.toString}"

#eval show CoreM Unit from do
  tryFmt "label" "register_label_attr leanFmtProbeAttr"
  -- THREW: Unknown constant `Lean._root_.Lean.Parser.Command.registerLabelAttr`
  tryFmt "simp"  "register_simp_attr leanFmtProbeSimp"
  -- THREW: Unknown constant `Lean.Meta.Simp._root_.Lean.Parser.Command.registerSimpAttr`
  tryFmt "grind" "register_grind_attr leanFmtProbeGrind"
  -- THREW: Unknown constant `Lean.Meta.Grind._root_.Lean.Parser.Command.registerGrindAttr`
  tryFmt "ctrl"  "example : True := trivial" -- OK
```

The `_root_` in the middle of the reported name is the defect itself.

Note for anyone fixing it: the doubled name is baked into the `ParserDescr` too, so rewriting the node kind to the
suffix does not help — `node.formatter`'s `checkKind` (`src/Lean/PrettyPrinter/Formatter.lean:335-343`) then compares
the descr's doubled name against the rewritten node and `throwBacktrack`s, turning `Unknown constant …` into `uncaught
backtrack exception`. Both ends of the descr agree on the doubled name; only `runForNodeKind`'s `getConstInfo` asks for
the suffix.

## What it costs lean-fmt

Nothing now. `rootedKind?` / `formatCommandForKind` (`LeanFmt/Formatter/NativeLayout.lean:4550-4615`) point the *lookup*
at the suffix and hand the formatter the tree untouched. That recovered 24 of the 457 commands a whole-project run left
verbatim before it. Mathlib declares none of these itself and uses three, in three of its 8,815 files. A rooted kind
*nested* inside a command would still be refused; no such nesting exists in the toolchain today.

## Pinned by

`tests/fixtures/upstream-defects/Probe.lean` labels `s9-*`; asserted still-reproducing by case `s9` of
`tests/Suites/UpstreamDefects.lean`. A fix upstream deletes `rootedKind?` and `formatCommandForKind` in
`LeanFmt/Formatter/NativeLayout.lean`, `tests/fixtures/native-layout/RootedKind.lean` and its assertions in
`tests/Suites/NativeLayout.lean`.
