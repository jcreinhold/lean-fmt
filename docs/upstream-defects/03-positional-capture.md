# 3. A `%$` positional capture makes any quotation unformattable

Writing `!%$e` — an atom with a positional capture — anywhere in a quotation makes the quotation unformattable: the
atom's formatter descends to the capture expression and then tests whether that *expression* is the *token* it expected.
It is not, and the formatter throws backtrack. Outside a quotation the same failure is absorbed by a surrounding
combinator, which reads it as "this element is not there" and **silently deletes the element**.

**Upstream:** `tokenAntiquotFn` (`src/Lean/Parser/Basic.lean:1816-1824`) builds a `token_antiquot` node whose children
are `#[<token>, "%", "$", <antiquotExpr>]`. Its formatter, `tokenWithAntiquot.formatter`, calls `visitArgs`, which
descends to the node's *last* child — the antiquotation expression — and runs `p`, the *token* formatter, there.
`symbolNoAntiquot.formatter` tests `stx.isToken sym`; the expression is not that token, and it throws backtrack.
`tokenWithAntiquot` wraps `symbol`, `nonReservedSymbol` and `unicodeSymbol`, which is why every atom in the grammar can
carry one.

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

syntax "cvt" "!"? (" using " num)? : tactic
syntax "cvt2" : tactic

#eval show CoreM Unit from do
  -- the one to lead with: a bare term quotation, one capture, nothing else
  tryFmt "term"     "def g := `(1 +%$p 1)"                                -- THREW
  tryFmt "plain"    "macro_rules | `(tactic| cvt !) => `(tactic| cvt2)"   -- OK
  tryFmt "capture"  "macro_rules | `(tactic| cvt !%$e) => `(tactic| cvt2)" -- THREW
  tryFmt "splice"   "macro_rules | `(tactic| cvt $[!%$e]?) => `(tactic| cvt2)" -- THREW
  tryFmt "keyword"  "macro_rules | `(tactic| cvt using%$u 1) => `(tactic| cvt2)" -- THREW
  -- outside every quotation: no throw — the tactic block is DELETED instead
  tryFmt "ctrl"     "example : True := by exact trivial"    -- OK, intact
  tryFmt "bare"     "example : True := by exact%$t trivial" -- OK, and `exact trivial` is GONE
```

The `bare` row was recorded here as refusing on its own; measured 2026-08-14, it does not — it formats, to
`example : True := by`, with the whole tactic block gone. Same mechanism as the throws, with §1's silent-deletion
consequence. This matters for what the fix is worth: the cost below is counted in backtracks, and a silent deletion is
not in that count. How much code the bare-atom shape deletes across a corpus was not measured.

The family first turned up in `Mathlib/Tactic/Convert.lean:221` (`$[←%$l]?`) and `:241` (`$[!%$expensive]?`); the
optional splice is irrelevant.

## What it costs lean-fmt

40 of the 239 backtracks — 26 alone, 7 alongside a dynamic quotation, 7 alongside a doubly-declared notation. `%$` is
idiomatic in Mathlib's tactic frontends — `with_reducible%$tk`, `says%$tk`, `with%$w`, `using%$u` — so this reaches well
past the files counted.

Nothing more, since 2026-08-13: `tokenSlotCapture` in `LeanFmt/Formatter/NativeLayout.lean` makes the smallest enclosing
node an exact island, and the command formats around it. The shape of that protection is forced by the slot: every other
protection replaces a node standing in a syntax *category* position, which accepts any leaf, but a `token_antiquot`
stands where an *atom* does and `symbolNoAntiquot.formatter` tests the token's *spelling*, so no in-place marker is
admissible — measured, an identifier marker at the `token_antiquot` reproduces the original backtrack byte for byte. The
protection therefore escalates to an enclosing node, and answers at an enclosing splice too: a marker at the
`antiquot_scope` of `$[only%$x]?` lands in the same token slot and throws the same way.

## Pinned by

`tests/fixtures/upstream-defects/Probe.lean` labels `s3-*` (the `bare` pair is `s3-control-bare` / `s3-capture-bare`,
which is where the correction above came from); asserted still-reproducing by case `s3` of
`tests/Suites/UpstreamDefects.lean`. A fix upstream deletes `tokenSlotCapture` in `LeanFmt/Formatter/NativeLayout.lean`,
the `tokenCapture` and `tokenCaptureInSplice` declarations in `tests/fixtures/native-layout/Islands.lean`, and their
assertions in `tests/Suites/NativeLayout.lean`.
