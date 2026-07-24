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
"do not reimplement what Lean does do" case. Repairing D5 means rewriting the native document at the
one position where the grammar's declaration and the rendered shape disagree, which is a mechanism the
adapter does not yet have.

`run.sh` keeps the `do` and `fun` reproductions even though both are correct today. They are the
control: they show the repair must not fire on a body whose soft line already renders flat, and they
are what would catch a fix that forced every `:=` join unconditionally.

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
