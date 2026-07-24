# Attribution of the six pinned layout defects

Measured 2026-07-24 against `leanprover/lean4:v4.33.0-rc1`, at `90537d0`.

`tests/native-layout/run.sh` §7 pins six defects as the *adapter's* output. That pin cannot say
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
`tests/native-layout/run.sh` that states the positive claim, and §7 now holds the record rather than a
pin. D4 was last, and the sections below are why: the repair that looks right is width-unsound, and the
one that works needed a second mechanism.

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
(`:372-381`) and `collectRecordUpdateFieldStarts` (`:394-413`) already are. An earlier draft of this
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
