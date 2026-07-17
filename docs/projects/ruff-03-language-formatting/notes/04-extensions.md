# RLF-EXTENSIONS: the registration boundary, and what a lossless default has to survive

## 1. The boundary already exists, and it is two closed matches

The prompt asks for "the extension registration boundary for known syntax kinds and a lossless default
for custom syntax". Both are already in `LeanFmt/Printer.lean`, and neither is a registry:

    Tree.canonical? : … → Option (Nat × Doc)     -- commands;  ends `| _ => none`
    spacingOf       : String → Spacing           -- terms;     ends `| _ => .keep`

A kind is "registered" iff it is named in one of those two matches, which is to say iff this stack has
read its declaration in the compiler source and written the citation down. Everything else — a
`notation` from `Init/Notation.lean`, a `syntax` from the corpus being formatted, a macro quotation —
falls to the default and keeps its bytes. There is no table to maintain, no registration call, and no
way for a caller to add one, which is what `RLF-EXTENSIONS`' "a formatter extension cannot gain
application lifecycle authority" stop rule asks for.

**The default is not a wall, and that is the whole design.** `termDoc` recurses through a `.keep` kind
rather than emitting its subtree wholesale (`Printer.lean`, `termDoc`'s docstring), and `termClaims`'
`continue` on `.keep` deliberately does **not** set `skipUntil`. So an `app` inside a custom notation
inside a `paren` is still found and still laid out, while every byte no layout claimed survives. That
is what makes the fallback *lossless* rather than *lazy*: laziness would be refusing the subtree, and
it would cost every built-in construct that happens to sit under a corpus-declared head.

`tests/printer/run.sh`'s `--- the extension boundary ---` holds all four cases the task line names:

| case | fixture | what it pins |
|---|---|---|
| syntax declared earlier in the same file | `syntax:max "twice " term : term` + `macro_rules` + `twice (id     1)` | the walk descends; `id     1` → `id 1`; `twice ` keeps its byte |
| scoped notation | `scoped notation:65 a " oplus " b => (a, b)` | same, and the `notation` command itself is untouched |
| macro quotations | ``def quoted (stx : Term) : MacroM Term := `($stx + $stx)`` | quotation bytes survive, antiquotations included |
| mixed built-in/custom trees | `twice (id     (1 + 2))` | a built-in tree under a custom head is still laid out |

## 2. The reason this prompt is not about registration at all

Descending into a kind you cannot read is only sound if the collapse you perform there cannot change
what the parser does. That was assumed, and it is false, and finding out cost this prompt its whole
budget. Two breaks, both in `evidence/04-coleq-break.txt`, both re-analyzed in both directions.

### 2a. The built-in break

    theorem tA : (id     True) := by skip
                                     trivial

parses. This printer emitted

    theorem tA : (id True) := by skip
                                     trivial

which does not: `unexpected identifier; expected command`. Collapsing the app moved `skip` four columns
left; `trivial` did not move; `sepByIndent`'s separator is
`psep <|> checkColEq … >> checkLinebreakBefore >> pushNone` (`Lean/Parser/Extra.lean:202-208`), so it
stopped matching and `trivial` fell out of the block.

`notes/02-expressions.md` §5b had already stated the governing rule — *a collapse is safe when no live
column check compares two tokens whose relative columns the collapse changes* — and then cleared `app`
under it:

> Same-line collapses are ordinarily safe because the saved position sits at the construct's start,
> left of everything the collapse moves — that is why `app` and the binders are fine.

That sentence asks only about **the collapsing construct's own** saved position. The one that breaks
belongs to a `sepByIndent` opened to the app's **right on the same line**, by the `by` block, which
saves at its first tactic. The rule was never wrong. The exemption was, and it was an exemption granted
by a *kind* — `app` — for a hazard that has nothing to do with kinds.

### 2b. The custom break, which is why the fix is not a census

The first fix refused a gap when a cross-line **node** opened at-or-right of it. It caught 2a. It is
still wrong:

    syntax:max "tbl " term:max ppSpace withPosition(term:max colEq term:max) : term
    macro_rules
      | `(tbl $a $x
                 $y) => `(($a, $x, $y))

    def broken : Nat × Nat × Nat := tbl (id     1) 2
                                                   3

parses, and that guard emitted `expected checkColEq`. A user's `withPosition` **compiles to no node at
all**. The only node here is `termTbl_____`, and it opens at `tbl` — *left* of the gap inside
`(id     1)` — so a census of nodes opening to the gap's right looks straight past it. `sepByIndent`
was caught in 2a only because `tacticSeq1Indented` happens to be its own node opening at the first
tactic. That was luck, not a rule.

This is not an exotic fixture. `register_parser_alias "colGt" checkColGt`, `"colGe"`, `"colEq"`,
`"lineEq"` and `withPosition` are all registered aliases (`Lean/Parser.lean:39-42, 50`), so any
`syntax` command in the corpus being formatted can put a live column check anywhere it likes, and no
census of *this* tree can promise to find it. That is §6's argument about notations, arriving one layer
down: an answer phrased as a property of kinds is one this printer cannot finish writing.

## 3. What is actually true, and it is a proof rather than a table

Two facts, and the second follows from the first.

**Same-line pairs cannot flip.** A collapse never reorders tokens and never closes a gap below one
space. So for two tokens on the collapse's own line, `colGt` stays true and `colEq` stays false however
far either slides. Tokens on every other line do not move at all. The entire hazard is therefore *a
saved position that moves while what it is compared against does not*, and that needs a check whose two
ends straddle a line break.

**A one-line command has no such check.** Say a check compares `P`, right of some gap and on its line,
against `Q` on another line. The smallest node holding both spans a line break; it lies inside the
command; so the command spans one too. Contrapositive: if the command is one line, no gap in it can
move a column any other line measures.

That is `Tree.mayCollapse`, and it asks nothing about kinds:

    single-line command  ∧  nothing non-blank after it on its line   →  collapse
    otherwise                                                        →  keep the bytes

The second clause is about the *next* command, not this one: two commands can share a line, and the
first one's collapse moves the second one's first token, which no fact about the first command's own
tokens can see. `dE`/`tF` in `tests/printer/run.sh` holds it.

**Read from the command's tokens, not its `extent`.** An extent runs to the end of the last token's
*trailing* run (`Printer.lean`, the extent docstring), so it reaches the next command's line for every
command with a blank line after it — nearly all of them. Reading `extent` here answers "multi-line" for
a one-line `def`, turns the entire layer off, and looks like it works. `tB` and `dC` catch it; the
mutation is in `results/04-extensions.md`.

## 4. The price, stated as a number and not as a shrug

`mayCollapse` refuses every collapse inside a multi-line command. On the frozen sample that is free,
and the freedom is measured rather than hoped for: `app_slack=0`, `binder_slack=0`, `match_slack=0`
across all 62 modules, `reformatted` unchanged at 12. The term layer's only effect is narrowing a
same-line run of spaces to the separator its grammar declares — `gapDoc` hands any gap containing a
newline to `.verbatim` — and **real Lean contains no such run**. The layer fires zero times on real
code under either rule.

What it costs is fixture-visible: `wonky`'s golden goes from 47 rewritten lines to 39, and all eight
are match alternatives written one per line.

**`matchAlt` is not dead, and the difference matters.** An earlier revision of this correction said
`spacingOf`'s `matchAlt` entry was "unreachable on every input". That was written without measuring it
and is false — `def inlineAlts : Nat → Nat | 0 => 1 | n => n` is a one-line command, `mayCollapse` is
true, and the layout runs. `inline.lean` in `tests/printer/run.sh` now holds it. What was withdrawn is
"matchAlt spread across lines", not "matchAlt".

## 5. The table that would buy the cross-line case back, and why it is refused

The refusal in §4 is conservative, and the shape of the exact answer is known. A cross-line **ancestor**
`N` of a gap is harmless iff every position `N`'s grammar saves is `N`'s own first token — which is left
of the gap by construction, since the gap lies between two of `N`'s tokens, so it cannot move.
`matchAlts := withPosition $ many1Indent (ppLine >> matchAlt …)` (`Term.lean:279-280`) wraps its
`withPosition` around the whole node and saves at the first `|`: harmless. `termTbl` wraps it around a
*part* and saves at `2`, to the gap's right: fatal. So the clearance is a list of kinds whose
`withPosition` covers the whole node, with refusal as the default.

It is not built, on three grounds, in increasing order of weight:

1. **It buys nothing measurable.** All three slack counters are 0 on the sample. It would recover a
   collapse that fires zero times on real Lean.
2. **Every entry goes stale silently.** Each is a claim about `Lean/Parser/Term.lean` that no gate here
   would notice breaking — which is the exact objection `notes/02-expressions.md` §6 used to refuse
   hardcoding the notations, and `results/02-expressions.md` used to refuse the hybrid atom model
   ("expressiveness with no claim behind it").
3. **The default it protects is the one that is already right.** Refusing an unread kind is what makes
   the custom case sound. A table only ever widens what gets collapsed, so every entry is a new way to
   emit Lean that does not parse, in exchange for whitespace nobody writes.

It is the recommended shape for whoever needs the cross-line collapse, and nobody needs it yet.

## 6. What is left uncertain

`mayCollapse` is proved sound against *Lean's* column checks, which is the only mechanism `RLC-SPEC`
§4.7 and the parser aliases give a `syntax` command for making a column load-bearing. It is not proved
against a parser this stack has not read. That is the same residue every prompt in this stack carries,
and the default is the mitigation: an unread kind's bytes are kept.

The `wonky` golden now records eight lines of *refused* collapse. A future reader should not read those
as the layout's opinion about how match alternatives ought to look — they are the guard declining, and
§5 is the reason.
