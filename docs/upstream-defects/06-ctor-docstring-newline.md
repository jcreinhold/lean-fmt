# 6. `ctor` puts the newline after the docstring it should precede

A constructor's docstring renders glued to the `where` (or the previous constructor) above it, with the newline that
should have preceded it following it instead. Layout only — the reparse still owns the docstring correctly — but ugly,
and a correctness hazard under tooling that diffs docstring text.

**Upstream:** `ctor` (`src/Lean/Parser/Command.lean:210-212`) is `atomic (optional docComment >> "\n| ") >> ppGroup …`.
The newline a constructor needs sits *inside* the `"\n| "` atom, which comes *after* `optional docComment` — so the
formatter emits the docstring where the separator belongs, and the separator after it.

## Reproduce

```lean
import Lean
open Lean Parser PrettyPrinter

def tryFmt (label s : String) (width : Nat := 100) : CoreM Unit := do
  match runParserCategory (← getEnv) `command s with
  | .error _ => IO.println s!"{label}: parse error"
  | .ok stx =>
    try IO.println s!"{label}: OK -> {repr ((← formatCommand stx).pretty width)}"
    catch e => IO.println s!"{label}: THREW: {← e.toMessageData.toString}"

#eval show CoreM Unit from do
  tryFmt "first" "inductive Foo where\n  /-- the doc -/\n  | mk : Foo"
  -- renders `inductive Foo where/-- the doc -/`, a blank line, then `  | mk : Foo`
  tryFmt "later" "inductive Bar where\n  | first : Bar\n  /-- second's doc -/\n  | second : Bar"
  -- renders `  | first : Bar/-- second's doc -/`, a blank line, then `  | second : Bar`
  tryFmt "ctrl"  "structure S where\n  /-- the field -/\n  fst : Nat"
  -- unchanged, correct: this is ctor's composition, not doc comments generally
  tryFmt "narrow" "inductive Foo where\n  /-- the doc -/\n  | mk : Foo" 20
  -- the docstring's group also breaks, and the category formatter's dedent lands the
  -- continuation at column zero: `inductive\n  Foo where/--\nthe doc -/\n\n  | mk : Foo`
```

## A claim this file does not support

`LeanFmt/Formatter/AGENTS.md` and `collectCtorDocStarts`'s docstring in `LeanFmt/Formatter/NativeLayout.lean` both said
the rendered form "reparses onto the wrong owner". Measured on 2026-08-13, it does not: five shapes — one constructor,
two constructors with the docstring on the second, two constructors each with one, an `inductive` with no `where`, and a
`structure` — at widths 100, 20 and 8 all reparse with `Syntax.structEq` true against the original tree. The docstring's
*content* changes (it acquires a newline and loses leading indentation) but its owner does not. The two records are
corrected to match. The defect is a layout defect, and would become a correctness one under `--fix`-style tooling that
diffs docstring text — which is why it is still worth filing.

## What it costs lean-fmt

A mechanism: `ctorDocComment?` / `collectCtorDocStarts` plus a matching offside constraint
(`LeanFmt/Formatter/NativeLayout.lean:2222-2266`), which elides the first of the two newlines and cancels the dedent
over the docstring's range. Nothing reaches the ledger.

## Pinned by

`tests/fixtures/upstream-defects/Probe.lean` labels `s6-*`; asserted still-reproducing by case `s6` of
`tests/Suites/UpstreamDefects.lean`. A fix upstream deletes the mechanism above.
