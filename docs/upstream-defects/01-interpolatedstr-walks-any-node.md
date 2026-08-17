# 1. `interpolatedStr.formatter` walks whatever node it is handed

**Severity: this one silently deletes code.** The other pretty-printer defects throw.

Eight core parsers — `throwError`, `throwErrorAt`, `trace[…]`, `println!`, and four more — spell
their argument as `(interpolatedStr(term) <|> term)`. When the argument comes from the plain `term`
branch, the interpolated-string formatter still walks it as interpolation chunks, running the *term*
formatter at each child in turn. The first child that is an atom or `null` node dies with
`Unknown constant`; an argument that is a bare identifier is silently dropped from the output.

**Upstream:** `interpolatedStr.formatter`, `src/Lean/PrettyPrinter/Formatter.lean:586-591`, reads the
current node's arguments as chunks without knowing which branch produced them — `orelse.formatter`'s
own comment says the traverser is used non-linearly. The eight parser sites:
`src/Lean/Exception.lean:259,267`, `src/Lean/Util/Trace.lean:399`, `src/Init/System/IO.lean:1814`,
`src/Lean/Meta/Sym/SymM.lean:485,499`, `src/Lean/Meta/Tactic/Grind/Types.lean:1091`,
`src/Lean/Meta/Tactic/Grind/EMatch.lean:490`.

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

syntax "pp3 " (interpolatedStr(term) <|> term) : term
syntax "pp4 " (term <|> interpolatedStr(term)) : term

#eval show CoreM Unit from do
  tryFmt "ident"  "example := pp3 foo"          -- OK, and `foo` is GONE
  tryFmt "paren"  "example := pp3 (foo)"        -- THREW: Unknown constant «)»
  tryFmt "string" "example := pp3 \"x\""        -- OK, but the atom's space is lost: pp3"x"
  -- control: branches swapped, nothing breaks
  tryFmt "ctrl"   "example := pp4 (foo bar)"    -- OK, intact
```

On real core parsers:

```lean
#eval show CoreM Unit from do
  tryFmt "a" "def a : MetaM Unit := throwError err"        -- `err` dropped entirely
  tryFmt "b" "def b : MetaM Unit := throwError \"boom\""   -- renders `throwError"boom"`
  tryFmt "c" "def c : MetaM Unit := throwError (id \"x\")" -- THREW: Unknown constant «)»
  tryFmt "d" "def d : MetaM Unit := do trace[x] (id \"x\")" -- THREW: Unknown constant «)»
```

The thrown kind is the first atom or `null` node reached walking the argument's children
right-to-left, which is why one defect has several spellings. The `pp4` row is the control: plain
`orelse` is fine, and `num <|> term` / `ident <|> term` are fine too. The corruption is `p1`'s.

## What it costs lean-fmt

10 of the 421 degradations in the mathlib run: `«)»` ×5, `null` ×3, `«++»` ×1,
`Lean.Parser.Term.hole.antiquot` ×1. Small in count, but this is the family that can lose code
rather than refuse, so it is the one worth filing first. Sites:
`Mathlib/Tactic/{AdaptationNote:28, Bound/Attribute:56, Linarith/Datatypes:242, Monotonicity/Basic:48,
Order:237, ComputeDegree:474, MoveAdd:426, Simps/Basic:757, Says:90, Translate/Core:1106}`.

A dropped argument cannot reach a file: two always-on gates contain it, neither keyed on this
defect. The layout adapter's terminal correspondence is positional, so a terminal the document never
spelled degrades the command to its own source bytes; and `reparseCandidate`
(`LeanFmt/Analysis.lean:907`) compares each command's reparse against the original with `structEq` —
the gate that survives `--no-validate`. No protection was added, and none should be: the key would
have to be "argument of a parser spelled `(interpolatedStr(term) <|> term)`", which is not a
property of the node. The fix belongs upstream.

(A naive grep for `Unknown constant` over the ledger returns 13, not 10 — three are the compiler's
*messages* gate, where the phrase appears in a diagnostic. Filter on `gate == "the layout"`.)

## Pinned by

`tests/fixtures/upstream-defects/Probe.lean` labels `s1-*`; asserted still-reproducing by case `s1`
of `tests/Suites/UpstreamDefects.lean`. `NativeLayoutIslands.droppedTermArgument` in
`tests/fixtures/native-layout/Islands.lean` pins the dropped-argument shape, with deliberately
doubled spacing that survives only because the command is verbatim. A fix upstream deletes nothing —
but that pin goes vacuous, and the containment paragraph above becomes wrong.
