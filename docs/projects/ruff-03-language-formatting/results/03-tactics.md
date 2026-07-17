# RLF-TACTICS — results

Design and citations: `notes/03-tactics.md`. Evidence: `evidence/03-tactic-census.txt` (which tactic
syntax exists), `evidence/03-blank-line-columns.txt` (where real Lean puts a blank line, measured
without this repository's code), `evidence/01-printer-sample.txt` (the 62-module frozen sample).

**This prompt ships no tactic layout.** That is its finding, not a shortfall against it. The task line's
constructs are ones where the indentation *is a token* (§2), the prompt's own stop rule forbids
conflating the two, and the two designs that could be written turn out to be — measured, not argued —
one no-op and one parse-breaker. What ships is the reading, four counters, and the fixtures that keep
them honest.

## What the task line asked for, and what each item got

| item | outcome | why |
| --- | --- | --- |
| tactic scripts | **answered — nothing shippable** (`tacticSeq1Indented`, 1966) | the column *is* the separator (`checkColEq`, `Extra.lean:206-208`); `nest` cannot move a `.keep` gap, so re-indenting strands continuation lines *as tactics* (§5). Design A's licensed reach is 324 of 1966 blocks and on all 324 it emits the input |
| bullets | **answered — same, inherited** (`cdot`, 371) | `cdotTk tacticSeqIndentGt` nests a tactic sequence, so §2 applies whole (`Init/NotationExtra.lean:320-322`) |
| case alternatives | **answered — a different family** (`matchAlts`) | `many1Indent`: `checkColGe` only, no separator clause (`Term.lean:279-280`). The column is a *bound*, not a token — but §5's ownership still binds |
| `do` | **answered — a different family, and nearly absent** (43 `doSeqItem`) | `doSeqIndent := many1Indent doSeqItem` (`Do.lean:29-30`), `checkColGe` only. 43 items against 1966 tactic sequences |
| `where` | **answered — §2's family; the term spelling is absent** (`Term.whereDecls`, **0**) | `sepByIndent` in both spellings (`Term.lean:740-741`, `Command.lean:173-175`). `Term.whereDecls` does not occur in the sample at all — the 199 `where` lines there are the *command* spelling (`structure … where`), a different kind |
| `let` | **answered — a third family, and 02's layer** (26 `Term.let`) | `semicolonOrLinebreak := ";" <|> checkLinebreakBefore >> pushNone` (`Term.lean:100`) — **no column check at all**. A term parser, so `RLF-EXPRESSIONS`' layer; §5 catches it anyway |
| nested layout | **answered — blocked on `Doc.align`, which `ruff-02` closed** | `nest` counts from column 0 for a printer that never nests (§7). 234 ownable blocks begin their line deeper than 2, and A would de-indent every one out of its parent |
| deep nesting fixtures | **delivered** | `nestedBlocks` (bullets), `nestedOwnLine` (a `have … := by` with its own block), `inlineBlock` — the three shapes that land in three different buckets |
| comment-placement fixtures | **delivered** | `gapCommented` — a comment in a separator gap, which is what makes the whitespace-only guard load-bearing |

## Commands

    LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests      # 41 jobs; `lake build` alone does NOT build the tests
    ./tests/printer/run.sh                                      # includes the new tactic fixture
    ./tests/boundary/run.sh
    ./experiments/run-printer-sample.sh                         # the 62-module frozen sample
    ./experiments/run-blank-column-census.sh                    # the independent blank-line census
    ./experiments/run-tactic-census.sh                          # which tactic syntax exists

## Measurements

From `evidence/01-printer-sample.txt`, 62 modules, `failures=0`, `skipped=0`:

    tactic_blocks=1966 tactic_ownable=1422 tactic_ownable_own_line=558 tactic_ownable_at_two=324
    tactic_blank_gaps=0

Read as design A's ledger — A rewrites a block as `nest 2` over `hard`-separated tactics beginning a
fresh line at column 2, and `tactic_blank_gaps=0` already says the separators *are* one newline:

| ownable blocks | count | what A does | licensed? |
| --- | --- | --- | --- |
| begins its line at column 2 | **324** | emits the bytes already there | vacuously — it is the identity |
| begins its line, deeper than 2 | **234** | de-indents it out of its parent | **no** — a broken parse |
| begins inline (`:= by simp`, `· skip`) | **864** | breaks it onto a new line | **no** — wrapping, and the margin is unset |

**A's entire licensed reach is 324 of 1966 blocks (16.5%), and on every one it produces the input.** The
1098 where it would *do* something are exactly the 1098 where it has no right to. This is the sixth
consecutive measurement of the same shape — `app_slack=0`, `binder_slack=0`, `match_slack=0`,
`tactic_blank_gaps=0`, and now this — and prompt 02's §8 predicted it.

It also puts a size on §5's warning that `ownable` is an **upper bound**: it overstates A's licensed
reach by 4.4×. "Ownable inside" was never "safe to move".

From `evidence/03-blank-line-columns.txt`, which never loads this project's code:

    modules=62 blank_lines=3041 blank_gaps=3041 gaps_between_two_indented_lines=0

**Every one of the 3041 blank lines in the sample is followed by a column-0 line.** A blank line in real
Lean *ends* an indented block; none sits inside one. So `tactic_blank_gaps=0` is structural, not a
scarcity a bigger sample would fix.

From `evidence/03-tactic-census.txt`: `tacticSeq=1967 tacticSeq1Indented=1966 tacticSeqBracketed=1
bullets=371`. The bracketed `{ tacs }` spelling is dead syntax — counted, not inferred from
`1967 − 1966`, because `tacticSeqIndentGt`'s `pushNone` branch makes token-free nodes and the two
numbers are not complements (§6.3).

## Decisions changed during execution

- **Design B was the deliverable, and it is retired.** §8 chose B over A because B moves no column.
  Then `tactic_blank_gaps=0`: B's reach is empty. B was designed, counted, and dropped without a line
  of layout code, which is the order §8 committed to ("it gets a counter before it gets a layout").
- **B's citation was weaker than §8 recorded — and this matters more than the count.** §8's table cites
  `sepByIndent.formatter:218` (one `"\n"` per newline separator) as B's licence, in the same column as
  `Format.defIndent := 2` as A's, as though they were the same kind of thing. They are not.
  `defIndent` is a constant the compiler indents by. `sepByIndent.formatter` is a *formatter over a
  `Syntax` tree* whose newline separator is a null node (`n.matchesNull 0`, `:215`) — the blank line is
  gone before that code runs, so one newline is all it *can* emit. That is an absence of information,
  not a ruling that an author's blank line should go, and this printer starts from a lossless projection
  that still has what Lean's formatter lost. **The compiler cannot be cited for a decision it never had
  the information to make.** B would not have shipped at a non-zero count either. (Contrast the header's
  `optional (moduleTk >> ppLine >> ppLine)` — a *grammar* declaring its own vertical shape. That
  citation is real, and it is why the header is the one layout in this stack that emits a blank line.)
- **§3 was source-false, twice, and both were my own prose.** It first said the task line was "one
  problem wearing seven hats" — false: `do` is `many1Indent` (`checkColGe` only), not `sepByIndent`
  (`checkColEq`). I had generalized from four constructs that agreed. The correction to "two families"
  was *also* short: it had no row for `let`, which the task line names and which is neither combinator
  (`semicolonOrLinebreak`, no column check at all). Fixed to three families, each read in the grammar
  rather than inferred from the others.
- **The same false claim was still live in a second file.** `run-tactic-census.sh:17-18` repeated §3's
  "one family" sentence after `ae0922b` had corrected the note. Found by grepping the claim repo-wide
  rather than re-reading the file I had just edited — which is exactly how the *first* one was found,
  and exactly the check I had skipped when I made the second.
- **`tactic_ownable_at_two` alone was the wrong measurement, and its first number was misleading.** At
  324-of-1422 it looked like "A de-indents 1098 nested blocks". It does not: most of those 1098 are
  *inline* (`:= by simp`), where A would wrap rather than de-indent — a different decision failing for a
  different reason. Splitting on `firstOnLine` gives the honest three-way ledger above. The headline
  (A is licensed on 324) is unchanged; the reason it fails on the rest is not one reason but two.

## The interface, designed twice (Plan step 2)

| | **A — re-indent** | **B — normalize the separator** |
| --- | --- | --- |
| what it emits | `nest 2` + `hard` per separator | one `"\n"` + the gap's trailing indent, verbatim |
| moves a column? | yes | no |
| needs §5's ownership? | yes | no |
| reach on real Lean | **324 blocks, all identity** | **0 blocks** |
| where it changes bytes | 1098 blocks it may not touch | nowhere |
| citation | `Format.defIndent := 2` — real, but licenses a column A cannot inherit | `sepByIndent.formatter:218` — **not a licence**; a formatter that lost the information |
| verdict | **dead**: no-op where licensed, parse-breaking where not | **dead**: empty reach, and unlicensed anyway |

Neither ships. The comparison is retained because the *reason* they differ is the prompt's content: A
fails on Lean's offside semantics, B fails on the evidence, and knowing which is which is what tells a
later stack that `Doc.align` — not effort — is the thing standing between here and A.

## Non-vacuity: four mutations

Every number above is 0 or small, and a broken counter reports those just as readily. This stack has
shipped a vacuous 0 before — `RLF-COMMANDS`' `misordered=0`, which no input could have contradicted and
which took a mutation to notice. So the counters are checked by breaking them, against
`tests/printer/run.sh`'s tactic fixture, whose answers are countable by eye
(`blocks=10 ownable=8 own_line=5 at_two=4 blank_gaps=3`):

| mutation | result | what it pins |
| --- | --- | --- |
| drop `tacticBlankGaps`' whitespace-only guard | `blank_gaps` 3 → **4** | the guard: `gapCommented`'s comment would be deleted by B |
| `newlines > 1` → `newlines > 0` | `blank_gaps` 3 → **4** | that a lone separator newline is not a blank line |
| `columnOf`: drop the newline reset | `at_two` 4 → **0** | that the column is a column and not a byte offset |
| `columnOf`: `== 2` → `== 4` | `at_two` 4 → **1** | the target column — and the 1 is `nestedOwnLine`'s inner block, confirming the middle bucket by a second route |
| `firstOnLine` → always true | `own_line` 5 → **8** | the inline/own-line split, which is what separates "A wraps this" from "A de-indents this" |
| drop `tacticBlocks`' multi-line test | `ownable` 8 → **10** | §5's ownership test itself |

The blank-gap 0 has a second, independent support that no mutation of this code could rescue:
`experiments/run-blank-column-census.sh` reads the sample as lines and never loads the projection or the
printer, and it agrees.

## Remaining uncertainty

- **`Doc.align` is the one thing that would change the answer**, and it is closed to this stack.
  `sepByIndent.formatter`'s own solution is `pushAlign (force := true)` (`Extra.lean:224`), commented
  "so that `withPosition` will pick up the right column" — the compiler aligns because it must inherit a
  column it did not choose. `ruff-02` decided `Doc` has no align, by design and in writing
  (`Doc.lean:71-73`), and that decision is verified. It is a `Doc` change, not a printer change, and it
  is what stands between here and A's 234.
- **The margin is still unset** and would move some of the 864 inline blocks. `RLS-FINAL`'s, not this
  prompt's — the same open item prompt 02 closed on.
- **`tactic_ownable` remains an upper bound even after the split.** `at_two` tests the block's *own*
  column, not that every enclosing level is printer-owned up to the command root. It happens not to
  matter: A is the identity on all 324, so a laxer guard admitting a few more would still emit their
  bytes. It would matter to any layout that actually moved something.
- **`where`, `do` and `let` are read but not measured to the depth tactic scripts are.** Their counts
  say the mass is not there — `Term.whereDecls` **0**, `doSeqItem` **43**, `Term.let` **26**, against
  1966 tactic sequences — and §5's ownership argument covers all three regardless of family. The three
  counts come from `evidence/02-term-census.txt`'s exhaustive `Lean.Parser.Term.*` list, which runs to
  every kind occurring even once; a kind absent from it occurs zero times. That is a real bound for
  `whereDecls` and a weak one for the *command* `where` (`structure … where`), which is not a `Term.*`
  kind and which that census therefore cannot see at all — 199 lines in the sample carry a bare `where`
  token and nearly all of them are that one. If a later prompt wants to lay any of these out, the
  counter comes first, and for the command `where` it does not exist yet. That is the rule this prompt
  spent itself proving.
