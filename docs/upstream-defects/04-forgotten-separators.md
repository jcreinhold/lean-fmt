# 4. Two forgotten separators in `src/Lean/Parser/Syntax.lean`

Two spots in the `syntax`-command grammar forget a space the rest of the grammar remembers, so the pretty-printer glues
tokens together: `(kind := spcat)` renders as `(kind:=spcat)`, and nested element lists like `("a" "b")` render as
`("a""b")`. Both are one-token edits upstream.

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

declare_syntax_cat spcat

#eval show CoreM Unit from do
  -- 4a: optKind spells ":=" where namedName and catBehavior spell " := "
  tryFmt "optkind"   "macro_rules (kind := spcat) | x => x"        -- renders (kind:=spcat)
  tryFmt "behavior"  "declare_syntax_cat foo (behavior := symbol)" -- OK, control
  -- 4b: five nested element lists (plus syntaxAbbrev) spell `many1 syntaxParser` with no ppSpace
  tryFmt "outer"     "syntax \"t6\" \"a\" \"b\" : spcat"           -- OK, control
  tryFmt "paren"     "syntax \"t1\" (\"a\" \"b\") : spcat"         -- renders ("a""b")
  tryFmt "optional"  "syntax \"t2\" optional(\"a\" \"b\") : spcat" -- renders optional("a""b")
  tryFmt "andthen"   "syntax \"t3\" andthen(\"a\" \"b\", \"c\" \"d\") : spcat"
  tryFmt "sepby"     "syntax \"t4\" sepBy(\"a\" \"b\", \",\") : spcat"
  tryFmt "sepby1"    "syntax \"t5\" sepBy1(\"a\" \"b\", \",\") : spcat"
  tryFmt "abbrev"    "syntax abbr2 := \"a\" \"b\""                 -- renders := "a""b"
```

**Upstream, 4a:** `optKind` at `src/Lean/Parser/Syntax.lean:101` spells
`optional (" (" >> nonReservedSymbol "kind" >> ":=" >> ident >> ")")`; compare `namedName` at `:65` and `catBehavior` at
`:112`, both `" := "`.

**Upstream, 4b:** `paren` (`:37`), `unary` (`:41`), `binary` (`:43`), `sepBy` (`:45`), `sepBy1` (`:48`), and
`syntaxAbbrev` (`:108`) all spell `many1 syntaxParser` bare. The outer list in `«syntax»` at `:105` gets it right —
`many1 (ppSpace >> syntaxParser argPrec)` — which is what makes the six a forgotten `ppSpace` rather than a policy.

## What it costs lean-fmt

Nothing now — `collectForgottenSpaceRuns` in `LeanFmt/Formatter/NativeLayout.lean` repairs the spacing, having taken
`verbatim_commands` from 433 to 421 over the corpus, all twelve out of the "the compiler's messages" gate. The dated
measurement lives with the collector's docstring. The collector asks the *category* rather than naming the parsers, so
the sixth site (`syntaxAbbrev`) is covered without an edit; do not read a spacing change in a `syntax` command as
evidence about the collector without checking which list it is in.

## Pinned by

`tests/fixtures/upstream-defects/Probe.lean` labels `s4-*`; asserted still-reproducing by case `s4` of
`tests/Suites/UpstreamDefects.lean`. A fix upstream lets `collectForgottenSpaceRuns` be deleted at some future bump.
