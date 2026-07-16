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

## 3. Every construct the task line names is this same combinator

Read one at a time, and they converge:

| construct | grammar | source |
| --- | --- | --- |
| tactic scripts | `sepBy1IndentSemicolon tacticParser` | `Term/Basic.lean:74-75` |
| bullets | `cdotTk tacticSeqIndentGt`, and `cdotTk := unicode("· ", ". ")` | `Init/NotationExtra.lean:320-322` |
| `where` (decls) | `... "where" >> sepByIndent (ppGroup letRecDecl) "; " (allowTrailingSep := true) ...` | `Term.lean:740-741` |
| `where` (struct inst) | `... "where" >> structInstFields (sepByIndent structInstField "; " ...)` | `Command.lean:173-175` |
| records (deferred by 02) | `sepByIndent` | `notes/02-expressions.md` §5b |

`sepByIndent` and `sepBy1Indent` differ only in emptiness (`Extra.lean:202-208`); the separator clause
is identical. **Bullets are not a separate case**: `cdot` is `cdotTk` followed by a `tacticSeqIndentGt`,
so a bullet is a *nested* tactic sequence and inherits §2 whole. Its atom `"· "` is declared with a
trailing space, which is citable the way `matchAlt`'s `"| "` was — and it is declared with `syntax` in
`Init/NotationExtra.lean` rather than `leading_parser`, which prompt 02's criterion already covers: the
test is **closed versus open**, and `Init` is in the pinned compiler, so the corpus cannot redefine it.

So the task line's items are not seven problems. They are one problem, wearing seven hats.

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

1. **How many blocks qualify** — a block with every gap single-line. Unknown; the census counts kinds,
   not line spans.
2. **How many qualifying blocks are already canonical.** Real Lean indents tactic blocks by two. If the
   answer is "almost all", this layout joins `app_slack=0`, `binder_slack=0` and `match_slack=0` as a
   sixth no-op, and the honest report is that it changes nothing.
3. **What `tacticSeqBracketed` actually costs.** The census's exhaustive list is `Lean.Parser.Term.*`
   only (`evidence/02-term-census.txt:115`), so the tactic kinds appear only in its top-60 and
   `tacticSeqBracketed` is below the cut. `tacticSeq` is 1967 and `tacticSeq1Indented` is 1966, which
   *suggests* the bracketed form is vanishingly rare — but the difference is not the count, because
   `tacticSeqIndentGt`'s `pushNone` branch makes token-free `tacticSeq1Indented` nodes that the census
   excludes. **This needs its own census (`evidence/03-tactic-census.txt`), not an inference from two
   numbers**, and 1967 − 1966 = 1 is exactly the kind of arithmetic that produced the stale `7` this
   stack just finished correcting.

## 7. Open, and honest about it

- **The margin is still unset**, and this prompt does not need it: a deterministic block uses `hard`,
  never `line`, so nothing asks "does this fit". That is worth stating because it means prompt 02's
  "the vertical part needs a margin" was half right — the *breaking* part needs a margin; the
  *indenting* part needs only `nest`.
- **`nest` from a non-zero column is still unsolved** (`Printer.lean:1186`, `startsLine`). A `by` block
  under a top-level command starts from column 0, so `nest 2` lands at 2. A `by` block nested inside
  another block does not, unless every enclosing level nests too — which is §5's "own every newline"
  again, one level up. Any layout here is therefore top-level-only until that is faced.
