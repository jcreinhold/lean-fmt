# The layout abstraction

This note freezes the layout contract for `RLC-SPEC`. Every claim below is backed by a measurement
recorded in `results/01-design.md` and reproducible with `experiments/layout-core/run.sh` (22 checks,
0 failures). Where a plausible assumption turned out to be wrong, the note says so rather than
quietly stating the corrected version. One of those wrong assumptions was mine and had already been
written up as a finding before the fixture that produced it was found to be broken; §2 records what it
claimed and why it was wrong, because a design note that shows only its surviving conclusions is not
evidence of anything.

Toolchain: `leanprover/lean4:v4.32.0`.

## 1. The question, and why the obvious answer still needed checking

The roadmap asks for "one private, general-purpose document algebra". The obvious answer is a
Wadler/Leijen algebra, because that is what Prettier, Biome, `ruff_formatter`, and — decisively —
Lean core's own `Std.Format` already are. The prompt requires comparing it against a token-stream
constraint model anyway. That comparison turned out to matter, but not where it was expected to: the
two models are not distinguished by their layout decisions at all, and the constructor set is where
the whole decision lives.

Three candidates were built and measured, not cited:

- **A — Wadler/Leijen algebra.** A document tree. `experiments/layout-core/Wadler.lean`.
- **B — token-stream constraint model.** Oppen's 1980 scan/print prettyprinter (TOPLAS 2(4)), the
  model behind rustfmt's `pp.rs`. A stream of `Text`/`Break`/`Begin`/`End`, one pass, buffer bounded
  by the line width rather than the document. `experiments/layout-core/Oppen.lean`.
- **0 — `Std.Format`.** Lean core's Wadler algebra, `Init/Data/Format/Basic.lean`. Already in the
  tree, so writing our own needs a reason that is a measurement.

## 2. What the comparison actually found

### The two models make the same decisions

Both decide a group by comparing a width against the columns left on the line. They were expected to
measure different widths — Wadler's `fits` walks past the group through whatever follows it to the
next break, while Oppen's `Begin` carries the size of the group alone. On a document built to expose
exactly that (`group(f(arg))` followed by ` => tail`, so the group is 6 columns and the line is 14),
they agree at **every one of 10 margins from 30 down to 5**, including at margin 13 and 14 where the
decision flips.

They agree by different mechanisms, which is worth knowing. Oppen reaches the same answer through
`check_stream`: once the buffered material exceeds the line, the oldest undecided group's size is
forced to infinity and it breaks. The tail is accounted for, just not by measuring it. So candidate B
is not the weaker model here, and it is not rejected on this axis.

### Only one of the three can state a mode-dependent separator

A `do` block is flat `do act1; act2` and broken

```
do
  act1
  act2
```

The separator is `"; "` flat and *nothing* broken. `by`/`<;>` tactic blocks have the same shape. This
is text that depends on the mode, and it is the case that decides everything:

| model | margin 40 | margin 12 |
| --- | --- | --- |
| A, with `line (flat : String)` | `do act1; act2` | `do`⏎`  act1`⏎`  act2` |
| B (Oppen) | `do act1; act2` | `do`⏎`  act1;`⏎`  act2` |
| 0 (`Std.Format`) | `do act1; act2` | `do`⏎`  act1;`⏎`  act2` |

Oppen's `Break` inserts *blanks* and nothing else. `Std.Format.line` flattens to `" "` and to nothing
else. Both therefore force the semicolon onto a `Text` token, where it survives into the broken form
and strands there. The gap is not "Wadler versus Oppen" — **`Std.Format` fails the same test as
Oppen**. It is one constructor: whether `line` carries the text it becomes when flat.

That single generalization also collapses three constructors into one. Wadler's `line` is
`line " "`, Leijen's `softline` is `line ""`, and the `do` separator is `line "; "`.

### The textbook rendering algorithm is exponential in a strict language

Wadler's complexity argument is a statement about Haskell. `better` returns one of two *unevaluated*
renderings and `fits` forces only the prefix that fits on the line. Lean is strict, so a
transliteration evaluates both alternatives — including the whole rest of the document behind each —
before it can compare them. Measured on `n` sibling groups at margin 20:

| n | steps | ms | output bytes |
| --- | --- | --- | --- |
| 1 | 8 | 0.004 | 9 |
| 10 | 1,309 | 0.032 | 90 |
| 14 | 8,976 | 0.209 | 126 |
| 18 | 61,503 | 1.391 | 162 |
| 20 | 161,006 | 3.533 | 180 |

The per-group growth factor converges to **1.6180** — φ, the golden ratio, because at this margin
roughly every other group fits and the recurrence is Fibonacci-shaped. 161,006 steps to produce 180
bytes. The same algebra under a bounded work-list renderer costs `18n − 1` steps, exactly linear,
measured to n = 100,000 (1,799,999 steps, 30.3 ms, 900 KB out).

This is not an argument against the algebra. It is an argument that **the renderer is part of the
contract and not an implementation detail**, and Lean core agrees: `Std.Format`'s renderer `be`
(`Init/Data/Format/Basic.lean:252`) is already a bounded work list, and its `pushGroup` (line 244)
already measures a group together with the remainder of the line. Core solved this the same way, for
the same reason. The nesting shape is worth separating out: the textbook renderer is *not*
exponential there (steps track output size at a constant 2.77), because nesting has no sibling
groups to re-decide. Sibling groups are the blowup.

### Oppen's memory advantage is real, and choosing A pays for it

Candidate B's headline is bounded memory: it never materializes a tree, and its buffer is bounded by
the line width rather than by the document. Measured, the claim holds on **both** shapes:

| shape | n | `peak_buffer` |
| --- | --- | --- |
| siblings | 10 … 100,000 | **12** at every n |
| nested | 100 … 10,000 | **32** at every n |

Constant, at 100× the depth, while the document grows by four orders of magnitude. This is a real
advantage and the chosen model does not have it: a document tree is O(n) by construction. The note
records it as a cost accepted, not a claim dismissed.

It is recorded that way only because the fixture was wrong first, and the wrong fixture said the
opposite. The Oppen nested stream originally omitted the closing `)` that its Wadler counterpart
emitted, so it rendered half the bytes and reported `peak_buffer = 2n`. The two models were not being
given the same document, and the "measurement" was an artifact: with no width in the tail,
`check_stream` never saw the buffer exceed the margin, so it never forced a flush and undecided
entries piled up. Once the fixture matched, the growth vanished. `run.sh` now asserts that both nested
renderings are byte-identical (200,050,001 bytes at n = 10,000) before comparing anything about them.

The residue of that mistake is worth keeping as a lead rather than discarding: a token stream whose
tail carries no width *did* defeat Oppen's buffer bound. That is the same zero-width pathology §4.6
records as this contract's known hole, arriving from the other direction.

## 3. Decision

**Candidate A: a Wadler/Leijen-style document tree, with `line` carrying its flat text, rendered by a
bounded work list.** Not `Std.Format`, because `Format` is a closed inductive in core and the one
constructor that decides this cannot be added from outside it.

On the axes the prompt requires:

| axis | A (chosen) | B (Oppen) |
| --- | --- | --- |
| caller knowledge | logical structure; no columns, no order | must emit a *balanced* stream in order |
| invariants hidden | grouping, fit, indent, mode | same, plus a balance obligation it does not hide |
| error surface | none — rendering is total | unbalanced stream is a run-time failure |
| exactness | `line (flat)` states the flat form exactly | flat form is blanks only (measured) |
| cache identity | `Doc` is never serialized; margin is config | same |
| critical path | 100k groups → 30.3 ms | 100k groups → 99.9 ms |
| memory enforceability | O(document) always | **O(width) on both shapes (measured)** |

Two rows go **against** the choice, and are recorded rather than smoothed:

- **Memory.** B's buffer is constant on both shapes measured; A holds the whole tree. B wins this
  outright, and A pays for it. The bill is affordable rather than free: the largest mathlib artifact
  `RLS-FINAL` measured is 660 KB (~16k tokens), so A's O(n) is O(one module), and modules are already
  held in memory whole by every stage upstream of layout. The roadmap's 8 GiB envelope is not
  threatened by a document proportional to a file already in RAM.
- **Steps.** B does less work: 1.0M against 1.8M on 100k sibling groups. A's wall-time win (3.3×) is
  an artifact of B's `HashMap`-backed scan deque in this prototype, not of Oppen's algorithm. B is not
  rejected for being slow, and this row is not evidence for A.

Neither model's rendering time is on the critical path at all: `RLS-FINAL` measured analysis at a
median 1.96 s per mathlib module, against tens of milliseconds to render a document larger than any
real one. The performance rows bound the algebra; they do not choose it.

The decision rests on exactly two things: **the mode-dependent separator** — measured, and fatal for
both rejected candidates including core's own `Format` — and **the balance obligation** a tree makes
unrepresentable. It is a choice of expressiveness and totality over memory, made with the memory cost
measured and stated.

## 4. The contract

### 4.1 Constructors

```lean
inductive Doc where
  | empty
  | text (s : String)
  | line (flat : String)
  | hard
  | verbatim (s : String)
  | cat (a b : Doc)
  | nest (n : Nat) (d : Doc)
  | group (d : Doc)
  | mark (range : SourceRange) (d : Doc)
```

`text` never contains a newline; `hard` is the only way to state one. This is the one place the
contract deliberately departs from `Std.Format`, where a `\n` inside `text` is a hard break
(`Basic.lean:269`) and a group must be re-evaluated after it. Splitting the two makes "this string is
one line" checkable rather than conventional.

`verbatim` was **added during RLC-IMPL**, not designed here; §"Decisions changed during execution" in
`results/02-engine.md` records why. It is the escape hatch that departure forces. A block comment and a
multi-line string literal are single tokens whose text contains newlines and whose interior bytes are
not the formatter's to touch. With `text` newline-free and `hard` re-indenting to the current level,
neither can carry them: emitting such a token as `text` violates the invariant, and splitting it into
`hard`-separated lines rewrites its content — which is exactly what `Std.Format` does at
`Basic.lean:269-276`, and precisely the bug this project exists to avoid. `verbatim s` emits `s`
byte-for-byte, re-indenting nothing. It is the only constructor whose output is not a function of the
current indentation.

There is deliberately **no alternative constructor** — no Wadler `Union`, no Prettier
`conditionalGroup`, no `ruff_formatter` `best_fitting`. The only choice in the algebra is flat versus
broken, decided by one bounded fit test. This is what makes the roadmap's "no unbounded alternative
retention" satisfiable by construction rather than by discipline: there is no alternative to retain.

### 4.2 Group and line semantics

- `group d` renders `d` flat if the flat rendering of `d`, **together with everything that follows it
  up to the next break**, fits in the columns remaining; otherwise it renders `d` in break mode.
  Carrying the remainder is not optional — it is what makes a margin a statement about lines rather
  than about groups — and it is what core does (`pushGroup`).
- `line flat` renders as `text flat` in flat mode, and as a newline plus the current indentation in
  break mode.
- `hard` always renders as a newline plus the current indentation. A group containing a `hard` that
  is not inside a nested group can never be flat; the fit test reports "does not fit" on reaching one.
- `verbatim s` renders `s` unchanged in **both** modes. Unlike `hard` it does not force its group to
  break: a block comment is free to sit inside a flat group, because whether its bytes contain a
  newline is a fact about the token, not a layout decision. It does move the cursor — to the width of
  its last line if it spans one, otherwise forward by its width — so the fit test stays honest about
  where the next token lands.
- Nested groups decide independently. An outer group breaking does not break an inner one.

### 4.3 Indentation

`nest n d` increases indentation by `n` while rendering `d`. It is relative and additive, and only a
break-mode `line` or a `hard` consumes it. There is no align-to-current-column constructor; that is
column arithmetic, which the roadmap puts outside the caller's vocabulary. `Std.Format` has `align`
and Oppen has offsets on both `Begin` and `Break`; neither is adopted without a measured need.

Indentation is **not clamped against the margin**, and the engine does not treat that as an error.
See §4.6.

### 4.4 Source marks

`mark range d` records that `d` was rendered from input `range`. Rendering yields the output string
together with the ordered pairs of input range and output range. This is what range formatting
(`ruff-14-stream-range`) needs and it is the roadmap's "preserves marked source spans" requirement.

`Std.Format` has a `tag : Nat → Format → Format` hook with `startTag`/`endTags` in
`MonadPrettyFormat`, intended for associating `Expr`s in the delaborator. It could be made to index a
side table. It is not adopted, because `Format` is already rejected on §2, and a `Nat` that indexes a
table the caller must also carry is two structures where `mark` is one.

### 4.5 Comment ownership

This is the section the roadmap requires be "derived from the lossless source model", and it is the
one where the expected answer was wrong.

`RLS-SPEC` established that comments are not tree nodes: they live in the `leading` and `trailing`
substrings of `SourceInfo.original`. That leaves one question — which token owns a comment — and
`Lean.Syntax.updateLeading` (`Lean/Syntax.lean:304`) appears to answer it. It splits a token's
trailing at the first newline via `chooseNiceTrailStop`, and its docstring says this is done "so that
e.g. comments are associated to the (intuitively) correct token".

**`updateLeading` has no caller in the 4.32 tree, and the split never happens.** Measured over
`fixtures/Comments.lean`, 56 leaves: `nonempty_leading=0`, `comment_in_leading=0`,
`comment_in_trailing=6`, `trailing_spans_newline=11`. The parser sets `leading` to an *empty*
substring at the token's start (`Parser/Basic.lean:969`) and lets `whitespace` run `trailing` greedily
to the next token. Every comment is in the *preceding* token's trailing run, and one run routinely
holds a trailing comment, a blank line, and the next declaration's leading comments together:

```
token="0" span=392-393
  trailing=" -- trailing comment, same line as the token\n\n-- first of two stacked leading comments\n-- second of two stacked leading comments\n"
```

So the split is ours to perform. The contract adopts `chooseNiceTrailStop`'s rule, which is Lean's own
documented answer even though Lean does not currently run it — splitting a token's trailing run at
the **first newline**:

- **Trailing comment** — in the run before the first newline. Same line as its token.
  `def x := 0  -- why` gives `-- why` to `0`.
- **Leading comment** — from the first newline to the next token. Own line, belongs to the *next*
  token. Blank-line runs land here too, which is where a formatter wants them: they precede the
  declaration they separate.
- **Inline** — a comment with no newline on either side belongs to the preceding token, by the same
  rule. Measured: `def blockInline : Nat := /- inline block -/ 0` gives `/- inline block -/` to `:=`,
  not to `0`. This is the "dangling" case, and the rule already answers it; it needs no category of
  its own.

Two consequences the contract must state rather than discover later:

1. **Comments before the first command are header text and are not attachable.** `headerStop` is the
   first command token's leading start, which — leading being empty — is its own `pos`. Measured on
   the fixture: `header_stop=331`, and the single header leaf carries the module docstring and the
   first declaration's leading comment. A module linter never receives the header. The layout engine
   cannot attach these; they belong to whoever formats the header.
2. **Every comment is attached exactly once, and this is checkable.** `LosslessSource.structurallyValid`
   already requires the trivia runs to tile `[headerStop, terminalStop)` exactly once with no gap and
   no overlap. Attachment is a partition of that tiling, so "preserve every comment exactly once"
   reduces to an invariant the projection already carries, not to a property the printer must be
   trusted for.

A `lineComment` must be emitted with a following `hard`: `--` swallows the rest of its line, so a
comment that a group flattened onto one line would eat the code after it. This is why `hard` is in the
constructor set.

### 4.6 Rendering complexity and failure behavior

`render : Nat → Doc → String × Array Mark` is **total** (`RLC-IMPL` named the pair
`Mark {source, output : SourceRange}`; §4.4 is the contract it carries). There is no `Except`, because
there is no way for layout to fail: no backtracking, no alternatives, no unsatisfiable constraint. The
whole error surface of the layout engine is empty, and that is a deliberate property of the
constructor set (§4.1), not a claim about the implementation. `verbatim` does not weaken this: it
emits its bytes and cannot fail either.

What the engine does *not* promise:

- **The margin is not a guarantee.** The renderer never breaks a `text` and never invents a break
  opportunity. A document whose atoms exceed the margin produces lines over the margin. Measured: at
  margins 8, 6, and 5 the fit document renders a 9-column line, because `) => tail` has no break in
  it. Both models do this; it is inherent, not a defect. The roadmap's "bounded width where feasible"
  is exactly this caveat.
- **Indentation is not clamped.** `nest` depth `d` with unit `u` produces indents of `d·u` whatever
  the margin is. Measured at depth 10,000 and unit 2 against margin 20: 200 MB of output, nearly all
  spaces. Real formatters clamp; whether and how to is a language decision (§5), not a layout one.

What it does promise, measured:

| shape | renderer | steps | to n |
| --- | --- | --- | --- |
| sibling groups | bounded work list | `18n − 1` | 100,000 |
| nested groups | bounded work list | `10n + 485` (n ≥ 100) | 10,000 |
| sibling groups | Oppen | `10n` | 100,000 |
| nested groups | Oppen | `11n + 11` | 10,000 |

Linear in document size on both shapes the roadmap names, at sizes far past any real module (the
largest mathlib artifact `RLS-FINAL` measured is 660 KB, ~16k tokens).

**The bound, stated exactly** (`RLC-FINAL`; this paragraph replaces a weaker one that was wrong).
A fit test walks *to the next break in the tail*, not to the end of the document — so `render` is
O(n·k), where k is the largest number of nodes between consecutive break opportunities. Every printer
that offers a break at each line boundary has k bounded by its widest single construct, and is
therefore linear. This is the whole precondition, and it is one a printer meets by existing: a module
is not one line.

Two things follow, and the second is the hole:

- **Nesting is linear.** A group inside a group already rendered flat is *not* re-tested: the outer
  fit test reached its answer by assuming the inner group renders flat, so re-deciding could only
  re-derive that answer — or contradict the test that authorized it. Measured: 7.6× across an 8× size
  step on `zero-width-nesting`, which is the roadmap's "adversarial nesting" verbatim. **This was not
  true when this note was written.** The renderer re-tested every nested group, making the shape
  quadratic (72×), and `RLC-FINAL` found it by measuring the claim instead of restating it. Fixing it
  left all 16,400 generated renders byte-identical: it removed work, not decisions.
- **The known hole is a document with no break at all.** `n` sibling groups that spend no column and
  offer no break force each fit test to walk the entire tail, giving Θ(n²) — measured, 66× across an
  8× step, and unchanged by the fix above. It is not a defect in the implementation but a property of
  Wadler fit testing: **Lean core's own `Std.Format` is quadratic on the identical shape** (4.0× per
  doubling, measured). Only a running total over the tail closes it, which is Oppen's `rightotal` —
  the model §3 rejected on expressiveness. So the cost is accepted knowingly a second time, on the
  same terms. It is unreachable from a printer that emits a token per node, because every token spends
  a column; that is a precondition on printers, recorded here rather than assumed.
  `tests/layout/bench.sh` pins all of it.

### 4.7 Width policy

**A column is one Unicode codepoint.** This is not invented: `Std.Format` counts
`String.Internal.length` in both `spaceUptoLine` and `pushOutput` (`Basic.lean:401`), and core's
default width is 120. Measured confirmation — a 6-codepoint, 12-cell CJK string stays flat at width 8
and breaks at 7, so core counts codepoints and not terminal cells.

The policy is stated with its cost rather than as if it were exact:

| text | bytes | codepoints | terminal cells |
| --- | --- | --- | --- |
| `→` | 3 | 1 | 1 |
| `α` | 2 | 1 | 1 |
| `x₁` | 4 | 2 | 2 |
| `世界` | 6 | 2 | 4 |
| `🎉` | 4 | 1 | 2 |
| `é` precomposed | 2 | 1 | 1 |
| `é` decomposed | 3 | 2 | 1 |

Codepoints are right for the notation Lean is actually written in — `→`, `α`, `x₁` all measure 1 or 2
and display 1 or 2 — and wrong for CJK and emoji, which under-count by half. They are also **not
normalization-stable**: the same grapheme `é` measures 1 column precomposed and 2 decomposed. The
alternative, UAX#11 East Asian Width, needs a table Lean core does not have and would put this
formatter's column count at odds with every other Lean tool. Agreeing with core is worth more than
agreeing with a terminal.

### 4.8 Output assembly

Fragments accumulate and are joined once. The assumption that repeated `out := out ++ s` is quadratic
in Lean is **false** and was measured rather than assumed: Lean's runtime mutates a string in place
when its reference is unique, so the append loop is linear and in fact beats `Array` + `String.join`
(200,000 fragments: 1.148 ms appending against 3.373 ms joining, identical output). Either is linear.
The quadratic risk is real only where the accumulator is shared, which the renderer's is not.

## 5. What this note does not decide

These are language decisions, and the roadmap assigns "remaining language decisions" to `RLC-FINAL`.
They are listed so a later stack does not mistake silence for a ruling:

- **Inconsistent (`fill`) breaking.** Both rejected candidates have it — `Std.Format.fill`, Oppen's
  `inconsistent` — and this contract does not. No Lean construct measured here needs it. If one does,
  it arrives as a behavior parameter on `group` and changes no other constructor.
- **Align to current column.** Excluded as column arithmetic; `Std.Format` has it.
- **Indentation clamping** against the margin (§4.6).
- **The margin itself.** Core's default is 120; mathlib's convention is 100. It is configuration, and
  because it changes output it must enter the identity of any cached formatting result. The `Doc`
  itself is never serialized and never enters cache identity.

## 6. Risks this hands forward

- **The comment split is ours, and it is a policy choice.** It matches what Lean documents as
  intuitively correct, but Lean does not run it. If a future toolchain calls `updateLeading`, tokens
  start arriving pre-split and this contract's §4.5 would be doing the work twice.
  `experiments/layout-core/run.sh` asserts `nonempty_leading=0` and fails loudly if that changes.
- **Codepoint width is a compromise** (§4.7), and it is wrong for CJK by a factor of two. It is right
  for Lean's actual notation and it agrees with core.
- **The linearity of the fit test is measured, not proved** (§4.6), and one adversarial shape is not
  yet covered. `RLC-FINAL` owns it.
