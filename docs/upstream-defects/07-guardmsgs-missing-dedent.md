# 7. `guardMsgsCmd` omits the `ppDedent` every other command-embedding parser has

The command under `#guard_msgs in` (and `#guard_panic in`, `#guard_info_trees in`) renders indented one level, where
`set_option … in` correctly puts its command at column zero.

**Upstream:** `Init/Notation.lean:953-954` spells

```lean
syntax (name := guardMsgsCmd)
  (plainDocComment)? "#guard_msgs" (ppSpace guardMsgsSpec)? " in" ppLine command : command
```

Compare `src/Lean/Parser/Command.lean:886`, which spells
`withOpen (withSetOption (ppDedent (" in" >> ppLine >> commandParser)))`. `categoryParser.formatter`
(`src/Lean/PrettyPrinter/Formatter.lean:304-311`) wraps every category node in `nest format.indent`, so without the
`ppDedent` the embedded command is indented one level. `guardPanicCmd` (`Init/Notation.lean:960-961`) and `infoTreesCmd`
(`:968-969`) spell it the same way and have the same result.

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
  tryFmt "msgs"  "#guard_msgs in\nexample : True := trivial"          -- example indented
  tryFmt "panic" "#guard_panic in\nexample : True := trivial"         -- example indented
  tryFmt "ctrl"  "set_option pp.all true in\nexample : True := trivial" -- column zero, correct
```

## What it costs lean-fmt

Nothing in the ledger, and one mechanism: the `dedented` boundary keyed on the live `command` category rather than on a
list of parsers that forgot (`LeanFmt/Formatter/NativeLayout.lean:1178-1200`; its citation of `Init/Notation.lean:938`
is stale, the declaration is now at `:953`). A command must start at column zero — mathlib's `linter.style.whitespace`
reports otherwise, and on `Mathlib/Tactic/Linter/ValidatePRTitle.lean` the indented candidate breaks the very
`#guard_msgs` message that file asserts.

## Pinned by

`tests/fixtures/upstream-defects/Probe.lean` labels `s7-*`; asserted still-reproducing by case `s7` of
`tests/Suites/UpstreamDefects.lean`. A fix upstream retires the whole `dedented` boundary — it is keyed on the category,
not on a list of the parsers that forgot, so there is no entry to remove.
