# 2. `parserOfStack.formatter` reads one slot short — and `conv` is the loud case

Only `term` and `tactic` have dedicated quotation parsers. Every other category's quotation —
`` `(conv| …) ``, `` `(doElem| …) ``, `` `(command| …) `` — goes through `dynamicQuot`, and the
formatter for `parserOfStack` reads the parser stack one slot off, so none of them can be formatted.

**Upstream:** `dynamicQuot` (`src/Lean/Parser/Term.lean:1033-1034`) is
`` "`(" >> ident >> "| " >> incQuotDepth (parserOfStack 1) >> ")" ``. The parser
(`parserOfStackFn`, `src/Lean/Parser/Extension.lean:768`) reads `stack.get! (stack.size - offset - 1)`
where `stack.size` counts elements pushed *before* the one being parsed; the formatter
(`src/Lean/PrettyPrinter/Formatter.lean:331-334`) reads
`parents.back!.getArg (idxs.back! - offset)` where `idxs.back!` is the index *of* the element being
formatted. The two indices differ by one, so the formatter asks for a formatter registered under the
`"| "` atom instead of under the `ident`.

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
  tryFmt "term"    "def a := `(1 + 1)"            -- OK (dedicated parser)
  tryFmt "tactic"  "def b := `(tactic| skip)"     -- OK (dedicated parser)
  tryFmt "conv"    "def c := `(conv| skip)"       -- THREW: format: uncaught backtrack exception
  tryFmt "doElem"  "def d := `(doElem| pure ())"  -- THREW: Unknown constant «|»
  tryFmt "command" "def e := `(command| #eval 1)" -- THREW: Unknown constant «|»
  tryFmt "macro"   "macro \"rc1\" : conv => `(conv| skip)" -- THREW: backtrack
```

**Why `conv` gives the backtrack spelling rather than `Unknown constant` is not established.** The
proximate throw is the same call; something enclosing catches and rethrows it as a backtrack, the
conversion already noted at `LeanFmt/Formatter/NativeLayout.lean:4565`. Do not claim the mechanism
without measuring it.

Worth putting in the issue: `src/Init/Conv.lean` itself is written almost entirely in
`` `(conv| …) `` — lines 224, 227, 230, 234, 241, 251, 260, 267, 273, 280 — so `formatCommand`
cannot format core's own source.

## What it costs lean-fmt

35 of the 239 `uncaught backtrack exception` degradations sit in commands containing a dynamic
quotation for a category with no dedicated parser. `conv` accounts for 19; the rest name
`binderIdent`, `Parser.Tactic.rwRule`, `rcasesPat`, `config`, `Parser.Term.attrInstance`.

`lean-fmt` protects dynamic quotations as exact islands, so it never asks for most of these — which
is why the standalone scanner reports failures at `Mathlib/Tactic/Conv.lean:126` and `:146` that
never appear in our ledger. The ones that *do* degrade are cases the island protection does not
reach.

## Pinned by

`tests/fixtures/upstream-defects/Probe.lean` labels `s2-*`; asserted still-reproducing by case `s2`
of `tests/Suites/UpstreamDefects.lean`. A fix upstream makes the `dynamicQuotationKind` island
protection in `LeanFmt/Formatter/NativeLayout.lean` reviewable rather than obviously dead — the
degradations that reach the ledger are the ones the islands do not cover, so read this file before
deleting anything.
