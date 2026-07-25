# Attribution of the pinned layout defects

Measured 2026-07-24 against `leanprover/lean4:v4.33.0-rc1`, at `90537d0`.

`tests/native-layout/run.sh` §7 pins layout defects as the *adapter's* output — six originally, and D7
below after those six were repaired. That pin cannot say
whether a defect is a shape Lean's own registered formatter produces or one the adapter introduces on
top of a correct native document, and the two need different repairs. `Probe.lean` prints the native
document with nothing between `PrettyPrinter.formatCommand` and `Std.Format.pretty`, plus the same
`Std.Format` as a tree so a soft `line` can be told from a `text " "`.

```sh
bash experiments/native-layout-defects/run.sh
```

## Result

| Defect | Origin | Evidence |
| --- | --- | --- |
| D1 interior block comment swallows the following space | adapter | comments are stripped before native formatting, so no native document contains one |
| D2 constructor docstring dedented, blank line after | **upstream** | `text" where" nest-2[text"/--" line text"…-/" text"\n"] text"\n\|" …` |
| D3 dangling `do`-block comment escapes to column zero | adapter | as D1 |
| D4 guarded `let` breaks after the bar | **upstream** | `text" \|" text"\n" fill[text"return" …]` — a hard newline in the document |
| D5 `by` on its own line | **upstream** | `text" :=" line text"by" align(true) fill[…]` at width 100; one body shape, not three |
| D6 blank line after a comment dropped | adapter | as D1 |

So three of the six are Lean's document and three are the adapter's handling of comments, which the
native document never sees. They do not share a repair.

All six are repaired; every assertion moved out of §7 and into the section of
`tests/native-layout/run.sh` that states the positive claim, so those six survive in §7 as the record
rather than a pin. D4 was last, and the sections below are why: the repair that looks right is
width-unsound, and the one that works needed a second mechanism. D7, at the end, is the one still
pinned live.

## D5 is one case, not three, and not the mechanism the prompt names

`23c`'s D5 says `ppAllowUngrouped` is "one mechanism failing" across the three parsers that declare it.
Measured at width 100, two of the three are fine and the third fails only for a specific body:

| body | native first line | verdict |
| --- | --- | --- |
| `:= fun value => value + 1` | `def viaFun : Nat → Nat := fun value => value + 1` | correct |
| `:= do return 1` | `def viaDoDirect : Id Nat := do` | correct |
| `:= by rfl` | `theorem shortBy (n : Nat) : n = n := by rfl` | correct |
| `:= by` + a multi-step `tacticSeq` | `theorem tacticSiblings (n : Nat) : n + 0 = n :=` | **D5** |

`:= Id.run do` also breaks, and that one is *not* D5. `ppAllowUngrouped` sits inside `do`, not at the
head of the body, and the body's head here is the application `Id.run`. `categoryFormatterCore`
(`Formatter.lean:290`) sets `mustBeGrouped := true` on entry to every category, so the nested `do`'s
clearing is overwritten by the enclosing application and `ppHardLineUnlessUngrouped` correctly takes
its hard path — visible as `text" :=" text"\n"` rather than `text" :=" line`. That is the same
`declValSimple` hard line `results/23b` already recorded and handed to 23e as a style question, not a
defect.

So D5 is one body shape: `by` followed by a tactic sequence that renders on more than one line.

The mechanism it blames is not the one that fails. `ppAllowUngrouped` fires.

- `Term.byTactic` (`Term.lean:108`) is `ppAllowUngrouped >> "by " >> Tactic.tacticSeqIndentGt`.
- `categoryParser.formatter` (`Formatter.lean:302-310`) wraps a term in `fmt.nest indent |>.fill`
  **unless** `isUngrouped`. In the measured document `by` appears as a bare `text"by"`, not
  `fill[nest2[text"by" …]]`, so `isUngrouped` was true and the wrapping was skipped.
- `ppHardLineUnlessUngrouped.formatter` (`Extra.lean:304-308`) therefore chose `Formatter.pushLine`, a
  soft `line`, over `ppLine.formatter`'s hard `"\n"`. The document holds `text" :=" line text"by"`.

What decides the break is `Std.Format`'s own `fill` measurement, one layer below. `pushGroup`
(`Init/Data/Format/Basic.lean:243-249`) measures the group *and the enclosing remainder* — `r' :=
merge (w-k) r (spaceUptoLine' gs k)` — and the `fill`/`line` branch (`:294-309`) breaks whenever the
group built from the remaining items does not fit.

The difference between `by rfl` and the multi-step block is visible in the two documents. `by rfl` is
`text"by" line fill[nest2[text"rfl"]]`. The multi-step block is
`text"by" align(true) fill[…have…] text"\n" fill[…exact…]` — it carries an `align(true)` that the
single-tactic form does not. `spaceUptoLine`'s `align force` case (`:165-170`) returns
`space := (m - w).toNat` when `w < m` and `foundLine := true` otherwise, so the alignment contributes
*padding* to the measurement at narrow widths and *stops* it at wide ones. That is what makes the soft
line width-dependent even though the grammar declares it should not be:

| width | first line |
| --- | --- |
| 100 | `theorem tacticSiblings (n : Nat) : n + 0 = n :=` |
| 135 | same |
| 136 | `theorem tacticSiblings (n : Nat) : n + 0 = n := by` |
| 400 | same |

The threshold is 136 for a line that occupies 50 columns through `by` and 90 through the flattened
`have`. Nothing about 136 is a property of the line being laid out.

This matters for where the repair goes. `LeanFmt/Doc.lean:303-305` renders a registered native format
by handing it to `Std.Format.prettyM` at the active width and column, deliberately — "Registered Lean
formatter output remains opaque… A registered leaf is a fit boundary for enclosing custom groups."
lean-fmt does not own this decision and reimplementing `Std.Format`'s renderer to take it back is the
"do not reimplement what Lean does do" case.

It does not need to. The repair is a **flat boundary at the `by` terminal**, and the adapter already
has that mechanism: `transformOrdinaryText` (`NativeLayout.lean:704-711`) routes a whitespace-only text
leaf through `constrainBoundary`, so `flatBoundaries` replaces whatever the renderer emitted at that
position with `" "`. What is missing is only a pure collector of the shape `collectReturnTermStarts`
(`:372-381`) and `collectRecordUpdateFieldStarts` already are. (That second collector was replaced by
`collectIndentedSequenceStarts` when D9 showed the record update was one instance of a `sepByIndent`
rule, not a rule of its own; the line numbers here are as measured and are not maintained.) An earlier
draft of this
file claimed the repair needed a new document-rewriting mechanism — an eighth entry for the list in
`CLAUDE.md`. Reading `transformOrdinaryText` disproves that for D5: the position is already reachable.

D5 shipped this way and is width-safe, which is not a general property of flat boundaries (see D4
below). It holds here because the tactic sequence begins its own line either way, so joining `by` to
`:=` adds exactly three columns and moves no break. `tests/block-formatter/run.sh` renders `by` roots
at widths 20, 40, 80, and 100 and is the standing evidence.

`run.sh` keeps the `do` and `fun` reproductions even though both are correct today. They are the
control: they show the repair must not fire on a body whose soft line already renders flat, and they
are what would catch a fix that forced every `:=` join unconditionally.

## D2 is two upstream faults, and repairing one exposes a third thing

Measured 2026-07-24. `run.sh`'s first two probes print `formatCommand`'s document for
`inductive Choice where / /-- … -/ / | left / | right`:

```
text " where"
nest -2 [ text "/--" line text "…-/" text "\n" ]
text "\n|" line group-fill[nest 2[text "left"]] …
```

Two faults, not one. The `nest -2` dedents the docstring a level below the constructor it documents,
and the `"\n"` closing that nest spells a separator the `"\n| "` atom already carries — so the
rendered docstring is at column zero with a blank line under it, and reparsing hands it to no
constructor at all. Neither is a width effect; both hold at every width.

The repair is two ordinary corrections and no new mechanism: an `elided` boundary at the `|`, which
removes the first of the two newlines, and a constraint of `+format.indent` over the docstring's own
range, which cancels the `nest -2`. `elided` joins `flat` and `hard` as a third spelling of the one
substitution the adapter already had.

### Two things the naive repair got wrong, both caught by measurement

**A `nest` is not interchangeable with an `append` as a constraint carrier.** More than one node in
the document spells exactly the range a constraint names. Making `nest` eligible on the same predicate
as `append` is not additive: the walk is post-order, so the *deeper* node claims the constraint, and
for a guarded `let` that is the `nest` inside the `append`. Cancelling the nest dedents the body
without moving the break above it, which puts the siblings straight back inside the guard —
`tests/native-layout/run.sh` §1 reported `Offside.lean` as `infrastructure-failure` at the diagnostics
gate, `pure PUnit.unit … expected to have type Nat`. So a constraint now names its carrier, and a
carrier that never appears refuses the command rather than picking the other one.

**A constraint's `nest` is invisible to any exact island inside it.** An island's bytes carry absolute
source columns, so the adapter cancels the ambient indentation to reach column zero — computed from
`ambientNest`, the native document's own depth, during the walk. A constraint adds a `nest` the
document never had, at an *ancestor*, which post-order finishes afterwards. A constructor docstring
spanning two lines is exactly this case: the constraint moved its first line and left its
continuations behind. Verified to fail — with `containingConstraintNest` removed,
`tests/native-layout/Boundaries.lean` is not merely misindented but rejected, at the token gate:
`token 75 (Lean.Parser.Command.docComment) changed spelling`. The fix reads the containment out of the
spans, which are known before the walk starts.

Both were latent before D2 rather than introduced by it — the `doLetElse` constraint has the same
island exposure — but D2 is the first constraint whose range *is* an island, so it is what made them
observable.

## D3 is an ownership question, not a layout one

The dangling comment never reaches the adapter. `assignWithNeighbors` (`LeanFmt/Comments.lean:227-247`)
decides a comment's owner from the leaf before it and the leaf after it:

```
def danglingOwner : Nat := Id.run do
  let value := 8
  return value
  -- dangling comment after the last statement

end NativeLayoutBoundaries
```

`left` is `value`, `right` is `end`. `matchingDelimiters "value" "end"` is false; there *is* a newline
between `value` and the comment, so it is not trailing; and `isClosing` (`:102-104`) covers only `)`,
`]`, `}`, and `⟩`, so `end` is not closing either. Every branch falls through to
`syntaxOwner right .leading comment` — the comment is assigned as **leading trivia of `end`**, which is
a command at column zero. That is exactly the observed output, and no part of the adapter is involved.

The block ends by offside, not by a delimiter, so the delimiter-shaped questions above cannot see it.
What distinguishes the two readings is the one fact neither branch consults: the comment starts at
column 2 and `end` starts at column 0. A comment indented deeper than the leaf that follows it is
inside the construct the preceding leaf belongs to, not leading the following one.

Repairing it needs three coordinated changes, which is why it is larger than D1 and D6:

1. `assignWithNeighbors` gains an offside branch, assigning `.dangling` to the innermost site that
   contains `left` and not `right`.
2. `NativeLayout.interiorComments` (`:885-904`) filters on the command's `rootRange`, and a dangling
   comment lies *past* the last token by construction, so it would still be dropped.
3. `transform` (`:864-868`) gates on every collected comment being inserted, and the walk never reaches
   the boundary index `terminals.size`, so a comment admitted by (1) and (2) would turn the command
   into a refusal rather than being emitted.

The validator's comment gate compares ownership across a reparse, and the repair is self-consistent
under it: re-reading the output puts the comment between the same two leaves at the same two columns,
so it lands on the same owner.

## D4 is narrower than `results/23a` left it

Native output reparents the guard's siblings *into* the guard:

```
let some current := value |
      return 0
      let doubled := current + current
      return doubled + 1
```

That is a correctness defect in Lean's document — `let doubled` and `return doubled + 1` are siblings
of the guarded `let` in the source and run unconditionally. The adapter's existing `OffsideConstraint`
already repairs it; its output keeps them at the owning indentation. What survives as D4 is only the
break after the bar. So the offside mechanism is doing its job and D4 is cosmetic, which is what
`tests/native-layout/run.sh` §7 records and what `results/23a` did not yet know.

### A flat boundary at the bar is width-unsound

Measured 2026-07-24 at `929b067`, and reverted. Forcing the bail-out onto the bar's line does not
remove the break — it moves it. `.text " "` is unbreakable, so the renderer re-measures and breaks at
the next soft line, which is now *inside* the bail-out term. That break's indentation comes from the
enclosing `nest`, not from the bar's column, so the continuation lands at a column the `do` block
reads as a sibling element:

```sh
lake setup-file experiments/native-layout-defects/D4Probe.lean > setup.json
"$(lake -q query lean-fmt --text)" __analyze-exact setup.json \
  experiments/native-layout-defects/D4Probe.lean D4Probe.lean 8589934592 4:40
```

`D4Probe.lean` is `tests/block-formatter/Blocks.lean`'s `longLetFallback` alone. At width 47 and above
the whole guard fits and the output is correct. At 45 and below it fails the diagnostics gate:
`return Array.replicate 12 0 |>.size` splits after `12`, `Array.replicate 12` becomes the `return`'s
argument at type `Nat`, and `0 |>.size` becomes a statement of its own — `Nat.size` does not exist.
`tests/block-formatter/run.sh` renders its fixture at 20, 40, 80, and 100, so it caught this while
`tests/native-layout/run.sh`, which renders at 100 only, stayed green.

The width where it breaks is a property of the term, not a bound anyone can pick: any bail-out has a
width at which it must break somewhere. So D4 needs an indentation anchor for the bail-out — a
constraint that puts every break inside it past the guard's own column, which is what the hard newline
plus `nest` was already buying — and a flat boundary alone cannot supply one.

### There is no anchor to supply, so the repair removes the break instead

`Std.Format` has eight constructors — `nil`, `line`, `align`, `text`, `nest`, `append`, `group`, `tag`
— and none of them means "indent this subtree's continuations to the column where it starts". `nest n`
is relative to the current *indent*, and `align force` pads *to* that indent; neither reads the column.
So the anchor the paragraph above asks for cannot be written, whatever the adapter knows. That is a
distinct gap from `notes/06` item 4, which is that a parser-significant column cannot be *marked*; this
one is that it cannot be *expressed* even when it is known, and it is recorded there as item 9.

What is left is to leave no break for the anchor to place. The repair is two mechanisms over one
collected range: a flat `BoundaryLayout` at the bar joins the bail-out onto its line, and
`flattenNative` rewrites the bail-out's own span so it holds no `line` at all. Flattening can fail —
`align (force := true)` and a `text` containing a newline are the two leaves it cannot remove — and
when it does the command is refused with the leaf named, rather than published at a wrong column.

Flattening is total in practice because of the collector's one precondition: only a bail-out the
*source* already spells on one line is collected. `sepByIndent.formatter`
(`Lean/Parser/Extra.lean:212-224`) is the sole producer of both `pushWhitespace "\n"` and
`pushAlign (force := true)`, and emits them only on its `hasNewlineSep` path, which is a property of
the source argument list — so a bail-out with no source newline has neither leaf. The same
precondition bounds the joined line: measured 2026-07-24 over `LeanFmt/`, 102 guarded `let`s already
sit on one line, median 60 columns and widest 99; 10 more spell the bail-out on the next line and keep
their break. `tests/native-layout/Offside.lean`'s `guardedSpanningBailout` is that negative half, and
§6 asserts both directions. `tests/block-formatter/run.sh`, which caught the reverted attempt at width
40, passes.

## D7 is upstream, and the obvious adapter-side repair over-fires

Measured 2026-07-24, after the six above were repaired. `pushToken`
(`Lean/PrettyPrinter/Formatter.lean:366`) decides the separator between two adjacent tokens by
**re-lexing alone**. The formatter runs right-to-left, so `st.leadWord` holds the *next* token, and
lines 385-407 insert a separator only when the concatenation would lex past `tk`:

```lean
let t ← parseToken $ tk' ++ st.leadWord
if t.pos ≤ tk'.rawEndPos then pure false   -- stopped within `tk` => use it as is
else pure true                             -- stopped after `tk` => add space
```

That is the correct rule for a printer whose only obligation is that its output re-lexes to the same
tokens, and the wrong one for a formatter, which also owes the reader a shape. `for value in list do`
and `for value in #[1, 2, 3] do` are the same syntax with a different operand, and the probe separates
them:

| Preceding token | `parseToken (tk ++ "do")` | Document |
| --- | --- | --- |
| `list` | `listdo`, one identifier — runs past `tk` | `fill[nest2[text"list" line]] text"do"` |
| `]` | `]do`, stops at `]` | `fill[nest2[… text"]"]] text"do"` |

So the output reads `for value in #[1, 2, 3]do`. It still parses — `]do` was never one token, which is
precisely why `pushToken` declined — and it validates, so no gate catches it. `tests/native-layout/run.sh`
§7 pins both loops, because a repair must add the missing separator without disturbing the one Lean
already gets right.

Two things the table shows that the rendered output does not. The separator is `pushLine`, a **soft
`line`**, not a `text " "` — so it is a break candidate, and at a narrow width the identifier loop can
break where the bracket loop cannot. And it sits *inside* the preceding operand's group, trailing, not
between the two groups: whatever supplies the missing one has to reach into the operand's span rather
than concatenate at the seam.

### Why "the source separated them, so emit a `line`" is not the repair

The adapter knows both terminals' source ranges, so the tempting rule is to emit a `Format.line`
wherever the source put whitespace between two terminals that the document spells adjacent. Measured
against `def pair (a b : Nat) : Nat × Nat := ⟨ a , b ⟩`:

```
text"⟨" fill[nest2[text"a"]] text"," line fill[nest2[text"b"]] text"⟩"
```

The source separated `⟨` from `a` and `a` from `,`; the document removes both spaces on purpose, and
that removal is the formatter doing its job. The proposed rule restores them — it cannot tell a
separator Lean *declined for shape* from one it *declined for re-lexing*, because `pushToken` records
no such distinction. Nothing else in the document does either. A real repair needs a predicate over the
token pair itself, not over the source, and that has not been written; D7 stays pinned.

## D11 is upstream and unreachable from the adapter; D12 was hiding behind it

Added 2026-07-24, from the stratified mathlib sample rather than from these fixtures. Both were found
in the same four modules and they are independent: each reproduces without the other.

| Defect | Origin | Evidence |
| --- | --- | --- |
| D11 `` `(cat\| body) `` refuses with ``Unknown constant «\|»`` | **upstream** | `parserOfStack.formatter` resolves the `"\| "` atom as a parser name |
| D12 escalated island smaller than the marker it produced | adapter | island `112:120` for a marker standing in for `112:136` |

**D11.** `Lean.Parser.Term.dynamicQuot` (`Lean/Parser/Term.lean:1033`) parses its body with
`parserOfStack 1`, which reads the parser's name off the syntax stack. The two ends disagree about
where that name is:

| | Expression | Reads |
| --- | --- | --- |
| `parserOfStackFn` (`Lean/Parser/Extension.lean:772`) | `stack.get! (stack.size - offset - 1)` | the `ident`; the stack top is the `"\| "` atom |
| `parserOfStack.formatter` (`Lean/PrettyPrinter/Formatter.lean:319`) | `parents.back!.getArg (idxs.back! - offset)` | one slot short of the `ident` |

`idxs.back!` is the index of the argument being visited — arg 3 of
`"`(" >> ident >> "\| " >> incQuotDepth (parserOfStack 1) >> ")"` — so `3 - 1` lands on arg 2, the bar.
`formatterForKind` is then asked about an atom whose kind is `Name.mkSimple "\|"`, and the command dies.
`Lean/PrettyPrinter/Parenthesizer.lean:375` has the same expression.

No adapter repair reaches an upstream index, so the class is protected as an exact island instead.
Keying on `dynamicQuot` is not a shape whitelist: it is the toolchain's **only** call site of
`parserOfStack`, so nothing else can reach the broken formatter, and the body's category is chosen at
parse time, so there is no grammar here whose layout lean-fmt could validate either. `` `(tactic| …) ``
and the other dedicated category quotations are unaffected — they have their own parsers and never
route through `parserOfStack`, which is why the first minimization attempt with `` `(tactic| skip) ``
did not reproduce.

**D12.** Protection escalates from an antiquotation to the smallest node that *strictly* encloses it,
and it measured that node on the **rewritten** subtree. A placeholder is a leaf built from its node's
own `SourceInfo`, and an interior node's is `.none`, so a child that had already escalated contributed
no position and `Syntax.getRange?` stopped at the last leaf the rewrite left intact:

```
Term.app [112:136]                  -- as parsed
  term.pseudo.antiquot [112:116]    -- $(_)      => pending
  null [117:136]
    Term.fun [117:136]
      atom "fun" [117:120]
      Term.basicFun [121:136]       -- escalates first, for $b
```

After `basicFun` becomes a marker leaf, `Term.fun` measures `117:120` and the application `112:120`.
The island is `$(_) fun`; the marker stands for `$(_) fun $x:ident ↦ $b`. The transform then refuses
with `exact island 112:120 cuts terminal 141:146`, naming a terminal well past the island because
every leaf the island *should* have covered was suppressed as interior to it. Escalation has to be able
to run twice, so every range is now read off the node as the source wrote it.

## D13, D14 and D15 are the comment-and-column defects the same three modules carried

Added 2026-07-24, again from the stratified mathlib sample. `Mathlib/Tactic/Linter/ValidatePRTitle.lean`
carried D13, `Mathlib/Util/Superscript.lean` and `Mathlib/Order/Filter/AtTopBot/Tendsto.lean` carried
D14, and D15 was invisible until D14 let those two files render far enough to read.

| Defect | Origin | Evidence |
| --- | --- | --- |
| D13 a command nested in a command lands at `format.indent` | **upstream** | `guardMsgsCmd` spells `" in" ppLine command` with no `ppDedent` |
| D14 an interior doc comment changes which side of the break it is on | adapter | `letRecDecl` spells the comment inside a `nest`; the source decides the side, not the shape |
| D15 a space at the end of every `if c then` line | **upstream** | `doIf` spells `ppSpace` in front of a `doSeq` that begins `text "\n"` |

**D13.** Lean embeds a command in a command in several places and almost always wraps it in
`ppDedent`, which cancels the enclosing node's `nest` exactly: `open Nat in` spells
`nest -2 [text" in" text"\n" <command>]`. `guardMsgsCmd` (`Init/Notation.lean:938`) does not, and
`categoryParser`'s formatter puts the embedded command inside the node's own `nest`, so `#guard_msgs in`
indents the command after it by `format.indent`. On `ValidatePRTitle.lean` — itself a `#guard_msgs` test
— the candidate then trips mathlib's `linter.style.whitespace`, and the added warning changes the
message the test asserts, so the file refuses twice over.

The repair does not name the parsers that forgot. It asks the live parser environment which kinds the
`command` category holds
(`(Lean.Parser.parserExtension.getState env).categories.find? \`command |>.map (·.kinds)`) and spells a
boundary that *sets* column zero rather than adjusting the indent — so where Lean already dedented, as
`open … in` does, the correction reproduces the newline the document had. `rootStart` keeps it a
boundary correction: `open Nat in def f := 0` is one node whose first child is the `open` command
itself, so without the exclusion the rule fires at the command's own first terminal, where the only
thing in front of it is the padding separating it from the previous command. That spelled a blank line
above every such command.

**D14.** `letRecDecl` is `optional docComment >> letDecl`, and Lean spells it

```
text"let" line text"rec" line nest2[text"/--" line text"…-/" text"\n"] line text"helper"
```

so the comment always ends its own line and the name always follows a break. `Superscript.lean` writes
both spellings in one file — `let rec /-- … -/` on line 146 and a docstring on its own line on line
156 — so no fixed choice preserves both, and the choice matters: a comment is the previous token's
trailing trivia exactly when it shares that token's line, so the side of the break decides the owner
on a reparse and the comment gate compares owners.

This is therefore the one boundary rule in `NativeLayout.lean` whose spelling is read off the source
rather than decided by shape. It is read off the source because the question — which side of a break a
comment is on — is the source's to answer. The rule steps aside where a nested command opens with its
own docstring (`open Foo in` / `/-- … -/` / `def …`, an ordinary mathlib shape): both rules land on one
terminal, and D13's is the stronger claim because a parse-relevant column outranks a line-side
preference.

**D15.** `Std.Format.line` renders as a space when its group flattens and as a newline when it does
not. In front of a `text` that carries its own newline it is redundant either way: flattened it is a
space at the end of a line, broken it is a blank line. Lean's `doIf` spells exactly that, and
`Superscript.lean` has five of them:

```
group[ nest2[text"if" line … text" then"], line, text"\n", <doSeq> ]
```

Nothing else notices. The validator reparses the candidate, and a space before a newline changes no
token; a diff of two candidates shows nothing; and a printer has no reason to care, because a trailing
space is invisible in an error message and a re-print is never diffed against source. The gate is
therefore stated over every fixture render at three widths rather than against the construct.

The mirror rule — dropping a break that *follows* a hard newline — looks equally sound and is
deliberately absent. `sepByIndent` spells its first item after an `align force` and every later item
after a `text "\n"`, so the mirror fires on the later items only and leaves the first one a column to
their right. That column is `checkColGe`'s reference, so on `Superscript.lean:312` the second `where`
binding parsed outside the block:

```
where
   valid (s : String) : Bool := …      -- align, break kept
  scripted : SyntaxNodeKind → Bool :=  -- text "\n", break dropped: outside the block
```

A break in front of a newline cannot move a column, because nothing follows it on that line. A break
after one always can.

## D16 is the seam between reading the grammar and owning bytes

Added 2026-07-24, from the same sample, and it is D13's repair meeting the island mechanism.

| Defect | Origin | Evidence |
| --- | --- | --- |
| D16 a boundary collected inside an exact island can never be applied | adapter | `Mathlib/Util/ParseCommand.lean`: `native formatter applied 0/2 boundaries` |

Every boundary rule here reads the grammar, because a grammar shape is what a collector can see. An
exact island renders its own bytes, so `constrainBoundary` spells nothing between the terminals it
covers. Those two facts are individually right and jointly produce an unapplyable boundary: a
`` `(command| …) `` body *is* a command as far as the `command` category is concerned, so D13's rule
collects it, and the quotation is an island, so nothing the adapter asks for there is spelled. Every
collected boundary must be applied — two rules landing on one terminal and disagreeing is a defect the
table reports — so the command refuses instead.

`Mathlib/Util/ParseCommand.lean` has two `command` quotations in one `elab_rules` and reported `0/2`.
It is not a `#guard_msgs` file and had nothing to do with D13's original case; it appeared as a
*regression* between the D12 corpus run and the D15 one, which is the whole reason the frozen sample is
rerun after each repair rather than only the files a repair was aimed at.

The filter is stated once over the finished table rather than inside each collector, so a rule added
later inherits it. Its left edge is strict: the boundary in *front* of an island separates it from the
token before it and is the adapter's to keep, which is the same distinction `insideIsland` draws with
`enteredIslands`.

## D17 is D3 one nesting level in

Added 2026-07-24, from `Mathlib/Tactic/Linter/ValidatePRTitle.lean`, which is the one file in the
sample whose refusal survived D11–D16.

| Defect | Origin | Evidence |
| --- | --- | --- |
| D17 a comment closing an inner block escapes to the next statement | adapter | `dangling` of a `group` becomes `leading` of the `if` two columns to its left |

A comment written on its own line after a block's last statement has to render at a column inside that
block. A *boundary* cannot put it there: a boundary is the gap between two terminals, and the gap after
a block's last token is the same gap as the one before the next statement, so the comment gets that
statement's indent and a reparse hands it over as leading trivia. D3 was this defect where the next
statement is the next *command* — the comment left the declaration for column zero. It is the same
defect wherever the next statement is merely shallower.

`finishTrailing` already existed for D3 and hangs the comment off the owning block's own subtree, where
`Format.text "\n"` re-indents to the indent that block was rendered at. Two things had to change.

**Which comments reach it.** The split between `interiorComments` and `blockDanglingComments` was a
range test — this took what lay past the *command's* end — and that was a proxy for the test
`Comments.blockDangling` already applies: an owner whose own range stops before the comment starts.
The proxy is gone and the two sets are complementary by construction.

**Which column it lands at.** The site is chosen by span, and post-order reaches the *deepest* node
with that span first. Where a block's last item is an `if`/`else` chain, that node sits one `nest`
inside the indent the block's items were laid out at, and the comment came out at column 6 where the
block's items are at 4 — reparsing as dangling on the `else if` branch rather than on the block. The
difference is now cancelled against the nest depth recorded by the boundary in *front* of the block,
which the walk passes long before the claiming node finishes. Measured:

| fixture | ambient nest at the claim | block's item column |
| --- | --- | --- |
| one-level block | 4 | 4 |
| block ending in an `if`/`else` chain | 6 | 4 |

A block can also end in more than one such comment — `ValidatePRTitle.lean` ends one in two — and they
have to leave together, because the next site with the same span is an enclosing node one nest level
out, which is the column the whole mechanism exists to avoid.

## D18 is D9 asking the node that does not know

| defect | owner | what it does |
| --- | --- | --- |
| D18 a delimited tactic sequence takes a break it cannot place | adapter | `constructor <;> (skip; rfl)` renders `rfl` outside the parentheses |

D9's rule breaks a `sepByIndent` list onto its own line when the source spelled the separators, so that
a later separator breaking cannot dedent an item below the first. It fires unconditionally for a
carrier Lean marked `ppAllowUngrouped`, because that carrier's list is laid out by whatever `nest`
encloses the *declaration* and the column `by` happens to sit at is unrelated to it. For a grouped
carrier it asks `delimiterIntervenes` instead: `{ ` alone puts the first field exactly on the indent
the commas break to, `{ base with ` does not.

`ppAllowUngrouped` is `skip` (`Lean/Parser/Extra.lean:268`). It contributes no node, so nothing in the
tree says which carrier declared it, and the rule stood in for it with the sequence's own kind:
`tacticSeq1Indented` and `convSeq1Indented` were read as ungrouped wherever they appeared. They appear
in four places:

| carrier | terminals before the list | grouped |
| --- | --- | --- |
| `by ` | `by` | no — `ppAllowUngrouped` |
| `(` … `)` | `(` | yes |
| `· ` | `·` | yes |
| `case h => ` | `case`, `h`, `=>` | yes |

The three grouped rows took the boundary anyway. Two of them did not need it — the delimiter is the
only thing in front of the list, so the first tactic already sits on the column the separators break to
— and there the forced break had nowhere to land. `nest` is relative to the current indent, so the
break went one level *past* the separators:

```
constructor <;>
  (
      skip;
    rfl)
```

which is `rfl` outside the parentheses; the frontend reported `unexpected identifier; expected ')'`.
`Archive/Arithcc.lean` refused for it, and it was the last diagnostics refusal in the frozen 72-path
sample.

The repair reads the carrier rather than the kind. The walk carries the nearest enclosing node that
spells a token — `Tactic.tacticSeq`, `Conv.convSeq` and `null` are transparent, since none of them owns
a delimiter to count or a `ppAllowUngrouped` to stand for — and the ungrouped branch is taken only when
that node is `Term.byTactic`. Every other carrier falls back to `delimiterIntervenes`, which was
already the right question for a grouped list: `case h => ` still opens its sequence on its own line,
`(` and `·` no longer do.

The parent is not always the immediate one. `Term.byTactic'` (`Term.lean:117`) is `byTactic` with the
`ppAllowUngrouped` marker removed and a kind of its own -- Lean's comment says it exists only so `show`
and `suffices` can be find-replaced safely -- and it is registered in no parser category, so
`categoryParser.formatter` never wraps it and it owns no group. The group belongs to the `show`, which
puts `by` far to the right of the column the separators break to: exactly the case the boundary exists
for. Testing the immediate parent for `Term.byTactic` declined it, and
`Mathlib/NumberTheory/LSeries/HurwitzZetaEven.lean` refused with the original D9 signature --
`(show Function.Periodic … 1 by intro ξ;` joined at column 71, `simp` at column 8. The walk therefore
carries the nearest node that *owns* a group, treating `Term.byTactic'`, `Tactic.tacticSeq`,
`Conv.convSeq` and `null` as transparent. Confirmed against the live parser environment:

| kind | in a category's `kinds` |
| --- | --- |
| `Term.byTactic` | yes |
| `Term.show` | yes |
| `Term.structInst` | yes |
| `Term.byTactic'` | no |
| `Tactic.tacticSeq` | no |
| `Term.whereDecls` | no |

A first attempt filtered the collected starts by the source instead, keeping only lists whose first
item began a line. It repaired all three reproductions and `Archive/Arithcc.lean`, and it broke
`{ base with first := 1, second := 2, … }` at width 40 — an inline record the source did not open on a
line and which D9 exists to correct once a comma has to break. The source says where the list *was*,
not whether the carrier positions it.

## D19 is a separator two layers both spelled

| defect | owner | what it does |
| --- | --- | --- |
| D19 a module docstring gains a blank line below it | upstream | every `/-!` block in ~50 of the 71 accepted sample files |

The adapter renders each command on its own and then spells the separator between commands from the
source's own blank lines. That is the only place the separator can come from, because a command's
document does not know what follows it.

One command's document spells it anyway. `moduleDoc` (`Lean/Parser/Command.lean:60-61`) ends with
`ppLine`, whose formatter is `pushWhitespace "\n"`, so the document ends in a hard newline and the
assembly adds the source's blank line on top of it.

For a printer this is right: a module docstring is followed by a blank line and there is no assembly
layer to own that. For a formatter it is a duplicate. Nothing caught it — a blank line changes no
token, so the structural, comment, diagnostics and idempotence gates all pass, and the candidate is
byte-stable under a second pass because the second pass produces the same extra line. It was found by
counting `\n\n\n` runs across the accepted candidates of the stratified sample: 139 runs against 10 in
the corresponding sources.

The repair drops a hard newline a command's document *ends* with. It is stated over any command rather
than for `moduleDoc`, because what makes it wrong is who owns the separator, and a parser that acquires
the same tail tomorrow is wrong for the same reason. The durable gate is suite-wide: no candidate of any
of the four fixture modules, at any of the three rendered widths, holds two consecutive blank lines.
None of the four sources does either, so the assertion is about the adapter and not about the fixtures.
