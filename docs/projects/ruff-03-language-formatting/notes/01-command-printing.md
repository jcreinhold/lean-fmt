# RLF-COMMANDS — where the printer reads its tree from

## 1. The question

`ruff-02-layout-core` delivered a `Doc` algebra and a renderer, and nothing consumes them. This stack
must produce a `Doc` from an accepted Lean module. The prompt introduces a new abstraction — the
printer — so its interface is designed twice here before anything is built.

The question is not "what does a `def` look like". It is **what the printer reads**, because that
choice fixes the error surface, the cache identity, and whether the printer can ask the parser
anything at all.

## 2. What the boundary actually is (measured, before deciding)

`LosslessSource` carries `kinds : Array String`, `nodes : Array Node` where
`Node = {kind, parent : Option Nat, range}`, and `tokens : Array Token` where `Token` names its
immediate parent node. There is **no children array and no arg index**.

Measured by `experiments/run-projection-shape.sh` over every module of this repository — 21 modules,
40,027 nodes, real parser output — by reconstructing the tree from the projection and testing each
property (`evidence/01-projection-shape.txt`):

| property | result |
| --- | --- |
| subtree of node *j* is a contiguous index range | **0 violations** |
| among a parent's token-bearing node-children, index order agrees with byte order | **0 violations** |
| nodes whose subtree contains no token at all | **14,405 — 36.0%** |
| …of those, whose parent also has direct token children | **6,161 — 15.4% of all nodes** |

The first two are not luck. `LosslessSource.collect` pushes a node's placeholder at
`build.nodes.size` *before* folding its args left to right, so children of one parent necessarily have
strictly increasing indices in arg order, and a pre-order walk necessarily makes each subtree
contiguous. The measurement confirms the reading of the code rather than substituting for it.

**Row 2 is deliberately not "are children in arg order", and the distinction cost a defect to find.**
The projection stores only `parent`, so index order is the *only* order it retains: asking whether
children are in arg order compares index order against itself and returns 0 for every possible input.
The first draft of the probe asked exactly that and reported a reassuring `misordered = 0` that no
input could have contradicted. Arg order is guaranteed by `collect`'s code and is unobservable in its
output. Byte order *is* observable, and index order disagreeing with it is what a fold over args in the
wrong order would actually produce — so that is what row 2 measures. Both hard checks were then
mutation-tested rather than trusted: a synthetic tree whose child precedes its parent, and one with a
foreign node inside a parent's span, each raise the contiguity count; reversing child order on the real
corpus raises row 2 into the thousands (**4,962** on the corpus as it stood that run), which is also
the number of parents whose child order the check genuinely exercises.

The last two decide the interface:

- **More than a third of the tree is absent syntax.** `def f : Nat := 0` alone carries seven empty
  `null` children under `declModifiers` — the docComment, attributes, visibility, `noncomputable`,
  `unsafe`, and `partial`/`nonrec` slots. Across the corpus, 12,849 of the 14,405 empty nodes are
  anonymous `null`; the named remainder is exactly what the name suggests — `letConfig` (480),
  `declModifiers` (323), `Termination.suffix` (292), `optEllipsis` (139), `optDeclSig` (101),
  `optDeriving` (28). These nodes are the *absence* of syntax, recorded positionally.
- **An empty node has range `(0,0)`**, because `collect` computes a node's range as the hull of the
  leaves beneath it and there are none: `span.getD {start := 0, stop := 0}`. This is not information
  the projection dropped — `Lean.Syntax` has none either. An empty `null` node genuinely has no
  position, and `Syntax.getPos?` returns `none` for it.

**Therefore arg order cannot be recovered from positions.** For 6,161 of 40,027 nodes, an empty
node-child sits among direct token-children of the same parent and nothing in the projection says
whether it came before or after them. That is a seventh of the tree, not an edge case, and no amount
of care with ranges fixes it: the information is absent from `Lean.Syntax` upward.

This single fact drives everything below.

## 3. Design A — print from the projection

The printer takes `LosslessSource` + the normalized source and dispatches on `kinds[node.kind]`, a
`String`. It knows the shape of each kind it supports because that shape is written into the printer,
cited against Lean's parser definitions.

- **Caller knowledge.** The caller has the artifact already: the facet produces it, the cache stores
  it, and `Application` fetches it. Formatting needs no new capability and no frontend run.
- **Invariants hidden.** Parent-pointer and pre-order reconstruction stay inside the printer's tree
  view. Callers never see `Lean.Syntax`, which is `ruff-01`'s contract verbatim: "carries byte ranges
  and parent/child structure **without exposing Lean frontend objects to product callers**".
- **Error surface.** An unknown kind is an ordinary case, not an error — it falls back to the
  conservative token round-trip (§5). Layout cannot fail (`RLC-FINAL`), so the printer's whole error
  surface is decode failure, which is already an ordinary miss.
- **Exactness.** The projection is byte-exact by `RLS-FINAL` and `validFor` binds it to its source.
- **Cache identity.** Unchanged. The artifact is already the cache key; formatting is a pure function
  of it plus the margin (configuration, which enters identity — `RLC-SPEC` §5).
- **Critical path.** No frontend run, no environment, no elaboration. Format is artifact → `Doc` →
  string.
- **Memory.** Bounded by the artifact, whose largest instance in `RLS-FINAL`'s frozen sample is
  660,805 B (`Analysis/Normed/Module/Multilinear/Basic.lean`, from a 63,690 B source).

**The cost, stated plainly:** the printer cannot ask Lean what a kind's arguments are. There is no
`Environment` out here. Every supported kind's shape is a hardcoded claim about a parser the printer
cannot query, and it must be sourced by citation and pinned by a golden test, or it is exactly the
"textual guessing" the roadmap forbids one layer up.

## 4. Design B — print inside the exact frontend

The printer runs where the module was parsed, holding real `Lean.Syntax` and a live `Environment`.

- **Caller knowledge.** Formatting now requires an exact frontend run per file. `LeanFmt.Project`
  owns exact setup and one shared no-build graph; this makes formatting a second consumer of it.
- **Invariants hidden.** Fewer: `Syntax` has `getArgs`, so arg order is *free* and the 954 ambiguous
  nodes vanish. The `Environment` can in principle be asked about parser descriptions rather than
  told.
- **Error surface.** Grows to include everything a frontend run can fail at, for an operation that is
  otherwise total.
- **Exactness.** Equal — same parser, same normalized coordinates.
- **Cache identity.** Worse. The artifact stops being sufficient for formatting, so either formatting
  is uncacheable or a second key appears beside the one `RLS-FINAL` verified.
- **Critical path.** A frontend run per format. `RLS-FINAL` measured analysis at median 1.96 s and max
  15.5 s per module on the frozen sample. That is the whole cost of formatting, against ~0 for A.
- **Memory.** A live `Environment` per file, against a 660 KB artifact.

**And it contradicts a decision already made.** `ruff-01`'s completion contract commits to carrying
structure "without exposing Lean frontend objects to product callers", and `AGENTS.md` states the
application "consumes that registered facet through one private no-build Lake operation". Design B
does not extend that architecture; it reopens it.

## 5. Decision

**Design A.** The printer reads the projection.

The decision rests on two things and not on preference:

1. **Cache identity and the critical path.** The artifact exists, is verified byte-exact, and is
   already the cache key. B pays a 1.96 s median frontend run per file to recover an arg index, and
   gives up the cache to do it.
2. **The architecture already chose.** `ruff-01` froze "no frontend objects to product callers" and
   built the facet around it. B is not a printer decision; it is a reversal of `RLS-SPEC`, and it
   would be made here by a prompt that does not own it.

B's one real advantage — free arg order — is worth less than it looks, because **the printer is
grammar-aware under either design**. Canonical layout is per-construct by definition: deciding that a
`def` breaks before `:=` and that an `import` never breaks means knowing you are looking at a `def` and
an `import`. A printer that knew only "node with four children" could not choose a layout at all, so
the grammar shape has to be in the printer regardless of whether arg order is free. What A gives up is
therefore not layout knowledge but the ability to *check* its grammar claims against the parser at
runtime. A golden fixture checks them at build time instead, which is where a claim about a fixed
grammar belongs.

## 6. What this forces on the printer

- **Node-children are read in arg order, never sorted by range.** Arg order is guaranteed by
  `collect`; range order is wrong for 15.4% of nodes and *silently* wrong, which is worse.
- **Every supported kind's shape is a citation.** The shape goes in the printer with the parser
  declaration it mirrors, and a golden fixture pins it. An uncited shape is an unsourced claim.
- **The conservative fallback reads tokens, not the tree.** This is the load-bearing consequence of
  §2: empty nodes contribute no bytes, so a printer that re-emits a subtree's tokens in source order
  with their trivia is unaffected by all 6,161 ambiguous placements. Unknown syntax round-trips
  through the one path that does not depend on the information the projection lacks. The roadmap's
  "unknown commands must round-trip conservatively" and this measurement point the same way — the
  fallback is not a concession, it is the only path whose correctness does not rest on a grammar
  claim.

## 7. The ownership table

The roadmap requires "every supported parser category has an explicit ownership table and formatter
fallback". The table is built from what the corpus actually contains, not from what I remember Lean
having: `experiments/run-projection-shape.sh` censuses command kinds, and this repository yields
**437 commands in 7 distinct kinds** (`evidence/01-projection-shape.txt`; the counts below move as the
project grows and are re-read from the probe rather than maintained by hand).

| kind | count | owner |
| --- | --- | --- |
| `Lean.Parser.Command.declaration` | 369 | `RLF-COMMANDS` — the shell and its members; see below |
| `Lean.Parser.Command.namespace` | 25 | `RLF-COMMANDS` |
| `Lean.Parser.Command.end` | 25 | `RLF-COMMANDS` |
| `Lean.Parser.Command.moduleDoc` | 9 | `RLF-COMMANDS` |
| `Lean.Parser.Command.open` | 7 | `RLF-COMMANDS` |
| `Lean.Option.registerOption` | 1 | conservative fallback |
| `Lean.Parser.Command.initialize` | 1 | conservative fallback |
| everything else | 0 here | conservative fallback |

**This table is built from the corpus, and the corpus is not Lean.** Every count above is a fact about
code I wrote, and "everything else | 0 here" is the line that should have been suspicious: it is not
evidence that nothing else exists, only that I never wrote it. `experiments/run-printer-sample.sh` runs
the same census over the frozen mathlib sample — 2734 commands against this repository's 437 — and the
kinds it refuses are a different list:

| kind | count | owner |
| --- | --- | --- |
| `lemma` | 393 | `RLF-EXTENSIONS` — **not core Lean**; `Mathlib/Tactic/Lemma.lean:20` declares it |
| `Lean.Parser.Command.variable` | 277 | `RLF-EXPRESSIONS` — `many1 bracketedBinder` (`:471-472`) |
| `Lean.Parser.Command.section` | 181 | `RLF-COMMANDS` — **claimed now**; `:299-300` |
| `Lean.Parser.Command.declaration` | 156 | `RLF-COMMANDS` — a runtime guard refused these |
| `Lean.Parser.Command.in` | 108 | unclaimed — `open X in <cmd>` wraps another command |
| `Lean.Parser.Command.moduleDoc` | 104 | `RLF-COMMANDS` — needs no layout; see below |
| `Lean.Parser.Command.universe` | 20 | `RLF-COMMANDS` — **claimed now**; `:531-532` |
| `alias`, `attribute`, `notation`, `include`, `macro`, … | ~60 | `RLF-EXTENSIONS` or bracketed |

Two things fall out of it that the corpus could not have said:

**`section` is named by this prompt's task line, and this corpus has none of them.** "namespaces/
sections" is in `prompts/01-commands.md`; the census above shows 0 in 437 commands here and 181 in the
sample. It and `universe` are now claimed — both are flat runs of a keyword and identifiers, which is
`spaceSeparated`'s exact shape. The one hazard is `sectionHeader`'s first slot (`:288-292`):
`optional ("@[" >> nonReservedSymbol "expose" >> "] ")` is *bracketed*, and `@[` and `]` are separate
tokens, so a flat run over a command holding them emits `@[ expose ]`. Its other three slots are lone
keyword atoms and flat-run correctly, which matters because `noncomputable section` is the header shape
that actually occurs. So the layout refuses the bracket and claims the rest — the same call `open`
makes for `openOnly`.

**The biggest miss is syntax the compiler does not have.** `lemma` is Mathlib's, declared at
`Mathlib/Tactic/Lemma.lean:20`, and it is 30% of the sample's unclaimed commands on its own. Nothing
in this stack should claim it: the printer cites `Lean/Parser/Command.lean` for every layout it has,
and there is no such citation to make for `lemma`. It round-tripping conservatively **is** the
roadmap's "unknown commands must round-trip conservatively" doing its job, and it is the clearest
evidence available that the conservative default is the right one — a formatter that guessed at flat
runs by shape would have re-spaced 393 commands it has never read the grammar of.

Three facts the census settles, each of which changes the work:

**Imports are not commands, and the projection cannot carry them.** No `import` appears above because
the module header is not in the token stream at all: `headerStop` is 54 bytes on `LeanFmt/Rules.lean`,
covering `module` and both `import` lines, and the projection records the header as *bytes* with no
node and no token. This is deliberate and one layer down —
`LosslessSource.ofSource` (`LosslessSource.lean:358`) states it outright: "**Neither producer may pass
the module header — a module linter never receives it** — so the header is recorded as the prefix
before the first leaf's leading trivia, which is a position both producers can actually see." The
plugin producer is a module linter and Lean never hands it the header, so a schema carrying header
syntax could not be produced by both mandated producers, which is the same argument `RLS-SPEC` used to
keep raw bytes out of identity.

This does **not** block the prompt's "canonical layouts for module headers, imports", and it is not a
missing lower-layer piece. **Corrected:** an earlier draft of this section argued from
`parseHeader`'s *signature* — `(inputCtx : InputContext) : IO (TSyntax ``Module.header ×
ModuleParserState × MessageLog)`, taking "**no `Environment`**" — and concluded the header was
self-contained. The signature does not say that. Its body opens with `let dummyEnv ←
mkEmptyEnvironment` and builds its token table from that plus `Module.updateTokens`
(`Lean/Parser/Module.lean:75-79`), which is the whole reason it is `IO`. So it does need an
environment; it makes an empty one. The conclusion survives and is firmer than the argument that
reached it: **no *frontend* environment is required**, and an empty one is available anywhere in `IO`.

**Decided (this was §8's open question).** `format` acquires the `IO` boundary; no pure header parse
exists to find. Three things make the cost nil rather than merely acceptable:

- Both of `format`'s callers are `IO` already.
- It widens nothing. `format` already takes `normalized`, because every conservative path slices bytes
  out of it; the header parse reads those same bytes, so what a formatted module depends on is
  unchanged and the artifact's digest still binds all of it.
- **Design A is not contradicted.** §5's argument against reading `Lean.Syntax` was that printing
  *commands* in-frontend costs a median 1.96 s frontend run per file and gives up the cache. A header
  parse is not a frontend run and does not touch the cache. The printer reads `Lean.Syntax` in exactly
  one place, for the one region §7 shows the projection *structurally cannot* carry — and the
  alternative there is not "read the projection" but "lexically guess at `import`", which cannot tell
  a keyword from the same word in a comment and is the textual guessing the roadmap forbids.

**Structures, inductives, attributes, and binders are not commands.** The prompt lists them beside
declarations, but the grammar nests them: `declaration` wraps `declModifiers` (docstring, attributes,
visibility, `noncomputable`, `unsafe`, `partial`) and then one of `def`/`theorem`/`structure`/
`inductive`/`abbrev`/`instance`. They are reached by dispatching *within* `declaration`, and the
ownership table has one row for all of them.

**A declaration's value is a term, and terms are not this prompt's.** `RLF-EXPRESSIONS` owns them.
`RLF-COMMANDS` therefore lays out the declaration *shell* — modifiers, signature, the `:=` — and leaves
the value on the conservative path until the expression prompt claims it. That is not a gap to
apologize for; it is the decomposition the work order already chose, and the skeleton supports it
directly because a command's Doc can mix canonical structure with `verbatim` subtrees.

**Structures and inductives past their shell: the members get a shell of their own, and no more.** The
prompt's task names structures and inductives, and the declaration shell stops at the declaration's
name, so their members were the outstanding half. Their grammar decides how much of them is available
(`Lean/Parser/Command.lean:210-212`, `:257-258`, `:265-266`):

- **Everything past the member's name is a term.** `ctor` and `structSimpleBinder` both end in
  `optDeclSig`, and `structCtor` puts `many (ppSpace >> Term.bracketedBinder)` before its `" :: "`.
  `RLF-EXPRESSIONS` owns all of it, so the claim ends at the name. That also keeps the claim one
  *contiguous* run, which is all a `Claim` can be — `structCtor`'s `::` is unreachable for the same
  reason it is unowned.
- **Their vertical layout is not this printer's to choose, and may not even be legal.** `structFields`
  is `manyIndent`, i.e. `withPosition ((colGe p)*)` (`Lean/Parser/Extra.lean:199-201`), so a field's
  indentation is parser-significant: re-indenting can change what parses. Laying members out
  vertically would also need `Doc.nest`, which this printer never emits, and an indent width, which
  this stack has deliberately left unset alongside the margin.
- **So the member layout is the shell as a flat run**, and its guard follows from `hard` indenting to
  nothing: a shell whose gaps cross a line cannot be reproduced, because the break would land the name
  at column 0. `flatGaps` refuses those. This is why `structSimpleBinder`'s doc-commented fields are
  refused while `ctor`'s documented constructors are laid out — a `ctor`'s doc comment sits under
  `optional`, outside the shell, so it keeps its bytes and its break without the shell reproducing it;
  a field's doc comment is inside its `declModifiers`, hence inside the shell.

**What the measurement changed.** The probe was built to answer "would this layout decide anything?",
expecting the answer to be no — a layout that provably changes nothing is a conclusion to record, not
coverage to add. Its first draft said 11 fields had "slack" and appeared to argue for building it. That
draft was wrong twice over: it measured the gap between a member's *first two tokens*, which for
`field : Nat` is the gap before `optDeclSig`'s `:` — a term's spacing, which this prompt must not
report on — and it counted any gap over one byte, which scores a doc comment's newline as collapsible
slack. Corrected, the answer is **0 collapsible members out of 260**: 195 fields are one-token shells,
11 are doc-broken, and all 46 constructors and 8 structure constructors are already tight.

That is not an argument for skipping the layout, and the distinction matters. The corpus is this
repository's own already-formatted code, so "nothing here would change" is a fact about the corpus, not
about the rule: a formatter that leaves `|     first` alone is incomplete regardless. What the figure
decides is *what can test it* — the corpus cannot, so `members=` counts the claims and the wonky
fixture is the only evidence the layout changes a byte. Both are asserted in `tests/printer/run.sh`.

**What the corpus could not have told me, and what fixed it.** Everything above is measured on this
repository's own modules, and that corpus has a weakness no care removes: I wrote it, so it is already
formatted the way the layouts format it. The frozen mathlib sample is not, and running the printer
over it (`experiments/run-printer-sample.sh`, `evidence/01-printer-sample.txt`) found a defect the
corpus and every fixture had missed — **the header layout deleted a blank line**.

`headerGap` emitted a single `hard` between every pair of import groups, on the reading that "the
grammar decides vertical space": `many («import» >> ppLine)` asks for one line each. Mathlib's headers
put a blank line between their `public import`s and their plain `import`s, and the layout deleted it.
No header in this repository has a blank line inside it, so nothing here could notice.

The rule is now: a blank line the author left is kept, runs of them collapse to one, and the only
blank line the layout *adds* is after `module`. The correction is not a taste call — this prompt's
stop rules say "sorting is a separate opt-in fix", and grouping imports by blank line is import
*organization*, not spacing. Deleting that grouping reorganizes the header as surely as reordering it
would. The grammar's `ppLine` says what to emit when *generating* a header from syntax; it is not a
licence to delete what someone wrote.

**The first draft of that harness was itself wrong, and in an instructive way.** It checked byte
identity — format, then diff against the input — and reported 7 of 29 modules failing. They were not
failing; they were being formatted. `@[simp] theorem foo` becoming two lines is the declaration
layout's attribute rule working exactly as cited. Byte identity is a claim about *canonical source*,
not about the printer, and it is only true of this repository because this repository is canonical. On
arbitrary input the properties that hold are **idempotence** (`format(format(x)) = format(x)`) and
**information preservation** (the output parses back to the same tokens and the same comments), and
those are what the sample now checks. The identity assertion stays where it is true, on the corpus.

## 8. What this note does not decide

- The canonical layout of any construct. `RLF-COMMANDS` decides commands; terms, tactics, and
  extensions belong to later prompts and are named here only where they constrain the interface.
- Import sorting. The prompt is explicit that ordered import semantics are preserved and sorting is a
  separate opt-in fix. This *was* stronger than a policy while the printer had no header syntax to
  reorder; §7 has since decided it parses the header, so the protection is now the ordinary kind — the
  walk keeps source order because it is written to, and a mutation that reverses it fails the golden.
- The margin. It is configuration and enters cache identity (`RLC-SPEC` §5); this note does not pick a
  number. `Printer.format` therefore requires `width` rather than defaulting it.

## 9. Risks

- **A hardcoded grammar shape can be wrong or go stale.** The mitigation is citation plus golden
  fixtures plus the idempotence and round-trip checks the roadmap requires, not care.
- **The conservative fallback can be over-used.** A kind that falls back silently looks like success
  and prints the old bytes. `RLF-FINAL` runs a generated syntax-kind inventory for exactly this
  reason; until then, coverage must be reported rather than assumed.
