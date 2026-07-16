---
kind: state
first_unresolved: 02-expressions
---

# Current state

`RLF-COMMANDS` is **verified** (`results/01-commands.md`): the printer is live and proven lossless on
this repository *and* on 62 modules of foreign Lean, **415 of the corpus's 437 commands take a cited
canonical layout** — `namespace` (25), `end` (25), `open` (7), and the shell of 358 of 369
declarations — **all 20 module headers take theirs**, and **54 constructor and field shells** are
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
corpus. They are re-read from `experiments/run-projection-shape.sh` rather than maintained by hand;
when they are quoted in prose (`LeanFmt/Printer.lean`'s module docstring, `notes/01-command-printing.md`
§2 and §7) they drift silently, and no gate catches it. Re-running the probe after touching `LeanFmt/`
is part of the work, not an optional tidy-up.

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
| 02-expressions | RLF-EXPRESSIONS | planned | RLF-COMMANDS |
| 03-tactics | RLF-TACTICS | planned | RLF-EXPRESSIONS |
| 04-extensions | RLF-EXTENSIONS | planned | RLF-TACTICS |
| 05-corpus | RLF-FINAL | planned | RLF-EXTENSIONS |

## Known evidence

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
  rule.** `evidence/01-projection-shape.txt`: **0 collapsible of 260 members** — 195 fields are
  one-token shells (an unmodified field is just its name, with no gap to collapse), 11 are doc-broken,
  and all 46 constructors and 8 structure constructors are already tight. The probe was built expecting
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
  commands actually laid out, and `tests/printer/run.sh` floors the corpus total: **415 of 437**, and `members=` the shells claimed
  inside them, floored at 50 (**54**) because `canonical=` cannot see them — a command counts once
  whether it claims one region or six. The
  header gets the same treatment for the same reason, but as an exact count rather than a floor
  (`headers_canonical=20` of 20): a module has exactly one header, and the layout declines per group
  and per gap, so there is no header shape here it should refuse outright. The golden fixtures pin
  *what* the layouts produce; these pin *that* they run, on real code, at scale.
- **Two independent measurements of coverage agree exactly, and keep agreeing as it grows.**
  `experiments/run-projection-shape.sh` re-implements the structural half of the printer's predicate in
  Python against the same projection and finds 350 of 361 declarations claimable; the printer, in Lean,
  counts 407 = 350 + 25 `namespace` + 25 `end` + 7 `open`. So on this corpus every
  structurally-claimable declaration also passes the runtime guards the probe cannot model (clean
  trivia, newline-free flat run, column 0). The probe over-counts by construction and says so;
  `canonical=` is the honest figure.
- **That 407 commands take the layout and all 20 modules stay byte-identical is what proves the shell
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
