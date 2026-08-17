# 8. The category formatter's `nest` accumulates once per link of an operator chain

`categoryParser.formatter` (`src/Lean/PrettyPrinter/Formatter.lean:304-311`) wraps **every** category node in
`nest format.indent |>.fill`, a bare literal included. A chain of one infix operator parses as nested applications of
that operator, once per link, so the wrappers stack and each link's break lands one level further in than the link
outside it. The accumulation is unbounded: rows eventually exceed the width the caller asked for.

## Reproduce

```lean
import Lean
open Lean Parser PrettyPrinter

def chain (operands : Nat) : String :=
  "example := " ++ String.intercalate " ++ " ((List.range operands).map fun i => s!"\"a{i}\"")

def probeWidth (label s : String) (width : Nat := 100) : CoreM Unit := do
  match runParserCategory (← getEnv) `command s with
  | .error _ => IO.println s!"{label}: parse error"
  | .ok stx =>
    let rows := (← formatCommand stx).pretty width |>.splitOn "\n"
    let widest := rows.foldl (fun acc row => max acc row.length) 0
    IO.println s!"{label}: widest={widest} asked={width} — \
      {if widest > width then "OVERRUN" else "within"}"

#eval show CoreM Unit from do
  probeWidth "8 operands"  (chain 8)   -- within
  probeWidth "64 operands" (chain 64)  -- OVERRUN: pretty 100 returns a 114-column row
```

Measured figures at `pretty 100`: 16 operands indent to depth 10, 32 to 42, 64 to 106 with a widest row of 114.
`LAY-CHAIN-COMPENSATION` (`LeanFmt/Formatter/NativeLayout.lean:2331-2346`) records the same growth as
`2 × operands − 6`, reaching column 122 and rows 145 wide, from a run with wider operands — the constants depend on
operand width, the unbounded growth does not. Re-fit before quoting either.

## What it costs lean-fmt

A mechanism, `LAY-CHAIN-COMPENSATION`: one `nest (-format.indent)` on each operand that continues its parent's chain.
Nothing in the document says "these operands are a chain", so `Std.Format` cannot recover the shape — the accumulation
is in what the formatter emits, not in how the engine renders it.

Fixing this upstream means changing what the generic category formatter wraps, which moves the layout of every construct
in the language. That is a change to propose on its own evidence, not a rider on the others here.

## Pinned by

`tests/fixtures/upstream-defects/Probe.lean` labels `s8-*` (the tag is the assertion: `OVERRUN` vs `WITHIN`; the numbers
ride along for the failure message); asserted still-reproducing by case `s8` of `tests/Suites/UpstreamDefects.lean`. A
fix upstream deletes `LAY-CHAIN-COMPENSATION`, `tests/fixtures/native-layout/Chains.lean` and its assertions in
`tests/Suites/NativeLayout.lean`.
