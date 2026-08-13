# Upstream defects nothing has been filed for

Addressed to whoever files or fixes them, not to a consumer of `lean-fmt`. Each entry below is a
toolchain-only reproduction — no Mathlib, no `lean-fmt` — so each can be pasted into a
`leanprover/lean4` issue as-is.

Measured 2026-08-13 against `lean-toolchain` `leanprover/lean4:v4.34.0-rc1`, with corpus figures from
mathlib4 at `4a9d59a1cc`. Upstream line numbers are from a checkout based on `16fafca7f`; re-read
before quoting them, they move. A measurement here has a date, not authority — regenerate rather than
argue.

The corpus figures come from two whole-project runs on that day, both cold-cache
(`format --check --no-cache --root .`), before and after §3's and §5's repairs:
`verbatim_commands` 421 → 334 and `uncaught backtrack exception` 239 → 149, with `rejected` 1,
`broken` 0 and `infrastructure_failures` 0 in both. Where a section says "of the 421", it is quoting
the first run.

Nine defects, in two groups. §§1–5 are refusals: the formatter throws, and what they cost is counted
in the ledger. §§6–9 are defects `lean-fmt` already compensates for, each at the price of a mechanism
in `LeanFmt/Formatter/NativeLayout.lean` that could be deleted if the defect were fixed upstream —
they are here because a mechanism nobody can name the reason for is a mechanism nobody dares remove.
§10 is the residue neither group explains.

Two open items *are* filed and are deliberately absent from this file:
[#14611](https://github.com/leanprover/lean4/issues/14611) with its PR
[#14696](https://github.com/leanprover/lean4/pull/14696) (doubly-declared notation in binder
position), and [#14692](https://github.com/leanprover/lean4/issues/14692) /
[#14715](https://github.com/leanprover/lean4/issues/14715) with PR
[#14693](https://github.com/leanprover/lean4/pull/14693) (the `align` measure, which is what
`LAY-ALIGN-COMPENSATION` in `LeanFmt/Formatter/NativeLayout.lean` compensates for). Every defect below
was re-run against #14696's branch build and is unchanged by it.

## How to reproduce any of these

```lean
import Lean
open Lean Parser PrettyPrinter

def tryFmt (label s : String) : CoreM Unit := do
  match runParserCategory (← getEnv) `command s with
  | .error _ => IO.println s!"{label}: parse error"
  | .ok stx =>
    try IO.println s!"{label}: OK -> {repr ((← formatCommand stx).pretty 100)}"
    catch e => IO.println s!"{label}: THREW: {← e.toMessageData.toString}"
```

Run it with `lake env lean <file>`, never bare `lean` — bare `lean` reports an incompatible header.

To sweep a real file instead of a string, parse it command by command with `Parser.parseHeader` and
`Parser.parseCommand` and call `formatCommand` on each; that scanner is how the families below were
found. Note that its failures are neither a subset nor a superset of `lean-fmt`'s degradations:
`lean-fmt` builds its own document rather than calling `formatCommand`, so it survives some commands
the scanner refuses (dynamic quotations, which it protects as exact islands) and refuses some the
scanner survives.

---

## 1. `interpolatedStr.formatter` walks whatever node it is handed

**Severity: this one silently deletes code.** The others throw.

`interpolatedStr.formatter` (`src/Lean/PrettyPrinter/Formatter.lean:586-591`) reads the current node's
arguments as interpolation chunks:

```lean
def interpolatedStr.formatter (p : Formatter) : Formatter := do
  visitArgs $ (← getCur).getArgs.reverse.forM fun chunk =>
    match chunk.isLit? interpolatedStrLitKind with
    | some str => push str *> goLeft
    | none     => p
```

Under `(interpolatedStr(term) <|> term)`, `orelse.formatter` runs `p1 <|> p2` and cannot know which
branch produced the node — its own comment says so, and says the traverser is used non-linearly. When
the argument came from the `term` branch, this formatter still walks it as chunks and runs the *term*
formatter at each of its children in turn, including the atoms. The first child that is an atom or a
`null` node reaches `formatterForKind` with a kind that names no declaration.

Eight parsers in core share the shape:

| file | line |
| --- | --- |
| `src/Lean/Exception.lean` | 259 (`throwError`), 267 (`throwErrorAt`) |
| `src/Lean/Util/Trace.lean` | 399 (`trace[…]`) |
| `src/Init/System/IO.lean` | 1814 (`println!`) |
| `src/Lean/Meta/Sym/SymM.lean` | 485, 499 |
| `src/Lean/Meta/Tactic/Grind/Types.lean` | 1091 |
| `src/Lean/Meta/Tactic/Grind/EMatch.lean` | 490 |

### Reproduction

```lean
syntax "pp3 " (interpolatedStr(term) <|> term) : term
syntax "pp4 " (term <|> interpolatedStr(term)) : term
```

| input | result |
| --- | --- |
| `pp3 foo` | **OK, and the argument is gone**: formats to `example :=` |
| `pp3 1` | THREW `Unknown constant «1»` |
| `pp3 (foo)` | THREW `Unknown constant «)»` |
| `pp3 (foo bar)` | THREW `Unknown constant «)»` |
| `pp3 foo + bar` | THREW `Unknown constant «+»` |
| `pp3 ⟨foo⟩` | THREW `Unknown constant «⟩»` |
| `pp3 "x"` | OK |
| `pp4 (foo)`, `pp4 (foo bar)`, `pp4 "x"` | all OK — branches swapped, nothing breaks |

The thrown kind is the first atom or `null` node reached walking the argument's children
right-to-left, which is why the same defect has several spellings. The `pp4` row is the control: plain
`orelse` is fine, and `num <|> term` / `ident <|> term` are fine too. The corruption is `p1`'s.

In real terms:

```
def a : MetaM Unit := throwError err          ->  "def a : MetaM Unit :=\n  throwError"
def b : MetaM Unit := throwError "boom"       ->  "def b : MetaM Unit :=\n  throwError\"boom\""
def c : MetaM Unit := throwError (id "x")     ->  THREW: Unknown constant `«)»`
def d : MetaM Unit := do trace[x] (id "x")    ->  THREW: Unknown constant `«)»`
def e : MetaM Unit := do trace[x] id "x"      ->  THREW: Unknown constant `null`
def f : MetaM Unit := do trace[x] m!"x"       ->  THREW: Unknown constant `interpolatedStrKind`
```

Two further defects visible in those two `OK` rows: `throwError err` **drops `err` entirely**, and
`throwError "boom"` loses the space the `"throwError "` atom spells. The drop is the serious one — it
is the "silently drop a leaf" hazard in `LeanFmt/Formatter/AGENTS.md`, in its smallest possible form.

### What it costs us

10 of the 421 degradations in the mathlib run: `«)»` ×5, `null` ×3, `«++»` ×1,
`Lean.Parser.Term.hole.antiquot` ×1. Small in count, but this is the family that can lose code rather
than refuse, so it is the one worth filing first.

Sites: `Mathlib/Tactic/{AdaptationNote:28, Bound/Attribute:56, Linarith/Datatypes:242,
Monotonicity/Basic:48, Order:237, ComputeDegree:474, MoveAdd:426, Simps/Basic:757, Says:90,
Translate/Core:1106}`.

`Mathlib/Tactic/Says.lean:103` is the `«++»`, and reads well as a motivating example — an ordinary
message continued by a leading `++` on the next line.

### What contains it, and why nothing here works around it

A dropped argument cannot reach a file. Two always-on gates catch it, and neither is a protection
keyed on this defect:

- The layout adapter's terminal correspondence is positional. A terminal the native document never
  spelled makes the plan `.incomplete`, and that command degrades to its own source bytes.
- `reparseCandidate` compares each command's reparse against the original with `structEq`
  (`LeanFmt/Analysis.lean:907`). This is the gate that survives `--no-validate`: a `.structural`
  validation policy skips the second render and `Validator.admit` (`Analysis.lean:1103-1122`), never
  the reparse.

`NativeLayoutIslands.droppedTermArgument` in `tests/fixtures/native-layout/Islands.lean` pins it, with
deliberately doubled spacing that survives only because the command is verbatim.

No protection was added, and none should be. The key would have to be "argument of a parser spelled
`(interpolatedStr(term) <|> term)`", which is not a property of the node — it would come out as a list
of eight parser names, growing by spelling rather than by class. The fix belongs upstream.

### Note on counting

A naive grep for `Unknown constant` over the ledger returns 13, not 10. Three of those
(`Data/UInt:31`, `ClickSuggestions/SectionState:125`, `NormNum/BigOperators:186`) are the
**compiler's messages** gate, where the phrase appears in a diagnostic the candidate reparse produced.
Filter on `gate == "the layout"`.

---

## 2. `parserOfStack.formatter` reads one slot short — and `conv` is the loud case

Already documented in `LeanFmt/Formatter/NativeLayout.lean:431-447`, but only for the ``«|»``
spelling, and the note there understates the reach.

`dynamicQuot` (`src/Lean/Parser/Term.lean:1033-1034`) is

```lean
"`(" >> ident >> "| " >> incQuotDepth (parserOfStack 1) >> ")"
```

`parserOfStackFn` (`src/Lean/Parser/Extension.lean:768`) reads `stack.get! (stack.size - offset - 1)`,
where `stack.size` counts elements pushed *before* the one being parsed. The formatter
(`src/Lean/PrettyPrinter/Formatter.lean:331-334`) reads `parents.back!.getArg (idxs.back! - offset)`,
where `idxs.back!` is the index *of* the element being formatted. The two indices differ by one, so
the formatter asks for a formatter registered under the `"| "` atom instead of under the `ident`.

### Reproduction

| input | result |
| --- | --- |
| `` def a := `(1 + 1) `` | OK (`Term.quot`, not `dynamicQuot`) |
| `` def b := `(tactic\| skip) `` | OK (dedicated parser) |
| `` def c := `(conv\| skip) `` | THREW `format: uncaught backtrack exception` |
| `` def d := `(doElem\| pure ()) `` | THREW ``Unknown constant «\|»`` |
| `` def e := `(command\| #eval 1) `` | THREW ``Unknown constant «\|»`` |
| `` macro "rc1" : conv => `(conv\| skip) `` | THREW `format: uncaught backtrack exception` |

Only `term` and `tactic` have dedicated quotation parsers. Every other category goes through
`dynamicQuot` and cannot be formatted.

**Why `conv` gives the other spelling is not established.** The proximate throw is the same call;
something enclosing catches the `Unknown constant` and rethrows it as a backtrack, which is the
conversion already noted at `NativeLayout.lean:4565`. Do not claim the mechanism without measuring it.

Worth putting in the issue: `src/Init/Conv.lean` itself is written almost entirely in
`` `(conv| …) `` — lines 224, 227, 230, 234, 241, 251, 260, 267, 273, 280 — so `formatCommand` cannot
format core's own source.

### What it costs us

35 of the 239 `uncaught backtrack exception` degradations sit in commands containing a dynamic
quotation for a category with no dedicated parser. `conv` accounts for 19 of them; the rest name
`binderIdent`, `Parser.Tactic.rwRule`, `rcasesPat`, `config`, `Parser.Term.attrInstance`.

`lean-fmt` protects dynamic quotations as exact islands, so it never asks for most of these — which is
why the standalone scanner reports failures at `Mathlib/Tactic/Conv.lean:126` and `:146` that never
appear in our ledger. The ones that *do* degrade are cases the island protection does not reach.

---

## 3. A `%$` positional capture makes any quotation unformattable

Not previously recorded anywhere. The largest single cause after doubly-declared notation, and the
cheapest to reproduce.

### Reproduction

```lean
syntax "cvt" "!"? (" using " num)? : tactic
syntax "cvt2" : tactic
```

| input | result |
| --- | --- |
| ``macro_rules \| `(tactic\| cvt !) => `(tactic\| cvt2)`` | OK |
| ``macro_rules \| `(tactic\| cvt !%$e) => `(tactic\| cvt2)`` | THREW `uncaught backtrack exception` |
| ``macro_rules \| `(tactic\| cvt $[!]?) => `(tactic\| cvt2)`` | OK |
| ``macro_rules \| `(tactic\| cvt $[!%$e]?) => `(tactic\| cvt2)`` | THREW `uncaught backtrack exception` |
| ``macro_rules \| `(tactic\| cvt using%$u 1) => `(tactic\| cvt2)`` | THREW `uncaught backtrack exception` |
| ``def f := `(tactic\| cvt !%$e)`` | THREW `uncaught backtrack exception` |
| ``def g := `(1 +%$p 1)`` | THREW `uncaught backtrack exception` |

The last row is the one to lead with: a bare term quotation, one capture, no macro, no optional
splice, no tactic. The optional splice is irrelevant — it was only how the family first turned up, in
`Mathlib/Tactic/Convert.lean:221` (`$[←%$l]?`) and `:241` (`$[!%$expensive]?`).

### Root cause

`tokenAntiquotFn` (`src/Lean/Parser/Basic.lean:1816-1824`) builds a `token_antiquot` node whose
children are `#[<token>, "%", "$", <antiquotExpr>]`. Its formatter is

```lean
@[combinator_formatter tokenWithAntiquot, expose]
def tokenWithAntiquot.formatter (p : Formatter) : Formatter := do
  if (← getCur).isTokenAntiquot then visitArgs p else p
```

and `visitArgs` (`src/Lean/PrettyPrinter/Formatter.lean:160-166`) descends to the node's *last* child
— the antiquotation expression — then runs `p`, the *token* formatter, there. `symbolNoAntiquot.formatter`
tests `stx.isToken sym`, the expression is not that token, and it throws backtrack.

`tokenWithAntiquot` wraps `symbol`, `nonReservedSymbol` and `unicodeSymbol`, which is why every atom in
the grammar can carry one and why quotations are not the boundary: `example : True := by exact%$t trivial`
refuses on its own.

### What it costs us

40 of the 239 — 26 alone, 7 alongside a dynamic quotation, 7 alongside a doubly-declared
notation. `%$` is idiomatic in Mathlib's tactic
frontends — `with_reducible%$tk`, `says%$tk`, `with%$w`, `using%$u` — so this reaches well past the
files counted here.

### What we do about it

Cost nothing more, since 2026-08-13: `tokenSlotCapture` in `LeanFmt/Formatter/NativeLayout.lean` makes
the smallest enclosing node an exact island, and the command formats around it. Together with §5's
repair the corpus went from 421 degradations to 334, and from 239 backtracks to 149, with `rejected`
and `infrastructure_failures` unmoved — a fall in refusals matched by a rise in either of those would
have been a move, not a fix.

The shape of that protection is forced by the slot, and it is the first place lean-fmt met the
distinction. Every other protection replaces a node standing in a syntax *category* position, which
accepts any leaf — `categoryFormatterCore` falls through to `formatterForKind` on the marker's kind. A
`token_antiquot` stands where an *atom* does, and `symbolNoAntiquot.formatter sym` tests the token's
*spelling*, so no in-place marker of either constructor is admissible. Measured: an identifier marker
at the `token_antiquot` reproduces the original backtrack byte for byte. The protection therefore
escalates rather than standing in place, and it answers at an enclosing splice too — a marker at the
`antiquot_scope` of `$[only%$x]?` lands in the same token slot and throws the same way.

---

## 4. Two forgotten separators in `src/Lean/Parser/Syntax.lean`

These are what `collectForgottenSpaceRuns` in `LeanFmt/Formatter/NativeLayout.lean` repairs. The
collector is ours; upstream is untouched, and both are one-token edits.

### 4a. `optKind` spells `":="` where every sibling spells `" := "`

`src/Lean/Parser/Syntax.lean:101`:

```lean
def optKind : Parser := optional (" (" >> nonReservedSymbol "kind" >> ":=" >> ident >> ")")
```

Compare `namedName` at `:65` and `catBehavior` at `:112`, both `" := "`. So:

```
macro_rules (kind := spcat) | x => x   ->   macro_rules (kind:=spcat)\n  | x => x
declare_syntax_cat foo (behavior := symbol)   ->   unchanged
syntax (name := nm1) "tok1" : spcat           ->   unchanged
```

### 4b. Five nested element lists spell `many1 syntaxParser` without `ppSpace`

`src/Lean/Parser/Syntax.lean:37` (`paren`), `:41` (`unary`), `:43` (`binary`), `:45` (`sepBy`), `:48`
(`sepBy1`) — and `:108` (`syntaxAbbrev`), a sixth site. The outer list in `«syntax»` at `:105` gets it
right: `many1 (ppSpace >> syntaxParser argPrec)`.

```
syntax "t1" ("a" "b") : spcat              ->  syntax "t1" ("a""b") : spcat
syntax "t2" optional("a" "b") : spcat      ->  syntax "t2" optional("a""b") : spcat
syntax "t3" andthen("a" "b", "c" "d") : spcat  ->  syntax "t3" andthen("a""b", "c""d") : spcat
syntax "t4" sepBy("a" "b", ",") : spcat    ->  syntax "t4" sepBy("a""b", ",") : spcat
syntax "t5" sepBy1("a" "b", ",") : spcat   ->  syntax "t5" sepBy1("a""b", ",") : spcat
syntax abbr2 := "a" "b"                    ->  syntax abbr2 := "a""b"
```

`collectForgottenSpaceRuns` asks the *category* rather than naming the parsers, so the sixth site is
already covered without an edit. Do not read a spacing change in a `syntax` command as evidence about
that collector without checking which list it is in.

### What it costs us

Nothing now — the collector took `verbatim_commands` from 433 to 421 over the corpus, all twelve out
of the "the compiler's messages" gate. The dated measurement lives with the collector's docstring.
Filing upstream would let the collector be deleted at some future bump.

---

## 5. `sepByIndent.formatter` drops the antiquotation splice its own parser adds

Found on 2026-08-13 while explaining `Mathlib/Tactic/Have.lean`'s degradations, and the only one of
these five where the *absence* of the defect elsewhere is what matters.

`withAntiquotSpliceAndSuffix` (`src/Lean/Parser/Basic.lean:1923-1925`) is what makes `$[p]suffix` and
`$x,*` parse. It has three bases in the toolchain — `optional` (`src/Lean/Parser/Extra.lean:41-42`),
`many` (`:51-52`, `:66-67`), and `sepBy` (`:202-207`, plus `sepByElemParser` at
`src/Lean/Parser/Basic.lean:1935` and Lake's TOML parser). In every case the wrapper is *inside the
parser the combinator returns*, so the derived formatter carries `withAntiquot.formatter` and spells
the splice.

`sepByIndent` and `sepBy1Indent` then override that derived formatter:

```lean
@[builtin_doc, inline] def sepByIndent (p : Parser) (sep : String) … : Parser :=
  let p := withAntiquotSpliceAndSuffix `sepBy p (symbol "*")
  withPosition $ sepBy (checkColGe "irrelevant" >> p) sep …

@[combinator_formatter sepByIndent, expose]
def sepByIndent.formatter (p : Formatter) (_sep : String) (pSep : Formatter) : Formatter := do
  …
  visitArgs do
    for i in (List.range stx.getArgs.size).reverse do
      if i % 2 == 0 then p else pSep <|> …
```

`sepByIndent.formatter` receives formatters for `sepByIndent`'s own arguments and rebuilds the
sequence by hand, so the `withAntiquotSpliceAndSuffix` the parser added is not reproduced. The element
formatter meets the splice node directly, falls through to `formatterForKind`, and dies. A tactic
sequence is a `sepBy1Indent`, which is why `` `(tactic| ($[…];*)) `` is the loud case.

### Reproduction

`p7` needs one declaration first: `syntax "p7tac" (ppSpace ident)? : tactic`.

| input | result |
| --- | --- |
| ``macro "p1" "[" h:term,* "]" : tactic => `(tactic\| ($[have := $h];*))`` | THREW ``Unknown constant `sepBy.antiquot_scope` `` |
| ``macro "p2" "[" h:tactic,* "]" : tactic => `(tactic\| ($h;*))`` | THREW ``Unknown constant `sepBy.antiquot_suffix_splice` `` |
| ``def p3 (xs : Array Lean.Term) : Lean.MacroM Lean.Syntax := `(#[$[$xs],*])`` | OK |
| ``def p4 (xs : Array Lean.Term) : Lean.MacroM Lean.Syntax := `(#[$xs,*])`` | OK |
| ``def p6 (xs : Array Lean.Ident) : Lean.MacroM Lean.Syntax := `(fun $[$xs]* => 1)`` | OK |
| ``def p7 (x? : Option Lean.Ident) : Lean.MacroM Lean.Syntax := `(tactic\| p7tac $[$x?]?)`` | OK |

`p3` and `p4` are the control that isolates the formatter rather than the splice: the same `sepBy`
base, reached through the derived formatter instead of the hand-written one. `p6` and `p7` are the
`many` and `optional` bases, which have no hand-written formatter at all.

### What it costs us

Nothing directly — lean-fmt protects `sepBy` splices as exact islands, which is why the tactic-sequence
case never appears in the ledger. What it cost was the *shape* of that protection. Until 2026-08-13 the
whole splice family was protected, on the reading that no formatter dispatches on any splice kind. That
is true only of `sepBy` under `sepByIndent`, and an unnecessary marker is not free: standing one in for
an `optional.antiquot_scope` throws `uncaught backtrack exception` where the toolchain would have
formatted it. `Mathlib/Tactic/Have.lean`'s three `elab_rules`, each spelling
`` `(tactic| have $n:optBinderIdent $bs* $[: $t:term]?) ``, degraded for exactly that reason, and now
do not. That was the one file in §10's residue whose failure was already known to be ours.

Filing this would let the `sepBy` clause be deleted too. Until then the base test is the whole
discriminator: `sepBy` is protected because a `sepBy` splice cannot be told apart from `sepByIndent`'s,
and a marker there was measured harmless.

---

## 6. `ctor` puts the newline after the docstring it should precede

`ctor` (`src/Lean/Parser/Command.lean:210-212`) is
`atomic (optional docComment >> "\n| ") >> ppGroup …`. The newline a constructor needs sits *inside*
the `"\n| "` atom, which comes *after* `optional docComment` — so the formatter emits the docstring
where the separator belongs, and the separator after it.

### Reproduction

| input | rendered at width 100 |
| --- | --- |
| `inductive Foo where` / `  /-- the doc -/` / `  \| mk : Foo` | `inductive Foo where/-- the doc -/`, a blank line, then `  \| mk : Foo` |
| `inductive Bar where` / `  \| first : Bar` / `  /-- second's doc -/` / `  \| second : Bar` | `  \| first : Bar/-- second's doc -/`, a blank line, then `  \| second : Bar` |
| `structure S where` / `  /-- the field -/` / `  fst : Nat` | unchanged — correct |

The structure row is the control: this is `ctor`'s composition, not doc comments generally.

At width 20 the docstring's own group also breaks, and because `categoryParser.formatter` dedents it
one level the continuation lands at column zero:

```
inductive
  Foo where/--
the doc -/

  | mk : Foo
```

### A claim this file does not support

`LeanFmt/Formatter/AGENTS.md` and `collectCtorDocStarts`'s docstring in
`LeanFmt/Formatter/NativeLayout.lean` both say the rendered form "reparses onto the wrong owner" /
"no longer sits on its constructor". Measured on 2026-08-13, it does not: five shapes — one
constructor, two constructors with the docstring on the second, two constructors each with one, an
`inductive` with no `where`, and a `structure` — at widths 100, 20 and 8 all reparse with
`Syntax.structEq` true against the original tree. The docstring's *content* changes (it acquires a
newline and loses leading indentation) but its owner does not.

Settled by preferring the measurement: this section states only what was observed, and the two
records above are corrected to match. The defect is a layout defect — a docstring glued to `where`,
a spurious blank line, a continuation at column zero — not a correctness one. It would become a
correctness one under `--fix`-style tooling that diffs docstring text, which is why it is still worth
filing.

### What it costs us

A mechanism: `ctorDocComment?` / `collectCtorDocStarts` plus a matching offside constraint
(`LeanFmt/Formatter/NativeLayout.lean:2222-2266`), which elides the first of the two newlines and
cancels the dedent over the docstring's range. Nothing reaches the ledger.

---

## 7. `guardMsgsCmd` omits the `ppDedent` every other command-embedding parser has

`Init/Notation.lean:953-954`:

```lean
syntax (name := guardMsgsCmd)
  (plainDocComment)? "#guard_msgs" (ppSpace guardMsgsSpec)? " in" ppLine command : command
```

Compare `src/Lean/Parser/Command.lean:886`, which spells
`withOpen (withSetOption (ppDedent (" in" >> ppLine >> commandParser)))`. `categoryParser.formatter`
(`src/Lean/PrettyPrinter/Formatter.lean:304-311`) wraps every category node in `nest format.indent`,
so without the `ppDedent` the embedded command is indented one level.

### Reproduction

| input | rendered |
| --- | --- |
| `#guard_msgs in` / `example : True := trivial` | `#guard_msgs in` / `  example : True :=` / `    trivial` |
| `#guard_panic in` / `example : True := trivial` | same, indented |
| `set_option pp.all true in` / `example : True := trivial` | at column zero — correct |

`guardPanicCmd` (`Init/Notation.lean:960-961`) and `infoTreesCmd` (`:968-969`) spell it the same way
and have the same result; `set_option … in` is the control.

### What it costs us

Nothing in the ledger, and one mechanism: the `dedented` boundary keyed on the live `command`
category rather than on a list of parsers that forgot
(`LeanFmt/Formatter/NativeLayout.lean:1178-1200`; its citation of `Init/Notation.lean:938` is stale,
the declaration is now at `:953`). A command must start at column zero — mathlib's
`linter.style.whitespace` reports otherwise, and on `Mathlib/Tactic/Linter/ValidatePRTitle.lean` the
indented candidate breaks the very `#guard_msgs` message that file asserts.

---

## 8. The category formatter's `nest` accumulates once per link of an operator chain

`categoryParser.formatter` (`src/Lean/PrettyPrinter/Formatter.lean:304-311`) wraps **every** category
node in `nest format.indent |>.fill`, a bare literal included. A chain of one infix operator parses as
nested applications of that operator, once per link, so the wrappers stack and each link's break lands
one level further in than the link outside it. The accumulation is unbounded, and rows eventually
exceed the width the caller asked for.

### Reproduction

`example := "a0" ++ "a1" ++ … ++ "a<n-1>"`, rendered at `pretty 100`:

| operands | deepest indent | widest row |
| --- | --- | --- |
| 4 | 2 | 30 |
| 8 | 2 | 62 |
| 16 | 10 | 99 |
| 32 | 42 | 99 |
| 64 | 106 | 114 |

At 64 operands `pretty 100` returns a 114-column row. `LAY-CHAIN-COMPENSATION`
(`LeanFmt/Formatter/NativeLayout.lean:2331-2346`) records the same growth as `2 × operands − 6`,
reaching column 122 and rows 145 wide, from a run with wider operands — the constants depend on
operand width, the unbounded growth does not. Re-fit before quoting either.

### What it costs us

A mechanism, `LAY-CHAIN-COMPENSATION`: one `nest (-format.indent)` on each operand that continues its
parent's chain. Nothing in the document says "these operands are a chain", so `Std.Format` cannot
recover the shape — the accumulation is in what the formatter emits, not in how the engine renders it.

Fixing this upstream means changing what the generic category formatter wraps, which moves the layout
of every construct in the language. That is a change to propose on its own evidence, not a rider on
the others here.

---

## 9. Four toolchain parsers declare a node kind that names no constant

`macro (name := _root_.A.B) …` written inside `namespace N` leaves the two ends of one declaration
disagreeing about what `_root_` means. The parser *constant* is elaborated as an ordinary declaration
name, which honours `_root_`, and is `A.B`. The node *kind* is `(← getCurrNamespace) ++ declName.getId`
(`src/Lean/Elab/Syntax.lean:465`), which does not, and is `N._root_.A.B`. Every node that parser
produces carries a kind naming no constant, and `formatCommand` dies looking one up.

### Reproduction

| input | result |
| --- | --- |
| `register_label_attr leanFmtProbeAttr` | THREW ``Unknown constant `Lean._root_.Lean.Parser.Command.registerLabelAttr` `` |
| `register_simp_attr leanFmtProbeSimp` | THREW ``Unknown constant `Lean.Meta.Simp._root_.Lean.Parser.Command.registerSimpAttr` `` |
| `register_grind_attr leanFmtProbeGrind` | THREW ``Unknown constant `Lean.Meta.Grind._root_.Lean.Parser.Command.registerGrindAttr` `` |

Declared at `src/Lean/LabelAttribute.lean:84`, `src/Lean/Meta/Tactic/Simp/RegisterCommand.lean:16` and
`src/Lean/Meta/Tactic/Grind/RegisterCommand.lean:12`. A fourth,
`src/Lean/Meta/Sym/Simp/RegisterCommand.lean:15`, is the same shape and was not separately probed.

Note for anyone fixing it: the doubled name is baked into the `ParserDescr` too, so rewriting the node
kind to the suffix does not help — `node.formatter`'s `checkKind`
(`src/Lean/PrettyPrinter/Formatter.lean:335-343`) then compares the descr's doubled name against the
rewritten node and `throwBacktrack`s, turning `Unknown constant …` into `uncaught backtrack
exception`. Both ends of the descr agree on the doubled name; only `runForNodeKind`'s `getConstInfo`
asks for the suffix.

### What it costs us

Nothing now. `rootedKind?` / `formatCommandForKind`
(`LeanFmt/Formatter/NativeLayout.lean:4550-4615`) point the *lookup* at the suffix and hand the
formatter the tree untouched. That recovered 24 of the 457 commands a whole-project run left verbatim
before it. mathlib declares none of these itself and uses three, in three of its 8,815 files. A rooted
kind *nested* inside a command would still be refused; no such nesting exists in the toolchain today.

---

## 10. What is still unexplained

Classifying every `uncaught backtrack exception` degradation by the text around the degraded command,
one classifier run over both corpus runs:

| cause | before | after |
| --- | --- | --- |
| doubly-declared notation (#14611, PR #14696) | 122 | 104 |
| dynamic quotation (§2) | 35 | 26 |
| `%$` positional capture (§3) | 40 | 7 |
| *(commands carrying two causes, subtracted once)* | −29 | −14 |
| **unexplained** | **71** | **26** |
| total | 239 | 149 |

The classifier is a text heuristic over a 12-line window from each degradation's line: a token declared
by more than one `notation`/`infix*`/`prefix`/`postfix` command anywhere in the corpus, a `` `(cat| ``
for a category other than `term`/`tactic`, or a `%$`. It can only undercount the first (the token still
has to land in binder position) and can overcount any of them (the construct has to be in the *failing*
command, not merely nearby). Treat these as orders of magnitude, not tallies.

**The notation row is not comparable to the figure of 88 this file carried earlier on 2026-08-13.** That
count came from a classifier whose notation test could not be reconstructed afterwards; the two rows
that could be reproduced exactly — 40 and 35 in the before column — are the check that the rest of the
classifier is the same one. Rather than mix two classifiers in one table, both columns above are the
looser test, which over-tags notation and so under-reports the residue. The honest reading of the
"unexplained" row is that it is at least 26 and was at least 71.

Files carrying the unexplained residue after the repairs: `Mathlib/Tactic/CategoryTheory/Slice.lean`
(3), `Mathlib/Tactic/{ClickSuggestions/Util, Widget/Conv}.lean` and `MathlibTest/Tactic/GRewrite.lean`
(2 each), then a tail of singletons.

`Mathlib/Tactic/Have.lean` was the useful one to start on, because the standalone scanner formatted all
15 of its commands without complaint while `lean-fmt` degraded 3 — so whatever failed there was on our
side of the boundary. It was: §5. Establishing which side owns a failure is still the first thing to do
for any of the residue, and the scanner is still how to do it.
