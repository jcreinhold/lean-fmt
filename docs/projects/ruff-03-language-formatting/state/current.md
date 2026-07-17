---
kind: state
first_unresolved: 06-notation-facts
---

# Current state

## Reopened for phase 2 (reflowing formatter) — 2026-07-17

**Phase 1 is verified and correct; the stack is reopened because its ambition changed, not because its
work was wrong.** An audit of the ruff family found `ruff-03` shipped a formatter that is a *no-op on
already-canonical Lean* — which phase 1 proves, seven times, is a fact about the corpus (already
canonical) and the language (most reflow is parse-unsafe) rather than about the authors. Every deferral
below carries a parser citation. But the roadmap Goal promised *canonical* formatting of terms,
operators, records, tactics, and `do`, and the parts that change non-canonical bytes were deferred with
receipts, not built. The user chose the **reflowing (ruff/Black-class)** ambition (2026-07-17, margin
100), so phase 2 builds the deferred capability on top of the verified phase-1 claims.

Phase 1's claims (`RLF-COMMANDS`..`RLF-FINAL`) stay **verified** — they are honest and narrow.
`RLF-FINAL` closed the *conservative*-coverage inventory and style policy; it is no longer the stack's
final claim. The design-twice and the layer map are in `notes/05-reflow-architecture.md`. **The
declared-spacing fact is not built here:** it needs the frontend `Environment` (a semantic-tier fact),
so it is owned by the new foundation stack `ruff-05b-semantic-facts` (`Tier.semantic` + artifact `v4` +
the capture producer), which both this reflow phase and `ruff-11`'s lint rules depend on. Phase 2 is
five prompts that consume that foundation:

| Prompt | Claim | Capability |
| --- | --- | --- |
| 06-notation-facts | RLF-NOTATION | *consume* the `ruff-05b` notation-spacing fact → operators take declared spacing |
| 07-offside-layout | RLF-OFFSIDE | parse-preserving re-indent to a canonical base (design-twice; reopens `ruff-02` only if a `Doc` constructor wins) |
| 08-reflow-expr | RLF-REFLOW | margin-driven line breaking for app/operator/binder/match (engine `group`/`nest`/`line`) |
| 09-reflow-blocks | RLF-BLOCKS | records + tactic/`do`/`where`/`let` offside layout |
| 10-reflow-final | RLF-ACCEPT | idempotence + parse-preservation + coverage + performance acceptance |

Build order for reflow: `ruff-05b` (RSF-SPEC→IMPL→FINAL) first, then these consume it.

The remainder of this file is the phase-1 record — a live claim about the conservative subset and the
evidence for it — kept intact because it is the citation base phase 2 builds against.

## Phase 1 record (conservative subset — verified)

`RLF-COMMANDS` is **verified** (`results/01-commands.md`): the printer is live and proven lossless on
this repository *and* on 62 modules of foreign Lean, **459 of the corpus's 483 commands take a cited
canonical layout** — `namespace` (25), `end` (25), `open` (7), and the shell of 402 of 414
declarations — **all 20 module headers take theirs**, and **57 constructor and field shells** are
claimed inside those declarations. `section` and `universe` have layouts too; this corpus contains
none of either, so only the fixtures and the sample exercise them. Its external prerequisite stack
`ruff-02-layout-core` is verified and its live implementation still matches recorded state.

**The corpus's 95% is 57.8% on real Lean, and that is the honest number.** Coverage is measured on the
frozen mathlib sample as well as here, and the two disagree because this repository's command mix is
not Lean's. What the remainder consists of is measured rather than guessed (`printer-unclaimed`): the
largest part is `lemma` (393), which is Mathlib's own syntax and correctly conservative, and the next
is `variable` (277), which is binders and so terms. Nothing in the remainder is a guard misfiring —
all 156 refused declarations are the cited `instance` (155) and `example` (1) exclusions.

Corpus figures move whenever this repository's own code changes, because this repository *is* the
corpus. They are re-read from `experiments/run-projection-shape.sh` rather than maintained by hand.
**They used to drift silently and a gate now catches it** (`RLF-FINAL`) — `RLF-EXTENSIONS` added
`Tree.mayCollapse` and left `Printer.lean`'s docstring, `notes/01-command-printing.md` §2 and §7, and
this file all quoting a node count from two prompts earlier, which is how the hazard was proved live
rather than theoretical. `tests/printer/run.sh` now closes the chain in two links: it asserts the
committed `evidence/01-projection-shape.txt` reports the counts the printer just measured on the live
corpus, and `experiments/check-quoted-figures.py` asserts every figure quoted in those three files
agrees with that evidence. Either link alone is worthless — prose checked against stale evidence
passes while everything is wrong together. Re-running the probe after touching `LeanFmt/` is part of
the work, not an optional tidy-up, and the suite now says so rather than the prose asking politely.

**The `results/NN-*.md` notes are excluded on purpose and are not gated.** They are snapshots of what
a prompt measured when it ran; rewriting their figures to today's would claim `RLF-COMMANDS` measured
something it did not. One is a live claim, the other is history — a difference in kind, not a gap.

**`RLC-FINAL`'s standing caveat is now half-answered.** That prompt closed the layout stack noting
nothing consumed it, so every claim about realistic documents rested on fixtures written against the
engine. `LeanFmt/Printer.lean` is the first consumer: it renders a real `Doc` from a real projection of
real modules, and it now decides things. What it does not yet do is decide anything that could
*overflow*: every layout so far is a flat run of tokens one space apart, so no `group`, `line`, or
`nest` reaches the engine from real source and `Doc`'s break behaviour remains exercised only by
`ruff-02`'s fixtures. The caveat narrows from "nothing consumes it" to "nothing yet asks it to break
a line".

`notes/01-command-printing.md` designs the printer interface twice and decides: **the printer reads the
`LosslessSource` projection, not `Lean.Syntax` inside the frontend.** The decision is forced by
`RLS-SPEC`, not chosen here — `ruff-01`'s roadmap line 18 already committed to carrying structure
"without exposing Lean frontend objects to product callers", and the artifact is already the cache key.
Printing inside the frontend would buy free arg order for a median 1.96 s frontend run per file
(`RLS-FINAL`) and would give up the cache to do it.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-commands | RLF-COMMANDS | verified | — |
| 02-expressions | RLF-EXPRESSIONS | verified | RLF-COMMANDS |
| 03-tactics | RLF-TACTICS | verified | RLF-EXPRESSIONS |
| 04-extensions | RLF-EXTENSIONS | verified | RLF-TACTICS |
| 05-corpus | RLF-FINAL | verified | RLF-EXTENSIONS |
| 06-notation-facts | RLF-NOTATION | planned | RLF-FINAL |
| 07-offside-layout | RLF-OFFSIDE | planned | RLF-NOTATION |
| 08-reflow-expr | RLF-REFLOW | planned | RLF-OFFSIDE |
| 09-reflow-blocks | RLF-BLOCKS | planned | RLF-REFLOW |
| 10-reflow-final | RLF-ACCEPT | planned | RLF-BLOCKS |

**`RLF-FINAL` is verified, and it closed phase 1** (`results/05-corpus.md`). It changed no layout and
no output byte: its finding is that **the refusals were never unsafe, they were unread.** The stop rule
is *zero silently unowned accepted syntax kinds*, and the word carrying it is **silently** — an
unclaimed command already kept its bytes, but `run-printer-sample.sh` counted the refusals into a report
and nothing compared that count to anything. `experiments/kind-inventory.txt` gives all 24 refused kinds
a disposition and a citation — `guard` (4 kinds, 196 commands: a layout claims it, a named runtime guard
declined), `core` (14, 542: the pinned compiler declares it, no layout claims it — scope, not
soundness), `corpus` (6, 417: declared by the code being formatted, unreadable by construction) — and
the three partition the sample exactly: **196 + 542 + 417 = 1155 = 2734 − 1579**.

**It is not the clearance table `notes/04-extensions.md` §5 refused, and the direction is why.** That
table would have *widened* what the printer collapses, so a stale entry emitted Lean that does not
parse. This one widens nothing: every kind is refused whether listed or not, no entry changes an output
byte, and a stale entry can only mis-describe a refusal — a wrong sentence, not wrong Lean. Both gate
directions are mutation-tested on a two-module sub-sample, and **the second direction is the point**: a
kind in the inventory but not the corpus is the exact rot §5 named, and catching it is what earns a
hand-written table its place here.

**The inventory covers commands and not terms, and that asymmetry is forced rather than chosen.** A
refused command is inert — no layout claims it, the whole command keeps its bytes. An unread *term* kind
is not: the printer descends into it and lays out the built-ins inside. So term ownership cannot be a
list of kinds, and `RLF-EXTENSIONS` proved it cannot be — a user's `withPosition(term:max colEq
term:max)` compiles to **no node at all**, and the column-check aliases are registered, so no census of
kinds can be finished. **A term-kind inventory is unfinishable, not merely expensive**; `Tree.mayCollapse`
is the answer there and needs no kind knowledge. Commands get a table because their set is closed; terms
get a guard because theirs is open.

**Mathlib was characterization input and not an authority, and the slack counters are what make that
checkable.** The style policy is four rules (one space in a claimed flat run; the declared string where
one is declared; `ppLine` after a docstring or attribute block; the header's blank-line rule). With
`app_slack=0`, `binder_slack=0`, `match_slack=0` and `tactic_blank_gaps=0` on all 62 modules, mathlib
**forced no style decision at all** — it already agrees with every rule. Where it disagreed once (a blank
line between `public import`s and plain `import`s) the resolution kept the *author's* line rather than
adopting mathlib's taste. The roadmap's worry about "unstable accidental style" never bit, and the
reason is measured: there was no accidental style in the sample to copy.

**The `"artifact"` checks are no longer vacuous.** `results/04-extensions.md` asserted in unchecked prose
that `__analyze-exact` omits the key for a module with parse errors; three checks in
`tests/printer/run.sh` are worth exactly that sentence's truth. It is now pinned on the real frontend —
and **the fixture's first draft was `def wrong : Nat := 1`, which is perfectly good Lean**, so the run
failed rather than printing `ok`. That self-guard is the property worth keeping. The withholding is on
`messages.hasErrors` (`LeanFmt/Analysis.lean:79`), i.e. *any* error; a parse error is the fixture because
it is the failure the checks exist to catch. The envelope's `diagnostics` carries a serialized artifact
of the compiler plugin's own, which cannot fool `grep -F '"artifact"'` because JSON escapes it inside a
string — verified at 0 rather than assumed.

**`RLF-EXPRESSIONS` is verified** (`results/02-expressions.md`). `Term.app`, the three bracketed
binders and `Term.matchAlt` are laid out; `Term.proj`, patterns, literals, quotations and
antiquotations are **answered — nothing to build**, each from its own grammar rather than from a blanket
caution; operators and records are **deferred with citations**, and precedence is **discharged, not
implemented**. The census that decided the scope is `evidence/02-term-census.txt` and the design is
`notes/02-expressions.md`. The load-bearing findings are that **spacing, not precedence, is what the
projection cannot supply**, and that **every layout it added is a provable no-op on all 62 modules of
foreign Lean**. That second one has now happened five times running, and `notes/02-expressions.md` §8
promotes it from a curiosity to the finding: the citable part of term formatting is the part that
changes nothing, and **the margin question is where the remaining value is**.

**The prompt's own premise was wrong, and that is the result rather than a complication.** It asked for
"precedence-aware" formatting. Precedence was never the blocker — the parser resolved it into the tree
before the projection ever saw it — so the prompt's stated task was already done by someone else, and
the real obstacle (the declared atom string, which the projection drops) was not named anywhere in it.
`RLF-TACTICS` and `RLF-EXTENSIONS` should be read with that in mind: their premises have not been
checked either.

**`RLF-TACTICS` is verified, and it ships no tactic layout** (`results/03-tactics.md`). That is its
finding, not a shortfall: in the constructs its task line names, the indentation *is a token* — a
tactic's column occupies the slot a `;` would (`checkColEq`, `Lean/Parser/Extra.lean:206-208`), and the
compiler's own docstring says `by skip skip` does not parse (`Term/Basic.lean:57-65`). The prompt's stop
rule is *do not conflate visual indentation with Lean offside semantics*, and that rule turns out to be
the whole prompt rather than a caution attached to it.

Two designs were written out and both were killed by counters rather than by argument:

- **Re-indent (`nest 2` + `hard`).** `nest` moves a printer-emitted newline but cannot move a `.keep`
  gap, which reaches the output as `verbatim` and is never re-indented (`Doc.lean:62-68`). So
  re-indenting moves each tactic's *first* line and abandons its continuation lines — onto the block's
  own column, where they stop being continuations and become tactics that do not parse. Measured on the
  sample: of 1966 blocks, **324 already begin their line at column 2, where the design emits the input**;
  **234 begin deeper and it would de-indent them out of their parent**; **864 begin inline and it would
  wrap them, needing a margin nobody has set**. Its entire licensed reach is the 324 where it does
  nothing.
- **Normalize the separator** (collapse a blank line between two tactics). **`tactic_blank_gaps=0`** on
  62 modules and 1966 blocks — real Lean has no such gap. `evidence/03-blank-line-columns.txt` says why
  and says it structurally: **all 3041 blank lines in the sample are followed by a column-0 line**, so a
  blank line *ends* an indented block and never sits inside one. A bigger sample would not change it.

**That is the sixth consecutive no-op** (`app_slack=0`, `binder_slack=0`, `match_slack=0`,
`tactic_blank_gaps=0`, and re-indent's 324-of-324), which `notes/02-expressions.md` §8 predicted.

Two findings outlast the verdict. **A citation was weaker than it looked, and the prompt caught it
rather than shipping on it:** the separator design cited `sepByIndent.formatter` emitting one `"\n"`
(`Extra.lean:218`) as licence to collapse an author's blank line. But that is a *formatter over a
`Syntax` tree* whose newline separator is a null node (`:215`) — the blank line is gone before it runs,
so one newline is all it *can* emit. An absence of information is not a ruling. This printer starts from
a lossless projection that still has what Lean's formatter lost, and **the compiler cannot be cited for a
decision it never had the information to make.** (The module header's `ppLine >> ppLine` is a *grammar*
declaring its own shape; that citation is real, which is why the header is the one layout here that
emits a blank line.) And **`Doc.align`, not effort, is what stands between this stack and re-indenting**:
`sepByIndent.formatter`'s own answer is `pushAlign (force := true)` (`:224`) — it aligns because it must
inherit a column it did not choose. `ruff-02` decided `Doc` has no align, by design and in writing
(`Doc.lean:71-73`), and that decision is verified and closed to this stack.

**`RLF-EXTENSIONS` is verified, and its finding is that the term layer was not parse-preserving**
(`results/04-extensions.md`). The registration boundary the prompt asks for was already there and is
not a registry: `Tree.canonical? | _ => none` and `spacingOf | _ => .keep` are the two closed matches,
a kind is registered iff this stack has read its declaration and written the citation down, and the
default keeps its bytes. The four named cases — same-file `syntax`, scoped `notation`, macro
quotations, mixed trees — all pass, and none of them was the hard part.

**The hard part was that descending into an unread kind and collapsing inside it emits Lean this
printer cannot re-read.** `theorem tA : (id     True) := by skip` / `trivial` parses; collapsing the
app moved `skip` four columns left while `trivial` did not move, and `sepByIndent`'s separator is
`checkColEq >> checkLinebreakBefore` (`Extra.lean:202-208`), so `trivial` fell out of the block.
`notes/02-expressions.md` §5b had the governing rule right and then **cleared `app` under it by
checking only the app's own saved position** — the one that breaks belongs to a block opened to the
app's *right on the same line*. Both breaks are in `evidence/04-coleq-break.txt`, input and output
re-analyzed.

**The first fix was defeated by a custom `colEq`, and that is why the shipped guard asks about the
command rather than about nodes.** A user's `withPosition(term:max colEq term:max)` compiles to **no
node at all** — the only node opens at `tbl`, left of the gap — so a census of cross-line nodes opening
to a gap's right looks straight past it; `tacticSeq1Indented` was caught only because it happens to be
its own node. `colGt`, `colGe`, `colEq`, `lineEq` and `withPosition` are registered parser aliases
(`Lean/Parser.lean:39-42, 50`), so the corpus can declare a live column check anywhere and no census of
kinds can be finished. `Tree.mayCollapse` needs none: same-line pairs cannot flip (a collapse never
reorders and never closes a gap below one space), so the hazard needs a check straddling a break — and
if a check straddles a break the smallest node holding both ends does too, so the command does. One
line in, one line out.

**Seventh no-op, and it is the same one.** The layer's whole effect is narrowing a same-line run of
spaces (`gapDoc` sends any gap with a newline to `.verbatim`), and `app_slack=0`, `binder_slack=0`,
`match_slack=0` say real Lean has no such run. So the guard costs nothing on the sample — `reformatted`
is still 12 — and is carried by fixtures instead. What it does cost is `matchAlt` **spread across
lines** (`wonky`: 47 rewritten lines → 39). One-line alternatives still collapse, so the entry is not
dead; an earlier revision claimed it was, without measuring, and that is corrected. The table that
would buy the cross-line case back is designed and refused in `notes/04-extensions.md` §5, on §6's own
ground: every entry is a claim about `Lean/Parser/Term.lean` that goes stale silently, and it would
recover a collapse that fires zero times.

## Known evidence

- **Precedence was never the blocker, and spacing is.** The projection carries no precedence
  (`LosslessSource.lean:64-86`), but it does not need to: the parser already applied precedence when
  it built the tree, so `a + b * c` arrives with `b * c` already a subtree of `+`. The numbers are what
  the parser needed to *decide* the shape; the shape is what a printer needs. What the tree does **not**
  carry is the space between two atoms. Lean's own formatter takes it from the atom's *declared*
  string — `infixl:65 " + "` (`Init/Notation.lean:284`) declares `+` with a space on each side, and
  `Init/Prelude.lean:5390` says so outright — falling back to a lexical minimum-separation rule only
  for atoms declaring none (`Lean/PrettyPrinter/Formatter.lean:366-417`). The projection records a
  token's *source* text, never the declaration. So `RLF-COMMANDS`'s "one space between two tokens" does
  not generalize to terms, and a term layout may cite only kinds whose spacing does not depend on that
  declared string.
- **`Term.app` is laid out, on the strongest citation in this stack.** It is the largest term kind in
  real Lean — 11,679 of 122,011 token-bearing nodes on the frozen sample — and it declares **no atom
  at all**: `app := trailing_parser:leadPrec:maxPrec many1 argument` (`Lean/Parser/Term.lean:892`).
  What separates a function from its argument is `argument := checkWsBefore "expected space" >>
  checkColGt … ` (`:885-888`), and `checkWsBefore` "requires that there is some whitespace at this
  location" (`Lean/Parser/Basic.lean:1180-1184`). **The parser rejects `f a` with the space removed**,
  so one space is the grammar's minimum rather than this formatter's taste — every command layout cited
  a shape the parser merely *permits*.
- **`Term.proj` needs no layout, and that is an answer rather than a gap.** It is `checkNoWsBefore >>
  "." >> checkNoWsBefore >> (fieldIdx <|> rawIdent)` (`:906-907`), so the parser rejects `e . f`. Every
  proj in a module that analyzed is already tight, and a layout collapsing it would be dead code on
  every input this printer can receive. 1,448 occurrences, zero work.
- **The application layout changes nothing on real Lean, and that is measured rather than assumed.**
  `app_slack=0` across all 62 sample modules: real Lean does not write `f     a`. `reformatted` could
  not have found this — it is per module, and the command layouts already reformat 12 of 62, so a term
  layout changing thousands of gaps and one changing none both report 12. The counter is *validated*
  rather than trusted, because a broken one would also answer 0, which is exactly what `misordered=0`
  turned out to be: `tests/printer/run.sh` pins it at 7 against the wonky fixture, an answer known by
  reading the golden. **This is the third appearance of this corpus shape** (0 collapsible of 266
  members, `reformatted` unmoved, now `app_slack=0`), and it says something about the prompt rather
  than the layout: *the part of term formatting that is safely available today is the part that changes
  nothing.* The part that would change something is vertical, and needs `nest` and a margin.
  `binder_slack=0` and `match_slack=0` below make it five, which is where `notes/02-expressions.md` §8
  stops treating it as a coincidence.
- **Three mutations prove the application layout non-vacuous, and they fail in three different
  places.** Dropping `gapDoc`'s spaces-only test deletes `/- why -/` outright, joins an app's lines,
  **and fails 12 of this repository's own 20 modules** — that guard is load-bearing on real code.
  Reading the app's own parts instead of lifting the `null` that `many1 argument` builds turns
  `List.replicate 3 8` into `List.replicate 3     8`. Emitting an unciteable kind's bytes wholesale
  instead of recursing into its parts leaves `id (id     9)`. The last two are **invisible to the
  corpus round-trip** and rest entirely on the fixture, which is what the fixture is for.
- **The three bracketed binders are laid out on one rule, and rule 1 turns out to be citable when the
  declaring set is closed.** `explicitBinder` (2,100), `instBinder` (951) and `implicitBinder` (800)
  take *brackets tight, every interior gap one space* — read off `Lean/Parser/Term/Basic.lean:206-207`,
  `:248-249`, `:217-218`. This is the first layout to depend on a **declared atom** (`binderType`'s
  `" : "` at `:181-182`, `binderDefault`'s `" := "` at `:186-187`), which the bullet above says the
  projection cannot carry — and the resolution is that that bullet is about *querying the table at
  runtime*, not about naming a declaration. These are `leading_parser`s in the pinned v4.32.0 compiler:
  a **closed** set, changed only by a toolchain bump. A notation is an **open** one the corpus can
  extend. Closed-versus-open is the line, not core-versus-not.
- **`withoutPosition` makes the binder warrant stronger than the app's, which is the reverse of what
  the citations predict.** All three binders wrap their interior in it, and it "runs `p` without the
  saved position, meaning that position-checking parsers like `colGt` will have no effect"
  (`Lean/Parser/Basic.lean:1565-1571`). So the `checkColGt` that forces `app` into *collapse, do not
  break* **is switched off by the grammar inside a binder's brackets**. `strictImplicitBinder` is that
  same citation backwards and stays conservative: it is the one bracketed binder without
  `withoutPosition` (`:234-236`), so collapsing would move its contents left under a live column check.
- **`(x :Nat)` → `(x : Nat)` is the first space this formatter has ever added.** It parses today —
  `" : "` is a pretty-printing string, not a parsing one — so the layout rewrites source that was never
  wrong. Defensible only because the added space is the one the declaration names, and it is the
  evidence the rule is declared spacing rather than "squeeze runs of spaces", which no collapsing-only
  fixture could show.
- **`binder_slack=0` on all 62 modules, and it is a different predicate from `app_slack`.** A binder's
  declared spacing differs per gap, so this counts every gap whose bytes differ from the declaration —
  gaps that are too *tight* included, which is why it cannot be a "count the long runs" check. Zero
  across 3,851 binders: real Lean writes `(x : Nat)` already. Hand-counted at 15 against the wonky
  fixture before being believed. Three mutations pin the rule rather than the output: `bracketed` made
  unconditional gives `( x y : Nat )`; the last-gap arithmetic off by one gives `[Inhabited Nat ]`;
  dropping the spaces-only guard deletes `/- why -/` **from inside a binder's brackets**, which is the
  case that shows the guard earns its place there and not only in flat runs.
- **The gap refusal is per gap, not per node — and the fixture nearly failed to say so.** A comment in
  a binder's first gap freezes *that gap* while the three behind it still collapse. The fixture
  originally wrote the commented binder with its other gaps already canonical, where a per-gap rule and
  an all-or-nothing rule emit identical bytes and the golden would have pinned neither; it now carries
  slack in the later gaps on purpose. Same shape as the header's per-gap import rule.
- **`matchAlt` is laid out, and it is `flat` by a different route than `app`.** All three gaps an
  alternative owns are *declared*: `"| "` carries a trailing space and `darrow := " => "` carries one
  on each side (`Lean/Parser/Term.lean:265-270`, `:99`), where `app` declares no atom and the parser
  requires the space instead. Its patterns keep their bytes: `sepBy1 (sepBy1 termParser ", ")` builds
  two levels of `null` and `liftedParts` lifts one, so `| 0,     m => m` collapses at the ends and not
  in the middle. Safe under §5b despite a live `checkColGe` and no `withoutPosition`, because
  `matchAlts` saves at the **first alternative's `|`** — a line start, left of everything a same-line
  collapse moves. `match_slack=0` on the sample over 121 alternatives; hand-counted at 22 first.
- **The one-level `null` lift is the boundary of what the shipped model can express *correctly*, not a
  shortcut.** Mutation 4 lifts `null`s recursively and reaches `matchAlt`'s pattern run, which emits
  `| 0 , m => m` — **a space before the comma** — because `flat` spaces every gap while `", "` declares
  only a trailing one. The shape model cannot say "tight left, one space right" for a single gap.
  Stopping the lift is what keeps those bytes safe.
- **The interface was designed twice, and the shipped one is the under-expressive one — on purpose.**
  The alternative is a declared-atom table keyed on (kind, token text), computing each gap from the
  adjacent atoms' declared strings, which is what `pushToken` does
  (`PrettyPrinter/Formatter.lean:366-417`) and which would get the comma right. It is **not
  free-standing at this layer**: the gaps it cannot derive from declared strings — a bracket against an
  ident — are the ones `pushToken:393` sends to `parseToken`, which needs `env := ← getEnv` and the
  token table (`:357-364`), i.e. an `Environment`, which the architecture excludes
  (`notes/01-command-printing.md` §3-5). What is available is a hybrid: declared strings plus a
  per-kind hardcoded rule for the tight gaps — which is what `bracketed` already is. Not built,
  because everything it would unlock is blocked for other reasons (`structInst` on §5b's column check
  under any model; `matchAlt`'s patterns are already safe), so it would be expressiveness with no
  claim behind it. `notes/02-expressions.md` §7b is the comparison and the recommendation.
- **`{` is not `{`, and it is the sharpest evidence in this stack that spacing must be read per
  declaration.** `structInst` declares its braces **spaced** — `"{ "` and `" }"`
  (`Lean/Parser/Term.lean:351-355`) — where `implicitBinder` declares them **bare**
  (`Term/Basic.lean:217-218`). `{a : Nat}` and `{ x := 1 }` are both canonical, the projection records
  `{` for both, and only the kind plus the declaration separates them. So `Spacing.bracketed` is not a
  rule about brackets: it is three declarations that agree, and it would emit `{x := 1}` for this one.
  A kind may be added to it only by reading its own grammar, never by noticing it has brackets — which
  is now what the constructor's docstring says, with `structInst` named as the counter-example.
- **Horizontal collapsing is not unconditionally safe, and `structInst` is the case that shows it.**
  `withoutPosition` does not reach its fields: `sepByIndent` re-establishes a saved position inside it
  and separates two fields by `", "` **or** by `checkColEq >> checkLinebreakBefore`
  (`Lean/Parser/Extra.lean:202-204`), so fields at a shared column on consecutive lines are separated
  *by that column*. Collapsing the gap after `{` moves the first field left, the second does not move,
  and the parse changes — **a horizontal collapse breaking a later line**, which is the one thing
  "collapse, do not break" assumed away. The rule sharpens to: *a collapse is safe when no live column
  check compares two tokens whose relative columns the collapse changes*. `app` and the binders pass
  it because the saved position sits at the construct's start, left of everything the collapse moves;
  `sepByIndent` saves at the **first field**, inside the construct and to the right. **Records are
  therefore deferred on the grammar and would be deferred under any model of spacing** — not on the
  abstraction.
- **Operators are notations, and their spacing is the declared string this printer cannot read.**
  13,219 of 122,011 token-bearing nodes (10.8%) are notation or foreign syntax: `«term_≤_»` (1548),
  `«term_=_»` (1059), `«term_*_»` (641), `termℕ` (638). Some are core and could each be hardcoded;
  that is refused on two grounds. A table of hundreds of entries mirroring declarations this printer
  cannot query goes stale silently the moment `Init/Notation.lean` changes, and no gate here would
  notice. And it does not generalize — `Arithcc.«term_≃[_]_»` is in the same census, declared by the
  corpus being formatted. So notations keep their bytes, the same answer `lemma` got, and
  `RLF-EXTENSIONS` owns them. `termℕ` is why the census does not detect notations by their guillemets:
  those are escaping, present only when the notation's own syntax needs them.
- **Five of the task line's eleven items need nothing built, and each says so from the grammar.**
  **Patterns are terms** — `matchAlt` parses them with `termParser` (`Lean/Parser/Term.lean:268`), and
  0 of the census's 600 kinds over 122,011 nodes are patterns; the `app` layout already runs inside
  them. **Strings and numerals cannot be touched structurally**: a token reaches the output only via
  `.verbatim (tokenSpanText …)`, so there is no path from a layout to a token's interior and "never
  normalize literal contents" holds by construction rather than by rule. **Syntax quotations need no
  case, and this is the one place the conservative answer would have been *wrong*** — every quotation
  wraps its contents in `withoutPosition` (`Lean/Parser/Command.lean:20-21`, `:50-51`;
  `Term.lean:1028-1029`, `:1124`, `:1126`), so the layout already reaches inside `` `(f     x) `` and
  is safe there by §5b's own criterion; refusing them would have been a rule with no citation.
  **Antiquotations** have no `spacingOf` entry, so `$x` arrives as an opaque part and cannot be split.
  **`Term.proj`** is the fourth (above).
- **A term layout inside a command on the conservative path would be sound, and is not done.** An
  `app` is an `app` whatever encloses it, and collapsing its gaps rests on `argument`'s `checkWsBefore`
  rather than on any claim about the enclosing kind — so terms inside a `lemma` could be laid out. They
  are not, only because that is a wider claim than this prompt has measured. That is scope, recorded
  rather than a rule.

- **Foreign code found a defect that this repository's corpus and every fixture had missed.** The
  printer now runs over the frozen mathlib sample (`experiments/run-printer-sample.sh`,
  `evidence/01-printer-sample.txt`), and it found the header layout **deleting a blank line**.
  `headerGap` emitted a single `hard` between every pair of import groups, reading the grammar's `many
  («import» >> ppLine)` as "the grammar decides vertical space". Mathlib puts a blank line between its
  `public import`s and its plain `import`s; the layout deleted it. **No header in this repository has a
  blank line inside it**, so neither the 20-module corpus nor a fixture I wrote could see it. The rule
  is now: keep a blank line the author left, collapse runs of them to one, add one only after
  `module`. That is a stop rule, not taste — this prompt defers import *organization* ("sorting is a
  separate opt-in fix"), and grouping imports by blank line is organization. The fixture now pins it
  and a mutation back to the old rule fails the golden.
- **The identity check is a claim about canonical source, not about the printer.** The first draft of
  the mathlib harness diffed the formatted output against its input and reported 7 of 29 modules
  failing. They were not failing, they were being formatted: `@[simp] theorem foo` becoming two lines
  is the declaration layout's attribute rule working. Byte identity holds only for source already
  written the way the layouts write it — true here, false and rightly so for mathlib. The properties
  that hold on *arbitrary* input are **idempotence** and **information preservation** (the output
  parses back to the same tokens and the same comments), and those are what the sample checks;
  `printer-roundtrip` keeps the identity assertion for the corpus, where it is true, behind
  `checkIdentity`.

- **The formatter decides its first thing, and the corpus could not have tested it.**
  `namespace` and `end` have canonical layouts, cited against `Lean/Parser/Command.lean:317-318` and
  `:337-338` (v4.32.0): a keyword and an optional identifier, exactly one space apart. So
  `namespace     Alpha` becomes `namespace Alpha`. **This repository already writes them canonically**,
  so `printer-roundtrip` passes on all 20 modules while exercising the layout and changing nothing — a
  canonical layout is only tested by source that is not already canonical. `tests/printer/run.sh`
  therefore adds a generated non-canonical fixture with a golden file, and asserts the formatter
  *changed* something (2 lines rewritten) so the golden cannot degenerate into a copy of its input.
  Idempotence is checked by re-parsing the first pass's output and formatting again — a real second
  format, not a repeated call.
- **Every declaration shape but `instance` has its shell laid out, and the name is found rather than
  indexed.** Six shapes open with a keyword and the name — `abbrev`, `definition`, `theorem`, `opaque`
  (`:187-199`), `inductive` (`:238-240`), `structure` (`:274-281`) — but `declId` does not sit at a
  fixed child position: `definition` puts it first, `«structure»` puts `structureTk` ahead of it. So
  it is looked for among the shape's children and one level inside their `optional` wrappers, which is
  where every one of those grammars puts it, and **never deeper** — a `declId` found inside a value
  would drag the shell past the name, and the shell must be a prefix of the command's tokens. That
  bound is defensive: no construct in this corpus nests a `declId` inside a declaration, so nothing
  here exercises it. `class Foo` needs no case of its own: `classTk` is one of `«structure»`'s two
  openers, so it is a `structure` node.
- **A `structure`'s fields and an `inductive`'s constructors get a shell of their own, and the grammar
  says how much of one.** `01-commands.md`'s task names "declarations, structures, inductives"
  outright, so `structFields` (`:257-262`) and `ctor` (`:210-212`) are `RLF-COMMANDS`'s. Their claim is
  the opener, the modifiers and the name, and stops there: everything past a member's name is
  `optDeclSig` or a `bracketedBinder` — a term, and `RLF-EXPRESSIONS`'s — and stopping at the name is
  also what keeps the claim one contiguous run, which is all a `Claim` can be. Their *vertical* layout
  is not available at all: `structFields` is `manyIndent` = `withPosition ((colGe p)*)`
  (`Lean/Parser/Extra.lean:199-201`), so field indentation is parser-significant, and re-indenting can
  change what parses.
- **The claim model is an array of regions, not a prefix.** `canonical?` returns the prefix ending at
  the declaration's name; `Tree.claims` appends a claim per member, and `Tree.command` emits verbatim
  bytes between them. That generalization is what lets one `structure` lay out its own shell, leave its
  signature as bytes, then lay out each field's shell — regions a single prefix could not reach past.
  Members are claimed only inside a command that already has a layout: a kind on the conservative path
  rests on no grammar claim, and reaching inside it to lay out a field would be exactly such a claim.
- **The member layout changes nothing in this corpus, and that is a fact about the corpus, not the
  rule.** `evidence/01-projection-shape.txt`: **0 collapsible of 266 members** — 195 fields are
  one-token shells (an unmodified field is just its name, with no gap to collapse), 14 are doc-broken,
  and all 49 constructors and 8 structure constructors are already tight. The probe was built expecting
  that to *retire* the work, and it does not: this repository is its own corpus, so "nothing here would
  change" says the code is already formatted, not that `|     first` should be left alone. What the
  figure decides is what can test the layout — the corpus cannot, so `members=` counts the claims and
  the wonky fixture carries the only proof it changes a byte.
- **A member shell needs no column guard, and the reason is why doc-commented fields are refused.**
  The declaration shell needs `atLineStart` because it emits `hard` after the docstring, and `hard`
  indents to nothing. A member shell is a pure flat run with no break in it, so it is correct at any
  indentation. The price is that a shell whose gaps cross a line cannot be laid out at all —
  `flatGaps` refuses it, because reproducing the break would put the name at column 0, which under
  `manyIndent` may not even parse. That is why `structSimpleBinder`'s doc-commented fields are refused
  while `ctor`'s documented constructors are laid out: a `ctor`'s doc comment sits under `optional`,
  outside the shell, so it keeps its bytes and its break for free; a field's sits inside its
  `declModifiers`, hence inside the shell. Both guards are mutation-tested — dropping `flatGaps` pulls
  the field name up onto its doc comment's line, dropping `triviaClean` deletes `/- why -/` from
  `|     /- why -/     third` outright, and each fails the golden.
- **The declaration shell is laid out, modifiers included.** Cited against
  `Lean/Parser/Command.lean:282-285` (a `declaration` is exactly `declModifiers` plus one shape) and
  `:114-121` (seven optional
  modifier slots in fixed order). The two slots that are not flat token runs are read by index and
  emitted verbatim, each followed by a line break the grammar itself asks for: `docComment` ends in
  `ppLine` (`Lean/Parser/Term.lean:91-93`, which is inside `namespace Lean.Parser.Command` — hence the
  kind), and attributes are followed by `ppDedent ppLine` unless `inline`, which `declaration` does not
  pass. So `@[inline] def     e` on one line becomes `@[inline]` and `def e` on two. The slot
  structure is measured, not assumed: each `optional` is a `null` node whether filled or not, so an
  empty `declModifiers` still has seven children and the slots are addressable by index.
- **The two guards are asked over different ranges, and collapsing them would be a silent regression.**
  Trivia cleanliness is asked over the whole shell — a comment between any two of its tokens would be
  dropped, including in the gaps the layout fills with a line break. The newline-free check is asked
  only of the flat run, because the verbatim slots keep their bytes: asking it of the docstring would
  refuse every multi-line one, and with it most real declarations. The fixture pins a multi-line
  docstring being laid out for exactly that reason.
- **A line break may only be emitted at column 0, and the corpus could never have found that.**
  `Doc.hard` emits a newline plus the current indentation, this printer never nests, so its only
  indentation is column 0. On an indented declaration the docstring would stay put while the `def`
  jumped left. Mutating the guard to always pass reproduces exactly that (`  /-- ... -/` above
  `def indented`), caught only by a deliberately indented fixture — every command in this repository
  is at column 0. Whether top-level commands *belong* at column 0 is a language decision no prompt
  here has made, so the layout keeps its bytes rather than assume one.
- **Re-spacing is gated on losing nothing, and the gate is load-bearing.** A canonical layout chooses
  the space between tokens, so anything between them that is not whitespace would be dropped.
  `respaceable` refuses the layout when a comment sits inside the command, when a token's own text
  spans a newline (`Doc.text` requires newline-free content), and the command keeps its bytes instead.
  Mutating the guard away makes `namespace /- c -/ Gamma` silently become `namespace Gamma` and fails
  the golden. Only the runs *strictly inside* the command are examined: the last token's trailing run
  holds the newline, the blank lines, and the next command's leading comments, so `Tree.command` emits
  the trivia before the first token and after the last one verbatim and canonicalizes only the middle.
- **Imports are not commands, and the projection structurally cannot carry them.** The corpus holds
  **429 commands in 7 distinct kinds** and not one is an `import`: the module header is not in the
  token stream at all. `headerStop` is 54 bytes on `LeanFmt/Rules.lean` and covers `module` plus both
  `import` lines, recorded as bytes with no node and no token. This is one layer down and deliberate —
  `LosslessSource.ofSource` (`LosslessSource.lean:358`): "Neither producer may pass the module
  header — a module linter never receives it". The plugin producer is a module linter and Lean never
  hands it the header, so no schema carrying header syntax could be produced by both mandated
  producers. **This is not a blocker and not a missing lower-layer piece**, but the recorded reason was
  read off a signature and is corrected here. `Lean.Parser.parseHeader` (`Lean/Parser/Module.lean:75`)
  takes an `InputContext` and no `Environment` *as a parameter* — but its body opens with
  `let dummyEnv ← mkEmptyEnvironment` and builds its token table from it, which is the whole reason it
  is `IO`. So it does need an environment; it makes an empty one. The conclusion survives and is
  actually firmer than the argument that reached it: **no frontend environment is required**, an empty
  one is available anywhere in `IO`, so the printer can parse `[0, headerStop)` with Lean's own parser
  on bytes `normalizedDigest` already binds.
- **The header is laid out, and its cost is one `IO` boundary that changed nothing about what a
  formatted module depends on.** `Printer.format` is now `IO String` because `parseHeader` builds an
  empty environment; both callers were `IO` already, and the parse reads only `normalized`, which
  `format` already took because every conservative path slices bytes out of it. So the artifact's
  digest still binds every input. `tests/boundary/run.sh` constrains the *plugin's* import cone and
  `LeanFmt.Printer` is deliberately outside `LeanFmtCompilerPlugin`'s globs, so `import
  Lean.Parser.Module` there breaks no recorded rule; `notes/01-command-printing.md`'s Design A is not
  contradicted either, since its argument was about a median 1.96 s *frontend* run for commands and a
  header parse is not a frontend run.
- **The header layout declines per group and per gap, and an all-or-nothing rule would have switched
  itself off on the file that introduced it.** The first draft refused the whole header when a comment
  sat anywhere inside it — and `LeanFmt/Printer.lean`'s own header acquired a comment between its
  imports in the same edit, so that draft refused it. The shipped shape mirrors `Tree.command`: each
  group (`module`, `prelude`, each `import`) and each gap between two groups decides alone. So
  `  import     Lean.Data.Name` keeps its indent (the gap declines) *and* collapses its spaces (the
  group does not), which the golden pins.
- **The header is where the formatter first decides vertical space, and the grammar decides it.**
  `header := optional (moduleTk >> ppLine >> ppLine) >> optional («prelude» >> ppLine) >>
  many («import» >> ppLine) >> ppLine` (`Lean/Parser/Module/Syntax.lean:26-29`): two `ppLine`s is a
  blank line after `module`, one `ppLine` per import. Every command layout so far only ever chose
  *spaces*, so this is the first rule that can add or remove a line. Import order is never touched —
  the fixture's imports are in an order that differs from alphabetical in five of six positions, and
  mutating the walk to reverse them fails.
- **Groups are found by kind, not by argument index.** The `optional`/`many` wrappers are `null` nodes
  whose empty slots have no position — the same absence measured below — so an index-based read would
  need a case per filled/unfilled combination. Dispatching on `moduleTk`/`«prelude»`/`«import»`
  needs none, and a future grammar change surfaces as a refusal rather than as a header laid out from
  the wrong slot.
- **Three header guards were untested until a fixture was written for each, and one still is.**
  Mutation testing found `headerGap`'s line-start check, `headerGroupDoc`'s comment check, and its
  newline check all surviving — the corpus reaches none of them, because every header here is already
  canonical. The first two now have fixture lines (an indented import; `import /- why -/ Foo`) and
  mutating either fails the golden by name. The third is **defensive and unreached, which is recorded
  rather than left to be discovered**: five of the header's six atoms are fixed keywords and the sixth
  leaf is a module name, so only `import «a⏎b»` could spell a newline — the lexer accepts it
  (`takeUntilFn isIdEndEscape`, `Lean/Parser/Basic.lean:986`) but such a module would have to exist on
  disk to elaborate, so no test here can reach it.
- **`lake build` with no arguments does not build `LeanFmtTest`, and a real error was dismissed as
  stale LSP noise because of it.** `Printer.headerDoc?` was reported unknown by the editor while
  `lake build` reported success; the identifier really was wrong (the definition sat outside
  `namespace Printer`), and only `lake build lean-fmt lean-fmt-tests` — what `tests/printer/run.sh`
  runs — surfaced it. The standing lesson that LSP diagnostics go stale is true and was the wrong
  reading here; the authoritative command names its targets.
- **Coverage is counted by the printer, because byte identity cannot see it and the corpus cannot
  either.** Every module round-trips exactly and would still round-trip exactly if every guard refused
  every command — the printer would fall back to bytes and be the identity function it was before any
  layout existed. This repository also writes its declarations the way the layout writes them, so even
  a layout that runs changes nothing here. `printer-roundtrip` therefore reports `canonical=`, the
  commands actually laid out, and `tests/printer/run.sh` floors the corpus total: **459 of 483**, and `members=` the shells claimed
  inside them, floored at 50 (**57**) because `canonical=` cannot see them — a command counts once
  whether it claims one region or six. The
  header gets the same treatment for the same reason, but as an exact count rather than a floor
  (`headers_canonical=20` of 20): a module has exactly one header, and the layout declines per group
  and per gap, so there is no header shape here it should refuse outright. The golden fixtures pin
  *what* the layouts produce; these pin *that* they run, on real code, at scale.
- **Two independent measurements of coverage agree exactly, and keep agreeing as it grows.**
  `experiments/run-projection-shape.sh` re-implements the structural half of the printer's predicate in
  Python against the same projection and finds 402 of 414 declarations claimable; the printer, in Lean,
  counts 459 = 402 + 25 `namespace` + 25 `end` + 7 `open`. So on this corpus every
  structurally-claimable declaration also passes the runtime guards the probe cannot model (clean
  trivia, newline-free flat run, column 0). The probe over-counts by construction and says so;
  `canonical=` is the honest figure.
- **That 459 commands take the layout and all 20 modules stay byte-identical is what proves the shell
  is a prefix.** A shell that ran past the name, or stopped short, would duplicate or drop bytes on
  real code. The same round-trip is the only thing asserting that the header layout's claim ends
  exactly at `headerStop` — that the parser's idea of where the header stops and the projection's agree
  is checked by `lastStop > headerStop`, but that the *bytes in between* are reproduced is checked only
  by the identity. Nothing asserts either directly.
- **A coverage number inferred from the wrong population was off by a factor of seven, and the fix
  redirected the work.** The empty-node census reports empty `declModifiers` in the hundreds (318 when
  this was found, 323 now), which reads like
  "almost every declaration carries no modifiers" — but `declModifiers` is also on every structure
  *field* (`declModifiers true`, the inline form, `Lean/Parser/Command.lean:114`), so those 318 were
  never counting declarations. Counting the printer's actual predicate showed modifiers, not shapes,
  were the blocker on 262 of 345 declarations, which is why `declModifiers` was laid out next and why
  coverage went 45 → 271. The estimate would have sent this to `structure` and `inductive` instead.
- **The ownership table is measured, and it is shorter than the prompt's list.**
  `declaration` 361, `namespace` 25, `end` 25, `moduleDoc` 9, `open` 7, `registerOption` 1,
  `initialize` 1 (`evidence/01-projection-shape.txt`, 429 commands). Structures, inductives, attributes, and binders
  are **not** commands — the grammar nests them inside `declaration`, under `declModifiers` and the
  `def`/`theorem`/`structure`/`inductive` choice — so they are reached by dispatching within it. A
  declaration's *value* is a term, which `RLF-EXPRESSIONS` owns; `RLF-COMMANDS` lays out the shell and
  leaves the value conservative, which the skeleton supports directly because one command's `Doc` can
  mix canonical structure with `verbatim` subtrees.
- **The printer skeleton is lossless on real parser output, and the test proves it by mutation.**
  `LeanFmt/Printer.lean` renders header + command extents + `#exit` tail; with every kind on the
  conservative path it is the identity on accepted source. `tests/printer/run.sh`:
  `modules_checked=20 commands=429 failures=0`, at margins 0, 1, 40, 80, 120, and 1000 — the margin
  must not matter, since `verbatim` is specified to emit bytes unchanged and not to force a break.
  A generated fixture on the real parser covers what this repository lacks: a custom `syntax`/
  `macro_rules` command (an unknown kind), CJK and emoji, a multi-line string literal, an inline and a
  newline-spanning block comment, and a 173-byte `#exit` tail. **Non-vacuity is proven twice, and the
  two checks catch different things.** Mutating `tokenEnd` to ignore trailing trivia fails every
  module — but by only *one byte* (5416 → 5415), because dropping a trailing run merely shifts a
  boundary and the next extent absorbs the bytes; only the last command's trailing newline actually
  escapes. Mutating the extent walk to never close at a command boundary is **invisible to byte
  identity** — it round-trips perfectly at every margin — and is caught only by the tiling assertion:
  `11 commands produced 1 extents`. Byte identity alone would have accepted a printer with no
  command structure at all.
- **A seventh of real syntax cannot be placed by position, so the printer must know the grammar.**
  Measured by `experiments/run-projection-shape.sh` over 21 modules of this repository (the printer
  test's 20 plus the `LeanFmt.lean` root, which projects to no commands), 39,027 nodes
  (`evidence/01-projection-shape.txt`): `pre_order_contiguity_violations=0` and
  `nonempty_node_children_out_of_source_order=0`, so a tree view over the projection is
  reconstructable and its child order agrees with the source. But **14,092 nodes (36.1%) carry no
  token at all** — they are *absent* syntax, and `collect` gives them range `(0,0)` because a node's
  range is the hull of the leaves beneath it and there are none. Of those, **6,007 (15.4% of all
  nodes)** sit under a parent that also has direct token children, so nothing in the projection says
  where among its siblings an absent slot belongs. This is not a gap the projection introduced:
  `Lean.Syntax` has no position for an empty node either. A printer therefore cannot reconstruct arg
  order from ranges and must dispatch on kind — which it must do anyway, since canonical layout is
  per-construct by definition.
- **The conservative fallback is the only path that rests on no grammar claim.** Empty nodes
  contribute no bytes, so re-emitting a subtree's tokens in source order with their trivia is
  unaffected by all 6,007 ambiguous placements. The roadmap's "unknown commands must round-trip
  conservatively" and this measurement point the same way.
- **"Are children in arg order" is unaskable of the projection, and asking it produced a vacuous
  pass.** The projection stores only `parent`, so index order is the only order it retains and the
  question compares index order against itself. The probe's first draft asked it and reported
  `misordered=0` — a number no input could have contradicted. Arg order is guaranteed by `collect`'s
  code, not by its output. The replacement check compares index order against *byte* order, and was
  mutation-tested: reversing child order on the real corpus raises it to 4,324.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- **`RLF-COMMANDS` is met.** Every category its task line names is either laid out or deferred with the
  grammar line that forces the deferral; `results/01-commands.md` audits them one by one. The 22
  commands still conservative here are `instance` (11), `moduleDoc` (9), `registerOption` (1), and
  `initialize` (1). **Binders** are the one named category with no layout, and they are
  `RLF-EXPRESSIONS`'s twice over: `bracketedBinder` is a `Lean.Parser.Term` parser
  (`Term/Basic.lean:256`), and every one of its four alternatives is bracketed.
- **The corpus's 95% coverage is a fact about its command mix, and foreign code says so.** On the
  frozen mathlib sample the same printer claims **1579 of 2734 commands (57.8%)**. That gap is not a
  defect and not a floor to be raised for its own sake: `printer-unclaimed` names the kind of every
  refusal, and the largest single category is **`lemma` (393)**, which is *Mathlib's own syntax*
  (`Mathlib/Tactic/Lemma.lean:20`) and does not exist in the compiler this stack cites. The
  conservative path is the right answer for it — that is "unknown commands must round-trip
  conservatively" working, and it is `RLF-EXTENSIONS`'s to claim, not this prompt's. `variable` (277)
  is `many1 bracketedBinder`, so it is terms and `RLF-EXPRESSIONS`'s. A bare percentage cannot tell
  those apart from a guard misfiring, which is why the census reports kinds rather than a rate.
- **`section` was named by this prompt's own task line and had no layout; only foreign code showed
  it.** "namespaces/sections" is in `prompts/01-commands.md`, and **this corpus contains no `section`
  command at all** — the sample has 181. `section` and `universe` (20) now take flat-run layouts cited
  against `Command.lean:299-300` and `:531-532`. `sectionHeader`'s `@[expose]` slot is bracketed and is
  refused by `opensAttributeBracket`, the same call `open` makes for `openOnly`; a mutation disabling
  that guard emits `@[ expose ] public section` and fails the golden. As with the members, the corpus
  cannot test any of this, so the wonky fixture carries the whole proof — a bare `section` is one token
  and byte-identical, so the fixture needs *labelled* and `noncomputable` sections to show a decision.
- **`moduleDoc` may well need no layout at all, and that is an answer rather than a gap.** It is
  `"/-!" >> commentBody >> ppLine` (`:60-61`): an opener and a body of prose. There is nothing in it
  the formatter may re-space, so the conservative path *is* its layout. Recording that conclusion, and
  checking whether the opener's space is a real decision, is cheap and unstarted.
- **`open`'s three flat alternatives are laid out; `openOnly` and `openRenaming` are not** (`:724-739`).
  A flat run would emit `Alpha ( a )` and `a → myA , b → myB`. Brackets and separators need a layout
  that knows about them, which no prompt here has claimed.
- **`instance` is excluded on two separate grammar facts, not on difficulty** (`:202-204`). Its
  `declId` is `optional` — anonymous instances are ordinary Lean — so the shell cannot simply end at
  the name and must end at the keyword instead; and `optNamedPrio` (`:64-65`) is bracketed, so a flat
  run would emit `( priority := 5 )`. Each needs its own fixture. **All 11 in the corpus are
  anonymous** (`evidence/01-projection-shape.txt`), so their shells are the keyword alone with no gap
  any layout could close: excluding `instance` provably costs this corpus nothing, and the
  keyword-ended shell would be untestable here. A *named* instance has something to re-space, and the
  fact that none occurs is a fact about this corpus rather than about Lean — that layout is a separate
  claim that would need its own fixture to mean anything.
- **A declaration's signature and value are untouched, by decision and not by omission.** Both are
  terms and `RLF-EXPRESSIONS` owns them (`notes/01-command-printing.md` §7), so the shell layout stops
  at the `declId`'s last token and everything after it is bytes. `Tree.canonical?` returns *the last
  token its layout claimed* precisely to make that expressible; a layout claiming the whole command
  would have re-spaced the signature, which is the failure the split exists to prevent.
- **`Doc`'s *break* behaviour is still exercised only by `ruff-02`'s own fixtures.** The printer
  consumes `Doc` through `verbatim`, `text`, `cat`, `empty` and `hard` — the last from the header
  layout and from the line a declaration's doc comment forces — but no `group`, `line`, or `nest`
  reaches it from real source. Those are the constructors that make a *decision*: `hard` breaks
  unconditionally, so nothing yet asks the engine to measure a width and choose. Every layout so far
  is a flat run of tokens one space apart. `RLC-FINAL`'s "`call-args` is my model of a Lean call, not a
  Lean call" stands until a layout lands that can actually exceed the margin, which is
  `RLF-EXPRESSIONS`.
- **The margin is unset.** `Printer.format` requires `width` rather than defaulting it: the value is
  configuration, it enters cache identity (`RLC-SPEC` §5), and `RLC-FINAL` left it an open language
  decision. Nothing in this stack has picked one, and no caller passes one outside tests.
- **Every supported kind's grammar shape will be a hardcoded claim about a parser the printer cannot
  query.** There is no `Environment` outside the frontend. Each shape must carry the parser
  declaration it mirrors and be pinned by a golden fixture, or it is the "textual guessing" the
  roadmap forbids.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
