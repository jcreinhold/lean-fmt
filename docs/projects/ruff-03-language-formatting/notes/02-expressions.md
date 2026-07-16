# RLF-EXPRESSIONS — where precedence comes from, and where spacing does not

## 1. The question this has to answer first

`prompts/02-expressions.md` asks for "**precedence-aware** formatting … using parser/category
information rather than textual guessing", and its stop rule says "parentheses may change only with a
precedence proof and exact reparse validation".

`RLF-COMMANDS` decided the printer reads the `LosslessSource` projection and never touches
`Lean.Syntax` or an `Environment` (`notes/01-command-printing.md` §3-5). Precedence lives in Lean's
parser tables, and reading those needs an `Environment`. The projection carries none of it:

    structure Node  where kind : Nat; parent : Option Nat; range : SourceRange
    structure Token where node : Nat; leading; start; stop; trailing; info

(`LeanFmt/LosslessSource.lean:64-86`.) There is no precedence, no priority, no category. So the
question is whether this prompt is blocked on a lower-layer piece — the projection would have to start
carrying precedence, which is `ruff-01`/`ruff-02`'s layer, not this one.

## 2. Precedence is not the blocker, because the parser already ran

**The tree *is* the precedence, already resolved.** `a + b * c` does not reach the projection as a
flat token run for the printer to re-associate; it reaches it as a tree in which `b * c` is a subtree
of the `+` node, because the parser applied precedence when it built it. The numbers are what the
parser needed to *decide* the shape. The shape is what a printer needs, and the shape is what the
projection has.

This is exactly what the prompt's own phrase asks for. "Using parser/category information rather than
textual guessing" is satisfied by reading the kinds and the tree — the alternative it forbids is
matching `+` in the bytes and guessing what binds tighter. The projection is parser information by
construction: it is the parser's own output.

**Where precedence numbers would still be needed is where the stop rule forbids going anyway.**
Deciding that `(a + b) * c`'s parentheses are *redundant*, or that removing them is safe, needs the
precedence table and a proof. The stop rule already says parentheses may change only with a precedence
proof and exact reparse validation. This prompt does not have the table, so it does not make that
claim, so it does not touch a parenthesis. Those are the same conclusion reached from two directions,
and the second one is the prompt's own instruction.

## 3. Spacing is the blocker, and it is a different one than expected

The scope above — "re-space and break terms according to their tree" — assumed re-spacing is the easy
half. It is not, and the reason took reading Lean's own formatter to see.

**Lean's formatter derives inter-atom spacing from two sources, and the projection carries neither.**
`Lean/PrettyPrinter/Formatter.lean:366-417` (`pushToken`) is the whole rule:

1. **The atom's own declared string.** `infixl:65 " + " => HAdd.hAdd` (`Init/Notation.lean:284`)
   declares the atom as `" + "` — with a space on each side. `Init/Prelude.lean:5390` says so
   outright: "For example, `" + "` parses `+` and pretty prints it with whitespace on both sides."
   `Term.tuple` declares `", "` (`Lean/Parser/Term.lean:187`), so `(a, b)` and not `(a , b)`.
   `Term.paren` declares a bare `"("` (`:200-201`), so no space. `pushToken` reads that trailing space
   off the atom (`tk.endsWith " "`) and turns it into a `Format.line`.
2. **A lexical minimum-separation rule**, for atoms that declare no spacing: re-lex the token
   concatenated with the word that follows it, and insert a space only if the lexer would consume past
   the token (`:392-399`). Two identifiers always get one (`:387-389`), because `f a` would otherwise
   read as `fa`.

**The projection records the token's *source* text — `+`, `,`, `(` — and never the declared atom.**
So the spacing between two atoms of a term is not recoverable from the tree the way a command shell's
"one space" was: there, the shell is keywords and identifiers, and rule 2 forces a space between any
two of them regardless of what the parser declared. Terms are full of atoms whose spacing is rule 1,
and rule 1 needs the parser table, which needs an `Environment`.

This is not the precedence problem again. Precedence was discharged because the parser already applied
it and left the answer in the tree. Spacing is *not* left in the tree — it is left in the declaration.

## 4. What is citable anyway, and why it is most of the work

A layout may still cite the parser declaration it mirrors, one kind at a time, which is exactly what
`Tree.canonical?` already does for commands. The census (`evidence/02-term-census.txt`, 62 modules of
the frozen sample, 122,011 token-bearing nodes) says how far that reaches, and the answer is better
than §3 suggests, because **the two most common term kinds do not depend on rule 1 at all**:

| kind | count | what the grammar says | cite |
| --- | --- | --- | --- |
| `Term.app` | 11,679 | `trailing_parser:leadPrec:maxPrec many1 argument` — **no atom at all** | `Parser/Term.lean:892` |
| `Term.proj` | 1,448 | `checkNoWsBefore >> "." >> checkNoWsBefore >> (fieldIdx <|> rawIdent)` | `:906-907` |

`app` declares no atom, so rule 1 has nothing to say and rule 2 governs — and rule 2 is not a
preference. `argument := checkWsBefore "expected space" >> checkColGt "expected to be indented" >> …`
(`:885-888`), and `checkWsBefore` "requires that there is some whitespace at this location"
(`Parser/Basic.lean:1180-1184`). **The parser rejects `f a` with the space removed.** So one space is
not this formatter's taste; it is the minimum the grammar accepts, and collapsing `f     a` to `f a`
is a claim about Lean rather than about me.

`proj` is the same fact with the sign flipped: `checkNoWsBefore` **rejects `e . f`**, so zero spaces is
forced. Two rules, opposite directions, both grammar, no table needed.

Those are the two strongest citations available anywhere in this stack — stronger than any command
layout, which cited a shape the parser *permits* rather than one it *requires*.

`proj`'s citation is so strong that it dissolves the work: zero spaces is forced, so every `proj` in
existence already reads `e.f`, and a layout for it would be provably dead code on every input the
parser accepts. It is cited here and deliberately not written.

## 5. Rule 1 is citable after all — when the set of declarations is closed

§3 says the projection cannot carry declared-atom spacing, which reads like a verdict on every atom.
It is not. It is a verdict on *reading the table at runtime*. A layout can still name a specific
declaration and mirror it, and whether that is honest turns on one question: **can the corpus being
formatted change the declaration out from under the layout?**

For a notation, yes — §6. For the bracketed binders, no. `explicitBinder`, `implicitBinder` and
`instBinder` are `leading_parser`s in `Lean/Parser/Term/Basic.lean` of the compiler this stack pins at
v4.32.0. That is a closed set: it changes when the toolchain changes, which is a version bump with a
gate attached, not something a `.lean` file in the input can do. 3,851 nodes of the sample:

| kind | count | grammar | cite |
| --- | --- | --- | --- |
| `Term.explicitBinder` | 2,100 | `"(" >> withoutPosition (many1 binderIdent >> binderType >> optional (binderTactic <|> binderDefault)) >> ")"` | `Term/Basic.lean:206-207` |
| `Term.instBinder` | 951 | `"[" >> withoutPosition (optIdent >> termParser) >> "]"` | `:248-249` |
| `Term.implicitBinder` | 800 | `"{" >> withoutPosition (many1 binderIdent >> binderType) >> "}"` | `:217-218` |

One rule covers all three — **brackets tight, every interior gap one space** — and each half is read
off the grammar. The brackets are declared bare (`"("`, not `" ( "`), and rule 2 adds nothing because
`(x` does not re-lex as one token. The interior gaps are rule 1, each with its own declaration:
`binderType := optional (" : " >> termParser)` (`:181-182`), `binderDefault := " := " >> termParser`
(`:186-187`), `optIdent := optional (atomic (ident >> " : "))` (`:238-239`) — and `many1 binderIdent`,
which is rule 2's unconditional ident-ident space.

**`withoutPosition` is the part worth keeping.** All three wrap their interior in it, and it "runs `p`
without the saved position, meaning that position-checking parsers like `colGt` will have no effect …
usually used by bracketing constructs like `(...)` so that the user can locally override whitespace
sensitivity" (`Parser/Basic.lean:1565-1571`). So §7's constraint — an app's line breaks are
parser-significant — **is switched off by the grammar inside a binder's brackets**. That makes the
binder warrant stronger than `app`'s, which is the reverse of what §4 would predict.

`strictImplicitBinder` is the same citation read backwards, and stays on the conservative path: it is
the one bracketed binder whose interior is *not* wrapped in `withoutPosition` (`:234-236`), so an
enclosing saved position still reaches its contents, and collapsing a run of spaces moves them left —
the quantity `colGt` tests. A rule that has to be argued is worse than none.

**`(x :Nat)` is where this stops being cosmetic.** It parses today: `" : "` is a pretty-printing
string, not a parsing one. So the layout rewrites source that was never wrong, and it is the first
time this formatter has *added* a space rather than collapsed one. That is only defensible because the
space being added is the one the declaration names.

## 5b. `structInst` breaks the rule §5 just established, twice, and both are worth keeping

**`{` is not `{`.** `structInst` declares its braces **spaced** where `implicitBinder` declares them
bare:

    structInst := "{ " >> withoutPosition (… sepByIndent structInstField ", " …) >> " }"  -- Term.lean:351-355
    implicitBinder := "{" >> withoutPosition (many1 binderIdent >> binderType) >> "}"     -- Basic.lean:217-218

So `{a : Nat}` and `{ x := 1 }` are both canonical, and the projection cannot tell the two braces
apart — the source text is `{` in both. Only the *kind* plus the *declaration* distinguishes them.
This is the sharpest available proof that "brackets are tight" is not a rule about brackets: it is a
fact about three specific declarations, and `Spacing.bracketed` is a coincidence that holds for the
kinds it names and would emit `{x := 1}` for this one. It is why that constructor's docstring now
names `structInst` as the counter-example rather than merely listing what it covers.

**And `withoutPosition` does not reach the fields.** `sepByIndent` re-establishes a saved position
*inside* it, and its separator is not just the comma (`Parser/Extra.lean:202-204`):

    sepByIndent p sep psep := withPosition $ sepBy (checkColGe … >> p) sep
      (psep <|> checkColEq … >> checkLinebreakBefore >> pushNone) allowTrailingSep

Two fields are separated by `, ` **or by standing at the same column on a new line**. So this parses:

    { x := 1
      y := 2 }

and re-spacing the gap after `{` moves `x` left while `y` — on the next line, its gap untouched —
does not move. `checkColEq` then fails and the implicit separator stops matching. **A purely
horizontal collapse breaks the parse of a later line**, which is precisely what §7's "collapse, do not
break" was assumed to rule out.

That assumption is not wrong, but it was under-argued, and this is the sharpening: a collapse is safe
when no live column check compares two tokens whose *relative* columns the collapse changes. Same-line
collapses are ordinarily safe because the saved position sits at the construct's start, left of
everything the collapse moves — that is why `app` and the binders are fine. `sepByIndent` saves at the
**first field**, which is inside the construct and to the right of it, and compares it against a token
on another line. Records are therefore deferred on the grammar, not on the abstraction, and would be
deferred under any model of spacing.

## 6. What is not citable, and is therefore deferred

**Operators are notations, and their spacing is rule 1.** The census, by kind:

    1548 «term_≤_»    1059 «term_=_»    641 «term_*_»    638 termℕ
     453 «term¬_»      449 «term_+_»    268 «term_-_»    222 «term_<|_»

13,219 of 122,011 token-bearing nodes (10.8%) are notation or foreign syntax. Some are core —
`infix:50 unicode(" ≤ ", " <= ") => LE.le` (`Init/Notation.lean:375`), `infix:50 " = " => Eq` (`:379`)
— and could in principle each be hardcoded. That is refused, on two grounds. It would be a table of
hundreds of entries mirroring declarations this printer cannot read, so every entry is a claim that
goes stale silently the moment `Init/Notation.lean` changes and no gate here would notice. And it does
not generalize: `Arithcc.«term_≃[_]_»` and `_private.Mathlib.Algebra.Jordan.Basic.0.termL` are in the
same census, declared by the corpus being formatted, and no table can contain them.

So notations take the conservative path and keep their bytes — the same answer `RLF-COMMANDS` reached
for `lemma`, for the same reason, and `RLF-EXTENSIONS` owns it. The census's own `termℕ` (638) is why
this is not detected by looking for guillemets: those are escaping, present only when the notation's
syntax needs them.

§5 is the line between this section and that one, and it is not "core versus not". It is **closed
versus open**. A core notation is declared in `Init/Notation.lean`, which this stack pins just as
firmly as `Term/Basic.lean` — but `notation` is an extension point, and the corpus can add to it, so a
table of core notations would be a table that is silently incomplete rather than merely stale.
`Arithcc.«term_≃[_]_»` is in the census to prove it.

## 7. The margin and `nest` are still open, and `checkColGt` now constrains them

- **The margin is still unset.** `Printer.format` requires `width` rather than defaulting it
  (`RLC-SPEC` §5: it enters cache identity), and no prompt in this stack has picked a value.
- `Doc.hard` emits a newline plus the current indentation, and this printer never nests, so its only
  indentation is column 0 (`startsLine`'s docstring). A term that breaks *inside* an indented command
  cannot use `hard`.
- **`argument`'s `checkColGt "expected to be indented"` means an app's line breaks are
  parser-significant**, the same way `structFields`'s `manyIndent` made field indentation
  parser-significant (`notes/01-command-printing.md`). An argument moved to a column at or left of the
  enclosing saved position stops being an argument. So breaking an app is not available until `nest`
  is, and a re-space that only collapses runs of spaces *within one line* is the part that is safe
  today.

That is what this prompt implements: **collapse, do not break.** `run-printer-sample.sh` is the check
that makes this empirical rather than argued — pass one's output must re-analyze through
`__analyze-exact` before anything else is asserted about it, so a collapse that violated `checkColGt`
would fail as "formatted output does not analyze" rather than pass quietly.

## 7b. The interface, designed twice — and why the shipped one is the under-expressive one

Plan step 2 asks for the interface designed twice when a prompt introduces a new abstraction. This one
introduced `Spacing`, so:

**The shape model (shipped).** `spacingOf : kind → flat | bracketed | keep`, and a separator chosen by
the gap's *position* within the node: `flat` spaces every gap, `bracketed` spaces every gap but the
first and last. Caller knowledge: none — `termDoc` asks only for the kind. Error surface: a wrong
entry mis-spaces one kind, and each entry is a sentence of grammar that a reader can check against the
source. Cache identity: unaffected; the rule is a pure function of the tree.

**The declared-atom model.** A table keyed on (kind, token text) giving the atom's *declared* string,
and a gap computed from the two atoms around it: one space if the left declares a trailing space or
the right declares a leading one, otherwise tight. This is not an invention — it is what `pushToken`
does (`PrettyPrinter/Formatter.lean:366-417`), and tracing `(x : Nat)` through it right-to-left
reproduces the shipped output exactly: `" : "` reaches `:414` and is pushed as `tk.trimAsciiEnd`,
keeping its leading space literally, while `:413`'s `pushLine` supplies the trailing one.

**The atom model is strictly more expressive, and mutation 4 is the proof rather than an argument.**
Lifting `null`s recursively — reaching into `matchAlt`'s `sepBy1 (sepBy1 termParser ", ")` — makes the
shipped model emit `| 0 , m => m`, *a space before the comma*, because `flat` spaces every gap and
`", "` declares only a trailing one. The shape model cannot express "tight on the left, one space on
the right" for a single gap; the atom model gets it for free from the declaration. **So the one-level
null lift is not laziness. It is the boundary of what `flat` can express correctly, and stopping at it
is what keeps the pattern run's bytes safe.**

**But the atom model is not free-standing, and that is the finding.** The gaps it cannot derive from
declared strings — `(` against an ident, an ident against `)` — are the ones `pushToken` sends to
`:393`, which calls `parseToken` to re-lex the concatenation and see whether the lexer runs past the
token. `parseToken` needs `env := ← getEnv` and the token table (`:357-364`). That is an
`Environment`, which is exactly what this printer's architecture excludes
(`notes/01-command-printing.md` §3-5). So the atom model as Lean writes it is **not available at this
layer**; what is available is a hybrid — declared strings where they exist, plus a per-kind hardcoded
rule for the tight gaps, which is what `bracketed` already is.

That hybrid is a real improvement and it is deliberately not built here, because nothing it would
unlock is claimable yet: the two kinds that need per-gap separators are `structInst`'s fields (blocked
on §5b's column check, under any model) and `matchAlt`'s patterns (whose bytes are already safe).
**Building it now would be expressiveness with no claim behind it.** It is the recommended shape for
whoever lands the first `sepBy`-bearing kind, and `Spacing.bracketed`'s "tight" should be read as what
it is: a stand-in for a lexer this printer cannot run, verified per kind by reading the grammar.

## 8. What the corpus says back: the citable part changes nothing

`app_slack=0`, `binder_slack=0` and `match_slack=0` across all 62 modules, over 11,679 applications,
3,851 binders and 121 alternatives, and `reformatted` sits at 12 — the same 12 it was before any of
the three layouts existed (`evidence/01-printer-sample.txt`). **Real Lean already writes `f a`,
`(x : Nat)` and `| 0 => 1`.**

No zero is taken on the corpus's word. A counter that measured nothing would report 0 just as readily,
which is the exact shape `RLF-COMMANDS`'s `misordered=0` turned out to have, so all three are
hand-counted against a written fixture through the same code path — 7, 15 and 22,
`tests/printer/run.sh` — and four mutations confirm the golden pins the rule rather than the output:
`bracketed` made unconditional gives `( x y : Nat )`, the last-gap arithmetic off by one gives
`[Inhabited Nat ]`, dropping the spaces-only guard deletes `/- why -/` from a binder and rejoins the
two lines of an app, and lifting `null`s recursively gives `| 0 , m => m` (§7b).

**This is the fifth time this corpus has answered the same way**, after 0 collapsible members of 260,
`reformatted` unmoved by the member layout, `app_slack=0` and `binder_slack=0`. It is consistent
enough to be a finding rather than a run of luck:

> The part of term formatting that is citable today is the part that changes nothing on code people
> actually wrote. The part that would change something is vertical — and it needs a margin and `nest`,
> which §7 does not have.

That is not an argument against the layouts. It is what makes them safe to have landed: they are the
horizontal skeleton the vertical work will be built on, and they are known not to move a byte of real
code while `nest` is still missing. But it does say where the value in this stack is, and it is not in
`RLF-EXPRESSIONS`'s remaining task lines. **The margin question is the one that matters, and it is
still open.**
