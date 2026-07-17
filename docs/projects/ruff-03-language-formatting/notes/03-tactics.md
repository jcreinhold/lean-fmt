# RLF-TACTICS — tactic sequences, `do`, and layout-sensitive blocks

Design notes. Evidence: `evidence/02-term-census.txt` (the 62-module frozen sample; its top-60 list
covers the tactic kinds, its exhaustive list does not — see §6). Results: `results/03-tactics.md`.

Prompt 02 ended on a finding this prompt has to start from: *the citable part of term formatting is
the part that changes nothing; the part that would change something is vertical.* This prompt **is**
the vertical part. So the question is not "is there work here" — it is whether the vertical work is
available at this layer, and §5 is where that gets decided.

## 1. The question

The task line asks for "deterministic blocks for tactic scripts, bullets, case alternatives, `do`,
`where`, `let`, and nested layout". The stop line says: **do not conflate visual indentation with Lean
offside semantics.**

That stop rule is usually a caution about being careless. Here it is the whole prompt, because in every
construct named above the indentation *is* a token. Not "is significant" — *is a token*, occupying the
slot a `;` would occupy. §2 is the citation.

## 2. The separator is the newline, and the compiler's own docstring says so

    def tacticSeq1Indented : Parser := leading_parser
      sepBy1IndentSemicolon tacticParser        -- Lean/Parser/Term/Basic.lean:74-75

and `sepBy1IndentSemicolon` is not a mystery — it is documented in the compiler, in these words
(`Term/Basic.lean:57-65`):

> `sepBy1IndentSemicolon(p)` parses a (nonempty) sequence of `p` optionally followed by `;`, similar to
> `many1Indent(p ";"?)`, except that if two occurrences of `p` occur on the same line, the `;` is
> mandatory. This is used by tactic parsing, so that
> ```
> example := by
>   skip
>   skip
> ```
> is legal, but `by skip skip` is not - it must be written as `by skip; skip`.

**`by skip skip` does not parse.** The thing that makes the two-line version legal is the newline, and
the newline is doing the job `;` does on one line. Unfolding one more step (`Term/Basic.lean:67-68`,
`Lean/Parser/Extra.lean:206-208`):

    sepBy1IndentSemicolon p = sepBy1Indent p "; " (allowTrailingSep := true)
    sepBy1Indent p sep psep allowTrailingSep =
      withPosition $ sepBy1 (checkColGe "irrelevant" >> p) sep
        (psep <|> checkColEq "irrelevant" >> checkLinebreakBefore >> pushNone) allowTrailingSep

The separator is `psep <|> checkColEq >> checkLinebreakBefore >> pushNone` — either a literal `;`, **or
a linebreak followed by a token at exactly the saved column**. `withPosition` saves at the *first
tactic*, and the `tacticSeq` docstring says so in prose too (`Term/Basic.lean:81-83`): "Delimiter-free
indentation is determined by the *first* tactic of the sequence."

So a tactic's column is not its presentation. Move one tactic one space right and the `checkColEq` fails
and it stops being a separator: the tactic does not begin, and it is instead offered to the previous
tactic's parser as more input. That is not a formatting regression, it is a different program or a parse
error.

This is the same combinator, and the same argument, that made `RLF-EXPRESSIONS` defer `structInst`
(`notes/02-expressions.md` §5b). It was one deferred kind there. Here it is the prompt.

## 3. The task line names **three** families, and only one of them has §2's problem

The first draft of this section said the task line was "one problem wearing seven hats". That was false
— `do` is the counter-example — and the correction that replaced it, "two families", was *also* short by
one: it had no row for `let`, which the task line names. Both errors are the same error, made twice:
reading the constructs that agree and asserting the rest. The rule that catches it is to read every item
on the task line in the grammar, and the third family below is what that turned up.

There are two indentation combinators in `Lean/Parser/Extra.lean`. They are one letter apart in the
source and not at all alike in what they mean:

    sepBy1Indent p sep psep _ =
      withPosition $ sepBy1 (checkColGe .. >> p) sep
        (psep <|> checkColEq .. >> checkLinebreakBefore >> pushNone) _     -- :206-208
    many1Indent p =
      withPosition $ many1 (checkColGe .. >> p)                            -- :190-191

`many1Indent` has **no separator clause at all** — no `checkColEq`, no `checkLinebreakBefore`. Its
column is a *bound* ("indented the same or more than the first parse", `:184-186`), not a token. So the
whole of §2 — the column *is* the separator, move it and the program changes — applies to one family
and not the other:

| construct | combinator | is the column a separator? | source |
| --- | --- | --- | --- |
| tactic scripts | `sepBy1IndentSemicolon` → `sepBy1Indent` | **yes** — `checkColEq` | `Term/Basic.lean:74-75` |
| bullets | `cdotTk tacticSeqIndentGt` — nests a tactic sequence | **yes**, inherited | `Init/NotationExtra.lean:320-322` |
| `where` (decls) — **0 on the sample** | `sepByIndent (ppGroup letRecDecl) "; "` | **yes** | `Term.lean:740-741` |
| `where` (struct inst) | `sepByIndent structInstField "; "` | **yes** | `Command.lean:173-175` |
| records (deferred by 02) | `sepByIndent` | **yes** | `notes/02-expressions.md` §5b |
| `do` | `doSeqIndent := many1Indent doSeqItem` | **no** — `checkColGe` only | `Lean/Parser/Do.lean:29-30` |
| match alternatives | `matchAlts := withPosition $ many1Indent (ppLine >> matchAlt ..)` | **no** — `checkColGe` only | `Term.lean:279-280` |
| `let` | `optSemicolon := ppDedent $ semicolonOrLinebreak >> ppLine >> p` | **no** — no column check *at all* | `Term.lean:118-120`, `:550-551` |

**Bullets are not a separate case**: `cdot` is `cdotTk` followed by a `tacticSeqIndentGt`, so a bullet
is a *nested* tactic sequence and inherits §2 whole. Its atom `"· "` is declared with a trailing space,
citable the way `matchAlt`'s `"| "` was — and it is declared with `syntax` in `Init/NotationExtra.lean`
rather than `leading_parser`, which prompt 02's criterion already covers: the test is **closed versus
open**, and `Init` is in the pinned compiler, so the corpus cannot redefine it.

`do` is the one item in the task line that is *not* §2's problem, and it is also nearly absent: 43
`doSeqItem` and 38 `doExpr` on the sample, against 1966 tactic sequences. Its own item separator is
declared — `doSeqItem := ppLine >> doElemParser >> optional "; "` (`Do.lean:27-28`) — and that `ppLine`
is the same citation vehicle the header layout uses. What it is *not* is free of §5: `many1Indent`
still bounds every item at `checkColGe` against the first, so re-indenting `do` still requires owning
every newline in it, for exactly §5's reason. It is a weaker constraint, not an absent one.

**`let` is the third family, and it is neither combinator.** It is

    «let» := leading_parser:leadPrec
      withPosition ("let" >> letConfig >> letDecl) >> optSemicolon termParser   -- Term.lean:550-551
    optSemicolon p := ppDedent $ semicolonOrLinebreak >> ppLine >> p            -- :118-120
    semicolonOrLinebreak := ";" <|> checkLinebreakBefore >> pushNone            -- :100

so what separates a `let` from its body is a semicolon **or a linebreak, with no column check on
either side**. Not `checkColEq`, not even `checkColGe`: `withPosition` closes around the *declaration*
and the body is outside it. §2's argument does not touch `let`, and neither does §4's — there is no
column here to preserve, only a line break to keep.

That makes `let` the freest of the three and the best-cited: its `ppLine` sits in the parser
declaration, exactly like the module header's `optional (moduleTk >> ppLine >> ppLine)` that the header
layout already cites. It is also the smallest: **26 `Term.let` on the sample**
(`evidence/02-term-census.txt`), against 1966 tactic sequences. The 510 `letDecl` there are mostly the
*tactic* `let` and `do`'s, which are different kinds reusing the same declaration parser — counting
`letDecl` as `let` would be the `tacticSeqBracketed` mistake in the other direction, and §6.3 is where
this stack agreed not to make it.

And `let` is a **term** (`@[builtin_term_parser]`), so it was `RLF-EXPRESSIONS`' layer, not this one's;
the task line reaches across a prompt boundary to name it. It does not matter much, because §5 catches
it anyway: emitting that `ppLine` means emitting the newline before the body, and the body's own lines
stay `.keep`. Same trap, one prompt down.

So: six of the nine hats fit one head, `do` and match alternatives fit a second, and `let` fits a third.
Saying otherwise — as this section did twice — is the overclaim this stack keeps catching in its own
prose.

## 4. What the enclosing check actually measures — and it is weaker than it looks

`byTactic := ppAllowUngrouped >> "by " >> Tactic.tacticSeqIndentGt` (`Term.lean:107-108`), and

    tacticSeqIndentGt := tacticSeqBracketed
      <|> (checkColGt "indented tactic sequence" >> tacticSeq1Indented)
      <|> node ``tacticSeq1Indented pushNone          -- Term/Basic.lean:90-92

`checkColGt` against *which* saved position? `byTactic` does not call `withPosition`, and neither does
`declValSimple` (`Command.lean:169-170`). The nearest one out is the module's:
`(withPosition commandParser).fn` (`Lean/Parser/Module.lean:133`) — **every command is wrapped in
`withPosition` at its own first token**. For a top-level `theorem`, that is column 0.

So the constraint a top-level `by` block faces from outside is only `column ≥ 1`. Everything stricter —
the `checkColEq` that separates the tactics — is *internal* to the block, measured against the block's
own first tactic.

That asymmetry is the one hopeful fact in this prompt, and it is worth stating precisely:

> **A uniform shift of an entire tactic block preserves every column relation the parser checks
> inside it**, because `checkColGe` and `checkColEq` both compare tokens in the block against the
> block's own first tactic, and a uniform shift moves both sides equally. The only checks it can break
> are against tokens *outside* the block, and for a top-level command the only such check is
> `checkColGt` against column 0.

That is §5b's criterion from prompt 02, applied and *passed* rather than failed. Which would make the
re-indent safe — if a uniform shift were a thing this printer could perform. §5 is why it is not.

## 5. `nest` moves only the newlines the printer emits, and that decides the prompt

The engine is ready. `Doc.nest` exists (`LeanFmt/Doc.lean:74`) and both `fits` (`:179`) and `go`
(`:209`) honor it; it is this printer that has never called it. So the obvious move is: emit the block
as `.nest 2 (.hard ++ tac₁ ++ .hard ++ tac₂ ++ …)` and let the engine place the columns.

That does not do what §4 licenses, and the gap between the two is where this prompt lives.

`hard` emits a newline plus the current indentation, so `nest` moves it. But a gap this printer does not
claim is emitted as `.verbatim raw` (`Printer.lean`, `Tree.gapDoc`), and `verbatim`'s contract is
explicit (`Doc.lean:62-68`): **"Its interior is never re-indented, which is the entire reason it
exists."** A `.keep` gap that spans lines carries its newline *and the next line's leading spaces* as
literal bytes. `nest` does not touch them, and must not — that same guarantee is what stops a block
comment's body and a multi-line string's contents from being rewritten.

Now put the two together on a tactic that spans lines:

    by
      simp [foo,
        bar]
      exact h

Emitting the separators as `hard` under `nest 2` moves `simp` and `exact` — the printer owns those
newlines. The newline inside `simp [foo,` is a `.keep` gap, so `bar]` does not move. Re-indent the
block by two and you get `simp` at column 4 with `bar]` still at column 4: the continuation has drifted
from *inside* the tactic to *exactly the separator column*, and by §2 that is no longer a continuation.
It is a new tactic — `bar]` — which does not parse.

So a partial vertical layout is not a conservative approximation of a full one. **It is wrong in a
direction the conservative path is supposed to exclude**, and it is wrong precisely because `nest` and
`verbatim` disagree about what a line is. This is the prompt's stop rule — *do not conflate visual
indentation with Lean offside semantics* — reached from the implementation side rather than the
grammar side: `nest` is visual indentation, `checkColEq` is offside semantics, and a printer that emits
both onto the same block has conflated them.

**A block may therefore be re-indented only if the printer owns every newline inside it.** Not most.
Every one — a single unclaimed line-spanning gap anywhere in the block is enough, and it fails silently,
because the projection round-trips and only the *parse* changes.

## 6. What that leaves, and what has to be measured before any of it is written

Two ways to own every newline in a block:

- **Own the whole language.** Descend into every tactic and every term below it with a vertical layout,
  so no `.keep` gap can span a line. That reaches the 13,219 notation nodes (10.8% of the sample) whose
  spacing lives in a `notation` declaration this printer cannot read — `RLF-EXTENSIONS`, prompt 04,
  which comes *after* this one. This is not available here, and saying so is not a scheduling
  complaint: it would still not be available in prompt 04, because 04 makes notations citable, not
  line-breakable.
- **Refuse the blocks that contain one.** Re-indent a block only when every gap inside it is
  single-line, and keep the bytes otherwise. This is available today, needs nothing from prompt 04, and
  is the shape of every guard this stack has shipped.

The second is the candidate. Before it is written, three things have to be measured rather than
assumed, and the fifth-time-running pattern from prompt 02 says what to expect:

1. **How many blocks qualify — measured: `tactic_blocks=1966 tactic_ownable=1422`.** 72.3% of real
   Lean's tactic blocks have every tactic on one line, so the printer could own their newlines. **This
   is the first number in this stack that is not zero.** Five measurements running said the citable
   part changes nothing; this one says the reachable part is most of the corpus. It is an upper bound
   (`Printer.lean`, `Tree.tacticBlocks`) — ownable *inside* is necessary, not sufficient, because an
   ownable block can sit inside a block that is not.
2. **How many qualifying blocks are already canonical — measured: `tactic_ownable_own_line=558`,
   `tactic_ownable_at_two=324`.** The question turned out to be three questions, and splitting them is
   the answer to this prompt. Design A rewrites a block as `nest 2` over `hard`-separated tactics
   beginning a fresh line at column 2; `tactic_blank_gaps=0` (below) already says every separator *is*
   one newline; so A is the identity on a block exactly when the block already begins its line at
   column 2, and changes bytes otherwise. Of the 1422 ownable blocks:

   | | count | what A does | licensed? |
   | --- | --- | --- | --- |
   | begins its line at column 2 | **324** | emits the bytes already there | vacuously — it is the identity |
   | begins its line, deeper than 2 | **234** | de-indents it to 2, out of whatever encloses it | **no** — §5's `.keep` trap, and the prompt's "fallback must remain parse-preserving" |
   | begins inline (`:= by simp`, `· skip`) | **864** | breaks it onto a new line | **no** — a *wrapping* decision, and the margin is unset (§7) |

   So this layout is the **sixth no-op**, and this time the no-op is not a disappointment but the entire
   safety margin: A's whole licensed reach is 324 of 1966 blocks (16.5%), and on every one of them it
   produces the input. The 1098 blocks where it would *do* something are exactly the blocks where it has
   no right to. `app_slack=0`, `binder_slack=0`, `match_slack=0`, `tactic_blank_gaps=0` and now this —
   prompt 02's §8 is on record predicting it, and it is right for the sixth time.

   This is also the number that puts a size on §5's warning that `ownable` is an **upper bound**: it
   overstates A's licensed reach by 4.4×. "Ownable inside" was never the same claim as "safe to move",
   and the distance between them is 1098 blocks.
3. **What `tacticSeqBracketed` actually costs — measured: `tacticSeqBracketed=1`.**
   `evidence/03-tactic-census.txt` counts it directly across all 62 modules. **One.** The `{ tacs }`
   spelling is dead syntax in real Lean, so a layout for it would be dead code on every input this
   printer can receive — the same verdict `Term.proj` got, and for the same reason: not "too hard", but
   "nothing to decide". That also disposes of its `"{ "`/`"}"` trap (spaced open, bare close —
   `structInst` again, `notes/02-expressions.md` §5b) without needing to read it.

   The count was taken rather than inferred, and the inference would have been *right*: 1967 − 1966 = 1.
   It is still not evidence, because `tacticSeqIndentGt`'s `pushNone` branch (`Term/Basic.lean:90-92`)
   makes token-free `tacticSeq1Indented` nodes that a token-bearing census excludes, so the two numbers
   are not each other's complement and their agreeing here is luck. This stack has already shipped one
   figure that was arithmetic rather than measurement — the stale `7` in `results/02-expressions.md` —
   and the rule that catches it is: **a number nobody counted is not a number.**

## 7. Open, and honest about it

- **The margin is still unset**, and this prompt does not need it: a deterministic block uses `hard`,
  never `line`, so nothing asks "does this fit". That is worth stating because it means prompt 02's
  "the vertical part needs a margin" was half right — the *breaking* part needs a margin; the
  *indenting* part needs only `nest`.
- **`nest` from a non-zero column is still unsolved** (`Printer.lean:1186`, `startsLine`). A `by` block
  under a top-level command starts from column 0, so `nest 2` lands at 2. A `by` block nested inside
  another block does not, unless every enclosing level nests too — which is §5's "own every newline"
  again, one level up. Any layout here is therefore top-level-only until that is faced.

## 8. The interface, designed twice — and Lean's own answer uses a primitive this `Doc` refuses

Plan step 2 asks for the interface twice. Reading `sepByIndent.formatter`
(`Lean/Parser/Extra.lean:211-226`) supplies a third design that outranks both, and then rules itself
out — which is the useful part.

**What Lean itself does** for exactly this construct:

    def sepByIndent.formatter (p : Formatter) (_sep : String) (pSep : Formatter) : Formatter := do
      ...
        if i % 2 == 0 then p else pSep <|>
          ((if i == stx.getArgs.size - 1 then pure () else pushWhitespace "\n") *> goLeft)
      -- If there is any newline separator, then we add an `align` at the start
      -- so that `withPosition` will pick up the right column.
      if hasNewlineSep then
        pushAlign (force := true)

Two things, and both are citations this prompt did not have before:

- **the separator it emits is exactly one `"\n"`** (`:220`) — never two, never a blank line;
- **the block's column comes from `pushAlign (force := true)`** (`:224`), whose own comment says why:
  *"so that `withPosition` will pick up the right column"*. Lean does not *choose* the block's column.
  It aligns to wherever the first element already landed, and that is precisely how it guarantees the
  `checkColEq` in §2 — the separator column and the first element's column are the same thing by
  construction.

**This printer cannot do that, by a decision that predates the prompt.** `Doc` has no align, and
`Doc.nest`'s docstring says it is deliberate (`LeanFmt/Doc.lean:71-73`): "Relative and additive …
**There is no align-to-current-column, which is column arithmetic and outside the caller's vocabulary
by design.**" `ruff-02` is a verified stack; this one depends on it and does not get to reopen it.

That is a real gap and it is worth being exact about how big. It is **not** a correctness blocker: a
block emitted as `.nest 2 (.hard ++ t₁ ++ .hard ++ t₂ …)` puts every tactic at the same column, which
is all `checkColEq` asks, and `Format.defIndent := 2` (`Init/Data/Format/Basic.lean:379`) is where the
2 comes from rather than from taste. What it costs is that **this printer must *choose* the column
where Lean *inherits* it** — so the two agree only when the block starts on its own line at the
command's indent plus two, and diverge everywhere else. Since `nest` counts from column 0 for a printer
that never nests (§7), "everywhere else" means every block that is not directly under a top-level
command.

So the two designs actually on offer:

| | **A — re-indent** | **B — normalize the separator** |
| --- | --- | --- |
| what it emits | `nest 2` + `hard` per separator | one `"\n"` + the gap's original trailing indent, verbatim |
| moves a column? | yes | **no** |
| needs §5's ownership? | yes — the guard, ≤ 1422 blocks | no |
| needs `align`? | substitutes `nest 2`, agreeing with Lean only at top level | no — it never picks a column |
| citation | `Format.defIndent := 2` | `sepByIndent.formatter:220` emits exactly one `"\n"` |
| reach | top-level ownable blocks only | **every block, ownable or not** |

**B is the deliverable.** It is strictly weaker and strictly safer, and the asymmetry is not a
compromise — it is §5 read correctly. A is dangerous *because* it moves columns, and every guard it
needs exists to stop it moving one it should not. B never moves a column at all: it rewrites only the
run of newlines inside a separator gap and re-emits that gap's trailing indentation byte for byte, so
the tokens either side keep their columns and §2's `checkColEq` cannot be disturbed by construction.
It needs no ownership, no margin, no `align`, and no nest — and it reaches all 1966 blocks rather than
at most 1422.

B needs one guard, and it is the one this stack already has: **whitespace-only.** A separator gap can
hold a comment (`\n  -- why\n  `), and rewriting its newline run would delete the comment. That is
`gapDoc`'s spaces-only test (`notes/02-expressions.md`, mutation 3) generalized from *spaces* to
*whitespace*, and the mutation that proved it load-bearing there is the same mutation here.

What B is worth is **unmeasured and might be nothing**: it changes a byte only where real Lean has a
blank line between two tactics. That is the sixth instance of the question this stack keeps asking, and
prompt 02's §8 is on record predicting the answer. It gets a counter before it gets a layout.

## 9. The counters answered, and both designs are dead

§8 ended by saying B gets a counter before it gets a layout. It got one. So did A. Neither survives,
for different reasons, and the reasons are worth more than the verdict.

**B is a no-op: `tactic_blank_gaps=0`,** across 62 modules and 1966 blocks. B rewrites the newline run
inside a separator gap; real Lean has no gap with more than one newline in it. The independent census
(`evidence/03-blank-line-columns.txt`) says why, and says it more sharply than the counter can: **every
one of the sample's 3041 blank lines is followed by a column-0 line.** A blank line in real Lean *ends*
an indented block; none sits inside one. So B's reach is empty structurally, not by scarcity, and a
bigger sample would not change it.

**B's citation was also weaker than §8 recorded, and that is the more useful finding.** §8's table cites
`sepByIndent.formatter:218` — one `"\n"` per newline separator — as the licence to collapse a blank line,
alongside `Format.defIndent := 2` as A's. They are not the same kind of citation and I wrote them into
one column as though they were. `defIndent` is a constant the compiler indents by. But
`sepByIndent.formatter` is a *formatter over a `Syntax` tree*, and its newline separator is a null node
(`n.matchesNull 0`, `:215`): the blank line is already gone before that code runs. One newline is all it
*can* emit. That is an absence of information, not a ruling that an author's blank line should go — and
this printer, which starts from a lossless projection, still has the information Lean's formatter lost.
**The compiler cannot be cited for a decision it never had the information to make.** Contrast the module
header's `optional (moduleTk >> ppLine >> ppLine)`, which is a *grammar* declaring its own vertical shape;
that citation is real, and it is why the header layout is the one thing in this stack that emits a blank
line. So B would not have shipped at a non-zero count either.

**A is the sixth no-op, and the no-op is the safety margin.** §6.2 has the table: A's licensed reach is
the 324 blocks that already begin their line at column 2, where it emits the input. The other 1098
ownable blocks are ones it would change and may not — 234 by de-indenting a nested block out of its
parent (§5's `.keep` trap, and the prompt's "fallback must remain parse-preserving"), 864 by making a
wrapping decision that needs a margin nobody has set (§7). A is not "too weak to bother with"; it is a
rule whose entire effect is on blocks it has no licence to touch.

**So `RLF-TACTICS` ships no tactic layout, and that is the finding rather than a failure to deliver.**
The prompt's own stop rule — *do not conflate visual indentation with Lean offside semantics* — is
precisely what A does, and §2 through §6 are the reading that shows it and the numbers that size it.
What ships is the reading, the four counters, and the fixtures that keep them honest.

**What would change the answer**, stated so a later stack does not have to re-derive it:

- **`Doc.align`.** Not `nest`. §8's whole argument is that A must *choose* a column where Lean
  *inherits* one, and `sepByIndent.formatter`'s own answer is `pushAlign (force := true)` (`:224`),
  commented "so that `withPosition` will pick up the right column". `ruff-02` decided `Doc` has no align
  (`Doc.lean:71-73`) and that decision is verified and closed to this stack. It is the single change that
  would move the 234, and it is a `Doc` change, not a printer change.
- **A margin.** It would move some of the 864, and it is `RLS-FINAL`'s to set, not this prompt's.
- **Neither touches the 324**, which are already right. Nothing here is waiting on effort.
