---
kind: state
first_unresolved: 01-commands
---

# Current state

`RLF-COMMANDS` is **in progress**: the printer skeleton is live and proven lossless, and **391 of the
corpus's 419 commands take a cited canonical layout** — `namespace` (25), `end` (25), and the shell of
341 of 352 declarations. Its external prerequisite stack `ruff-02-layout-core` is verified and its live
implementation still matches recorded state.

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
| 01-commands | RLF-COMMANDS | planned | — |
| 02-expressions | RLF-EXPRESSIONS | planned | RLF-COMMANDS |
| 03-tactics | RLF-TACTICS | planned | RLF-EXPRESSIONS |
| 04-extensions | RLF-EXTENSIONS | planned | RLF-TACTICS |
| 05-corpus | RLF-FINAL | planned | RLF-EXTENSIONS |

## Known evidence

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
- **A `structure`'s fields and an `inductive`'s constructors are left as bytes, and they are this
  prompt's to claim.** The shell stops at the name, so `structure Str     where` re-spaces its keyword
  and keeps its fields exactly. An earlier reading of state called their ownership unsettled; the
  prompt settles it — `01-commands.md`'s task names "declarations, structures, inductives" outright,
  so `structFields` (`:257-262`) and `ctor` (`:210-212`) belong to `RLF-COMMANDS`, not to
  `RLF-EXPRESSIONS`. They are outstanding work, not an open question.
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
  **403 commands in 7 distinct kinds** and not one is an `import`: the module header is not in the
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
- **The header's cost is an `IO` boundary on `format`, and the boundary test does not forbid it.**
  `tests/boundary/run.sh` constrains the *plugin's* import cone; `LeanFmt.Printer` is deliberately
  outside `LeanFmtCompilerPlugin`'s globs, and `LeanFmtCore` already carries `LeanFmt.LosslessSource`,
  whose `ofSource` takes `Array Lean.Syntax`. So importing `Lean.Parser.Module` in the printer breaks
  no recorded rule, and `notes/01-command-printing.md`'s Design A is not contradicted either: its
  argument was that printing *commands* in-frontend costs a median 1.96 s frontend run, and parsing a
  header is not a frontend run. **This is the next piece of work and it is the prompt's own
  requirement** — the task names "module headers, imports" and the Stop rules name ordered imports.
- **Coverage is counted by the printer, because byte identity cannot see it and the corpus cannot
  either.** Every module round-trips exactly and would still round-trip exactly if every guard refused
  every command — the printer would fall back to bytes and be the identity function it was before any
  layout existed. This repository also writes its declarations the way the layout writes them, so even
  a layout that runs changes nothing here. `printer-roundtrip` therefore reports `canonical=`, the
  commands actually laid out, and `tests/printer/run.sh` floors the corpus total: **391 of 419**. The
  golden fixture pins *what* the layouts produce; this pins *that* they run, on real code, at scale.
- **Two independent measurements of coverage agree exactly, and keep agreeing as it grows.**
  `experiments/run-projection-shape.sh` re-implements the structural half of the printer's predicate in
  Python against the same projection and finds 341 of 352 declarations claimable; the printer, in Lean,
  counts 391 = 341 + 25 `namespace` + 25 `end`. So on this corpus every structurally-claimable
  declaration also passes the runtime guards the probe cannot model (clean trivia, newline-free flat
  run, column 0). The probe over-counts by construction and says so; `canonical=` is the honest figure.
- **That 391 commands take the layout and all 20 modules stay byte-identical is what proves the shell
  is a prefix.** A shell that ran past the name, or stopped short, would duplicate or drop bytes on
  real code. Nothing asserts prefix-ness directly; the round-trip is the assertion.
- **A coverage number inferred from the wrong population was off by a factor of seven, and the fix
  redirected the work.** The empty-node census reports 318 empty `declModifiers`, which reads like
  "almost every declaration carries no modifiers" — but `declModifiers` is also on every structure
  *field* (`declModifiers true`, the inline form, `Lean/Parser/Command.lean:114`), so those 318 were
  never counting declarations. Counting the printer's actual predicate showed modifiers, not shapes,
  were the blocker on 262 of 345 declarations, which is why `declModifiers` was laid out next and why
  coverage went 45 → 271. The estimate would have sent this to `structure` and `inductive` instead.
- **The ownership table is measured, and it is shorter than the prompt's list.**
  `declaration` 345, `namespace` 25, `end` 25, `moduleDoc` 8, `open` 7, `registerOption` 1,
  `initialize` 1 (`evidence/01-projection-shape.txt`, 412 commands). Structures, inductives, attributes, and binders
  are **not** commands — the grammar nests them inside `declaration`, under `declModifiers` and the
  `def`/`theorem`/`structure`/`inductive` choice — so they are reached by dispatching within it. A
  declaration's *value* is a term, which `RLF-EXPRESSIONS` owns; `RLF-COMMANDS` lays out the shell and
  leaves the value conservative, which the skeleton supports directly because one command's `Doc` can
  mix canonical structure with `verbatim` subtrees.
- **The printer skeleton is lossless on real parser output, and the test proves it by mutation.**
  `LeanFmt/Printer.lean` renders header + command extents + `#exit` tail; with every kind on the
  conservative path it is the identity on accepted source. `tests/printer/run.sh`:
  `modules_checked=20 commands=403 failures=0`, at margins 0, 1, 40, 80, 120, and 1000 — the margin
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
  Measured by `experiments/run-projection-shape.sh` over all 20 modules of this repository, 34,844
  nodes (`evidence/01-projection-shape.txt`): `pre_order_contiguity_violations=0` and
  `nonempty_node_children_out_of_source_order=0`, so a tree view over the projection is
  reconstructable and its child order agrees with the source. But **12,797 nodes (36.7%) carry no
  token at all** — they are *absent* syntax, and `collect` gives them range `(0,0)` because a node's
  range is the hull of the leaves beneath it and there are none. Of those, **5,345 (15.3% of all
  nodes)** sit under a parent that also has direct token children, so nothing in the projection says
  where among its siblings an absent slot belongs. This is not a gap the projection introduced:
  `Lean.Syntax` has no position for an empty node either. A printer therefore cannot reconstruct arg
  order from ranges and must dispatch on kind — which it must do anyway, since canonical layout is
  per-construct by definition.
- **The conservative fallback is the only path that rests on no grammar claim.** Empty nodes
  contribute no bytes, so re-emitting a subtree's tokens in source order with their trivia is
  unaffected by all 5,345 ambiguous placements. The roadmap's "unknown commands must round-trip
  conservatively" and this measurement point the same way.
- **"Are children in arg order" is unaskable of the projection, and asking it produced a vacuous
  pass.** The projection stores only `parent`, so index order is the only order it retains and the
  question compares index order against itself. The probe's first draft asked it and reported
  `misordered=0` — a number no input could have contradicted. Arg order is guaranteed by `collect`'s
  code, not by its output. The replacement check compares index order against *byte* order, and was
  mutation-tested: reversing child order on the real corpus raises it to 4,324.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- **`RLF-COMMANDS` is not met, and the gap is now mostly named work rather than unread grammar.**
  398 of 419 commands have a layout. Outstanding, in the prompt's own words: **module headers and
  imports** (not a command at all — see below), **structures and inductives** past their shell
  (`structFields`, `ctor`), and `results/01-commands.md`. The 21 commands still conservative are
  `instance` (11), `moduleDoc` (8), `registerOption` (1), and `initialize` (1).
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
  run would emit `( priority := 5 )`. Each needs its own fixture. How many of the 11 here are
  anonymous is **not measured**, and that number decides whether the keyword-ended shell is worth
  having.
- **`moduleDoc` (8) and `open` (7) are still conservative, and `open` is deliberate.** `openDecl` has
  bracketed forms (`open Foo (a b)`, `open Foo hiding a`) where one-space-between-tokens would be
  wrong, so it needs its own citation rather than an assumption.
- **A declaration's signature and value are untouched, by decision and not by omission.** Both are
  terms and `RLF-EXPRESSIONS` owns them (`notes/01-command-printing.md` §7), so the shell layout stops
  at the `declId`'s last token and everything after it is bytes. `Tree.canonical?` returns *the last
  token its layout claimed* precisely to make that expressible; a layout claiming the whole command
  would have re-spaced the signature, which is the failure the split exists to prevent.
- **`Doc`'s break behaviour is still exercised only by `ruff-02`'s own fixtures.** The printer
  consumes `Doc`, but only through `verbatim`, `text`, `cat`, and `empty` — no `group`, `line`, or
  `nest` reaches it from real source yet, because `namespace`/`end` are one-liners with nothing to
  break. `RLC-FINAL`'s "`call-args` is my model of a Lean call, not a Lean call" stands until a layout
  lands that can actually exceed the margin.
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
