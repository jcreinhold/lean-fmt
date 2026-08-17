# 5. `sepByIndent.formatter` drops the antiquotation splice its own parser adds

`sepByIndent`'s parser wraps its elements in `withAntiquotSpliceAndSuffix` — that is what makes
`$[p];*` parse — but its hand-written formatter rebuilds the sequence by hand and never reproduces
the wrapper. The element formatter meets the splice node directly, falls through to
`formatterForKind`, and dies. A tactic sequence is a `sepBy1Indent`, which is why
`` `(tactic| ($[…];*)) `` is the loud case.

**Upstream:** `withAntiquotSpliceAndSuffix` (`src/Lean/Parser/Basic.lean:1923-1925`) has three bases
in the toolchain — `optional` (`src/Lean/Parser/Extra.lean:41-42`), `many` (`:51-52`, `:66-67`), and
`sepBy` (`:202-207`). In every case the wrapper is *inside the parser the combinator returns*, so
the derived formatter carries `withAntiquot.formatter` and spells the splice. `sepByIndent` and
`sepBy1Indent` then *override* that derived formatter with `sepByIndent.formatter`, which receives
formatters for `sepByIndent`'s own arguments and rebuilds the sequence by hand — the splice the
parser added is not reproduced.

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

syntax "p7tac" (ppSpace ident)? : tactic

#eval show CoreM Unit from do
  -- the defect: sepByIndent's hand-written formatter meets the splice node and dies
  tryFmt "scope"  "macro \"p1\" \"[\" h:term,* \"]\" : tactic => `(tactic| ($[have := $h];*))"
  -- THREW: Unknown constant `sepBy.antiquot_scope`
  tryFmt "suffix" "macro \"p2\" \"[\" h:tactic,* \"]\" : tactic => `(tactic| ($h;*))"
  -- THREW: Unknown constant `sepBy.antiquot_suffix_splice`
  -- controls: the same sepBy base through the DERIVED formatter is fine …
  tryFmt "ctrl1"  "def p3 (xs : Array Lean.Term) : Lean.MacroM Lean.Syntax := `(#[$[$xs],*])" -- OK
  tryFmt "ctrl2"  "def p4 (xs : Array Lean.Term) : Lean.MacroM Lean.Syntax := `(#[$xs,*])"    -- OK
  -- … and the many/optional bases have no hand-written formatter at all
  tryFmt "ctrl3"  "def p6 (xs : Array Lean.Ident) : Lean.MacroM Lean.Syntax := `(fun $[$xs]* => 1)" -- OK
  tryFmt "ctrl4"  "def p7 (x? : Option Lean.Ident) : Lean.MacroM Lean.Syntax := `(tactic| p7tac $[$x?]?)" -- OK
```

The four controls isolate the formatter rather than the splice: same bases, reached through the
derived formatter or no override.

## What it costs lean-fmt

Nothing directly — `lean-fmt` protects `sepBy` splices as exact islands, so the tactic-sequence case
never reaches the ledger. What it cost was the *shape* of that protection. Until 2026-08-13 the
whole splice family was protected, on the reading that no formatter dispatches on any splice kind.
That is true only of `sepBy` under `sepByIndent`, and an unnecessary marker is not free: standing
one in for an `optional.antiquot_scope` throws `uncaught backtrack exception` where the toolchain
would have formatted it. `Mathlib/Tactic/Have.lean`'s three `elab_rules`, each spelling
`` `(tactic| have $n:optBinderIdent $bs* $[: $t:term]?) ``, degraded for exactly that reason, and
now do not. That was the one file in §12's residue whose failure was already known to be ours.

## Pinned by

`tests/fixtures/upstream-defects/Probe.lean` labels `s5-*`; asserted still-reproducing by case `s5`
of `tests/Suites/UpstreamDefects.lean`. A fix upstream lets the `sepBy` clause of the splice-island
protection be deleted too. Until then the base test is the whole discriminator: `sepBy` is
protected because a `sepBy` splice cannot be told apart from `sepByIndent`'s, and a marker there was
measured harmless.
