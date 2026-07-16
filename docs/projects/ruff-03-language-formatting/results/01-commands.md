# RLF-COMMANDS — result

The printer exists, reads the `LosslessSource` projection, and is proven lossless on this repository
and on 62 modules of foreign code — every one idempotent, none losing a token or a comment. Module
headers, imports, namespaces, sections, `universe`, `open`, declaration shells, and the shells of
constructors and fields take cited canonical layouts. Everything else round-trips as bytes.

Running it on code nobody wrote for it is what made this prompt worth its length. It found a real
defect (the header layout deleting a blank line), one prompt-named category that was missing precisely
because this corpus contains none of it (`section`), and the fact that the 95% coverage figure this
repository reports is 57.8% on real Lean.

## The task line, category by category

The prompt names nine. Each is either laid out, or deferred with the grammar line that forces it:

| category | state |
| --- | --- |
| module headers | laid out — parsed, since the projection structurally cannot carry them; 62/62 on the sample |
| imports | laid out, inside the header; blank lines the author left are kept |
| namespaces/**sections** | laid out — `namespace`, `end`, `section`, and `universe` |
| attributes | laid out — `declModifiers`' slot goes out verbatim, then `ppDedent ppLine` breaks the line |
| **binders** | **`RLF-EXPRESSIONS`** — `bracketedBinder` is a `Lean.Parser.Term` parser, and bracketed |
| declarations | shell laid out, stopping at the name; the signature and value are terms |
| structures | shell, plus a shell per field and per structure constructor |
| inductives | shell, plus a shell per constructor |
| command comments | doc comments verbatim; `triviaClean` refuses any layout that would drop one |
| golden + idempotence tests | `tests/printer/run.sh`, both fixtures, plus idempotence on all 62 sample modules |

## Commands run

    LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests
    lake exe lean-fmt-tests
    tests/boundary/run.sh
    tests/layout/run.sh
    tests/printer/run.sh
    experiments/run-projection-shape.sh          # -> evidence/01-projection-shape.txt
    experiments/run-printer-sample.sh            # -> evidence/01-printer-sample.txt
    git diff --check
    uv run --with pyyaml python .../check_stack.py docs/projects/ruff-03-language-formatting
    uv run --with pyyaml python .../write_next.py docs/projects/ruff-03-language-formatting --check

**`lake build` with no arguments does not build the test target and reports success anyway.** It
built 32 jobs and said "Build completed successfully" while `LeanFmtTest.lean` did not compile; the
editor's `Unknown identifier` was correct and the standing lesson that LSP diagnostics go stale was
the wrong reading. The prompt's Check says `lake build`; the command that checks anything is the one
that names its targets, and it builds 41 jobs.

**Every guard and layout added here was mutation-tested**, by editing `LeanFmt/Printer.lean`,
rebuilding, and confirming the golden fails: the `section` layout (→ `section     Labeled`), the
`universe` layout (→ `universe     u     v`), the bracket guard (→ `@[ expose ] public section`), the
member `flatGaps` guard, and the header blank-line rule (→ reproduces the mathlib diff exactly). This
is not ceremony. One earlier mutation in this prompt, `true && Id.run do`, was a **no-op** — `true && x`
is `x`, so the guard was never disabled and the test "passed" while proving nothing. A mutation that
does not fail is not evidence; it is a bug in the evidence.

## What was decided

**The printer reads the projection, not `Lean.Syntax` inside the frontend** (`notes/01-command-printing.md`
§3-5). Forced rather than chosen: `ruff-01`'s roadmap already committed to carrying structure "without
exposing Lean frontend objects to product callers", the artifact is already the cache key, and
printing in-frontend would buy free arg order for a median 1.96 s frontend run per file (`RLS-FINAL`)
while giving up that cache.

**The header is the one exception, and it is parsed** (§7). The projection structurally cannot carry
it — `LosslessSource.lean:358`, "neither producer may pass the module header" — and the bytes alone
are not enough, because a lexical scan for `import` cannot tell a keyword from the same word inside a
comment. So `Printer.format` parses the header with `Lean.Parser.parseHeader` and is `IO`. The cost is
nil: both callers were `IO` already, `format` already took the normalized bytes that the header parse
reads, and `normalizedDigest` still binds them. Design A is untouched — its argument was about a
*frontend run* for commands, and a header parse is not one.

**A claim is a region, not a prefix.** `canonical?` returns the prefix ending at the declaration's
name; `Tree.claims` appends one claim per member and `Tree.command` emits verbatim bytes between them.
This is what lets a `structure` lay out its own shell, leave its signature as bytes, and still lay out
each field's shell.

**Members get a shell and no more, and the grammar sets that bound.** Everything past a member's name
is `optDeclSig` or a `bracketedBinder` — a term, `RLF-EXPRESSIONS`'s — and their vertical layout is
not available at all: `structFields` is `manyIndent` = `withPosition ((colGe p)*)`
(`Lean/Parser/Extra.lean:199-201`), so field indentation is parser-significant and re-indenting can
change what parses.

**Binders are named by the task line and are `RLF-EXPRESSIONS`'s, for two independent reasons.**
`bracketedBinder` is defined at `Lean/Parser/Term/Basic.lean:256` — in namespace `Lean.Parser.Term`,
so it is a *term*, and this stack's split gives terms to `RLF-EXPRESSIONS`. It is also, by its own
docstring, bracketed in every one of its four alternatives (`(x y : A)`, `{x y : A}`, `⦃y z : A⦄`,
`[A]`), so the bracket rule below refuses it regardless. Both places binders occur are therefore
untouched and stay bytes: `variable` (`:471-472`, `many1 (ppSpace >> checkColGt >> bracketedBinder)`,
277 in the sample) and a declaration's `optDeclSig`, which is exactly where the shell stops. This is
the same boundary that keeps `def b     : Nat := 1`'s five spaces in the golden.

**A bracket is refused wherever it appears, and that is one rule rather than several omissions.**
`spaceSeparated` is only correct for a flat run of tokens that all want one space between them, and a
bracket is a token of its own — so `open Alpha (a)`, `instance`'s `optNamedPrio`, and `sectionHeader`'s
`@[expose]` are all left as bytes rather than becoming `Foo ( a )`, `( priority := 5 )`, and
`@[ expose ]`. A layout that knows about brackets and separators is a claim this prompt did not make;
making it for one of the three and not the others would have been arbitrary. The cost is measured, not
assumed: it is what the sample's remaining 36 `section` refusals are, and all 36 are already written
the way the layout would write them.

## Measurements

| | this repository | frozen mathlib sample |
| --- | --- | --- |
| modules | 20 | **62**, 0 skipped |
| commands with a cited layout | **415 of 437 (95.0%)** | **1579 of 2734 (57.8%)** |
| module headers laid out | 20 of 20 | **62 of 62** |
| member shells claimed | 54 | 13 |
| modules the printer changed | 0 — it is already canonical | **12** |
| information lost, or failures to converge | — | **0** |

Corpus figures come from `tests/printer/run.sh`, sample figures from
`experiments/run-printer-sample.sh` (`evidence/01-printer-sample.txt`). Both are re-read from the
probes rather than maintained by hand, and the corpus ones move whenever this repository's code
changes, because this repository *is* the corpus — they moved twice during this prompt for no reason
but that.

Structural figures, from `evidence/01-projection-shape.txt`:

| | |
| --- | --- |
| declarations structurally claimable | **358 of 369 (97.0%)** |
| nodes carrying no token at all | **14,405 of 40,027 — 36.0%** |
| …of those, whose parent also has direct token children | **6,161 — 15.4% of all nodes** |

**Two independent measurements of coverage agree exactly.**
`experiments/run-projection-shape.sh` re-implements the structural half of the printer's predicate
against the same projection, in a different language, and reports 358 claimable declarations; the
printer counts `canonical=415 = 358 + 25 namespace + 25 end + 7 open`. The member figures agree the
same way: 46 constructors + 8 structure constructors = the printer's `members=54`.

## The number that matters is 57.8%, not 95%

The corpus figure is a fact about **which commands I happen to write**, and it is the one that would
have been quoted if the printer had never left this repository. Foreign code claims barely half as
much, and a rate that far apart is either ordinary remaining work or a guard refusing what it was
built to claim — a percentage cannot tell those apart. So `printer-unclaimed` reports the syntax
*kind* of every refusal instead, and the answer is not a single story:

| kind | count | whose |
| --- | --- | --- |
| `lemma` | 393 | **not core Lean** — `Mathlib/Tactic/Lemma.lean:20` declares it |
| `variable` | 277 | `RLF-EXPRESSIONS` — `many1 bracketedBinder` |
| `declaration/instance` | 155 | `RLF-COMMANDS` — cited exclusion; see below |
| `in` | 108 | unclaimed — `open X in <cmd>` wraps a command |
| `moduleDoc` | 104 | `RLF-COMMANDS` — needs no layout, which is an answer |
| `section` | 36 | `RLF-COMMANDS` — the bracketed `@[expose]` header; see below |
| `alias`, `attribute`, `notation`, `include`, `macro`, … | ~60 | `RLF-EXTENSIONS`, or bracketed |

**The largest single miss is syntax the compiler does not have.** `lemma` is Mathlib's own, 30% of the
unclaimed commands on its own, and there is no `Lean/Parser/Command.lean` line to cite for it. Its
round-tripping conservatively is the roadmap's "unknown commands must round-trip conservatively"
working, and it is the strongest evidence available that the conservative default is right: a
formatter that guessed at flat runs by shape would have re-spaced 393 commands whose grammar it has
never read.

**The declaration guards do not misfire on foreign code.** `declaration` is one kind over eleven
alternatives, so the bare name cannot distinguish a cited exclusion from a defect; the census reports
the inner shape instead. All 156 refusals are **155 `instance` and 1 `example`** — **zero** `def`,
`theorem`, `structure`, or `inductive`. `instance`'s `declId` is `optional` (`:202-204`) and `example`
has none at all (`:200-201`), so in both cases the shell would be the keyword alone and there is
nothing for a layout to decide. `triviaClean`, `singleLineTokens` and `atLineStart` refuse nothing
across all 62 modules, which is the closest thing to positive evidence available that the declaration
shell's guards are not over-refusing: they were written against a corpus that could never have
exercised them.

## What foreign code added to this prompt's scope

**`section` is named in this prompt's task line and had no layout, and only foreign code could show
that.** `prompts/01-commands.md` says "namespaces/sections". This repository contains **no `section`
command at all**; the sample has 181. The ownership table in `notes/01-command-printing.md` was built,
in its own words, "from what the corpus actually contains", and its `everything else | 0 here` row was
never interrogated — 0 there means "I never wrote one", not "it does not exist".

`section` and `universe` now take flat-run layouts cited against `Command.lean:299-300` and `:531-532`,
which took foreign coverage from 51.7% to 57.8%. Both are keyword-then-identifiers, which is
`spaceSeparated`'s exact shape. The corpus cannot test either, so the wonky fixture carries the whole
proof — and because a bare `section` is one token and therefore byte-identical however it is laid out,
the fixture needs *labelled* and `noncomputable` sections to witness a decision at all.

## The measurement that changed the work

The member-shell probe was built to *retire* the member layout by showing it decides nothing — "a
layout that provably changes nothing on real code is a conclusion to record, not coverage to add".
Its first draft appeared to argue the opposite, reporting 11 fields with "slack". That draft was wrong
twice:

- It measured **the gap between a member's first two tokens**, which for `field : Nat` is the gap
  between `field` and the `:` that opens `optDeclSig` — a term's spacing, which this prompt does not
  own and must not report on. Fixed by identifying the shell structurally (direct token children plus
  the `declModifiers` subtree), which excludes everything a term owns with no list of term kinds to
  keep in sync.
- It counted **any gap over one byte as collapsible**, which scores a doc comment's newline as slack.
  Fixed by reading the gap bytes and splitting horizontal space from line breaks.

Corrected, the answer is **0 collapsible of 260 members**: 195 fields are one-token shells, 11 are
broken by a doc comment, and all 46 constructors and 8 structure constructors are already tight.

**That did not retire the layout, and the reason is the important part.** The corpus is this
repository's own already-formatted code, so "nothing here would change" is a fact about the corpus,
not about the rule — a formatter that leaves `|     first` alone is incomplete regardless of whether
anyone here wrote one. What the figure decides is *what can test the layout*: the corpus cannot, so
`members=` counts the claims and the wonky fixture carries the only proof that a byte changes.

## The check that found a real defect

The corpus and the fixtures are both mine. `experiments/run-printer-sample.sh` runs the printer over
the frozen mathlib sample — foreign Lean, pinned at v4.32.0 by `RLS-FINAL` — and it found the header
layout **deleting a blank line**.

`headerGap` emitted a single `hard` between every pair of import groups, on the reading that the
grammar decides vertical space: `many («import» >> ppLine)` asks for one line each. Mathlib's headers
put a blank line between their `public import`s and their plain `import`s. The layout deleted it. **No
header in this repository has a blank line inside it**, so neither the 20-module corpus nor any
fixture I thought to write could have caught this.

The rule is now: keep a blank line the author left, collapse runs of them to one, and add one only
after `module`. That is settled by this prompt's own stop rule rather than by taste — "sorting is a
separate opt-in fix" defers import *organization*, and grouping imports by blank line is
organization, not spacing. The grammar's `ppLine` says what to emit when *generating* a header from
syntax; it is not a licence to delete what someone wrote. The fixture pins it, and a mutation back to
the old rule reproduces the mathlib diff exactly.

**The harness's own first draft was wrong, and the mistake is worth recording.** It checked byte
identity and reported 7 of 29 modules failing. They were not failing — they were being formatted.
`@[simp] theorem foo` becoming two lines is the declaration layout's attribute rule working as cited.
Byte identity is a claim about *canonical source*, not about the printer, and it is true of this
repository only because this repository is canonical. The properties that hold on arbitrary input are:

1. **Idempotence** — `format(format(x)) = format(x)`. A rule that adds a line every pass cannot fail a
   golden but fails here.
2. **Information preservation** — the output parses back to the same tokens, in the same order, with
   the same text, and to the same comments (`experiments/compare_tokens.py`). This is the real
   losslessness claim, and the one that would catch a guard that wrongly *accepts*.

`printer-roundtrip` keeps the identity assertion behind `checkIdentity`, true for the corpus and false
for the sample.

## Uncertainty, and what is deliberately not done

**22 of 437 commands stay conservative, and none is an unread grammar.**

- **`instance` (11) — excluded, and the exclusion is now measured to cost nothing here.** Its `declId`
  is `optional (ppSpace >> declId)` (`Lean/Parser/Command.lean:202-204`), so an anonymous instance's
  shell is the keyword alone, and `optNamedPrio` is bracketed, so one space between its tokens gives
  `( priority := 5 )`. `evidence/01-projection-shape.txt` measures that **all 11 are anonymous** —
  one-token shells, with no gap any layout could collapse. A *named* instance would have something to
  re-space, and none occurs here; that layout is a separate claim needing its own fixture.
- **`moduleDoc` (9) — needs no layout, which is an answer rather than a gap.** It is
  `"/-!" >> commentBody >> ppLine` (`:60-61`): an opener and a body of prose, with nothing in it the
  formatter may re-space. The conservative path *is* its layout.
- **`registerOption` (1), `initialize` (1)** — conservative, grammar not read.

**Brackets are refused wherever they appear, and that is one rule rather than three omissions.**
`spaceSeparated` puts one space between every pair of tokens, which is right for a flat run and wrong
the moment a bracket is a token of its own. Three shapes hit it, and all three keep their bytes:
`open Alpha (a)` and `open Alpha renaming a → myA` (`:728-731`), `instance`'s `optNamedPrio`
(`:64-65`), and `sectionHeader`'s `optional ("@[" >> nonReservedSymbol "expose" >> "] ")` (`:288-292`).
A layout that knows about brackets and separators is a claim this prompt has not made, and making it
for one of them and not the others would be arbitrary.

That last one is the whole of the sample's remaining `section` refusals: **all 36 are
`@[expose] public section`**, mathlib v4.32.0's module-system idiom, which occurs in 36 of the 62
modules. The guard is refusing exactly what it was built to refuse — verified by a mutation that
disables it and emits `@[ expose ] public section`. Claiming it is cheap and available (the
declaration shell already emits its attribute slot verbatim and could here too), and it would decide
nothing measurable: mathlib writes that header the way the layout would write it.

**Three header guards, one of which no test reaches.** Two are pinned by fixtures that fail the golden
by name (`  import     Lean.Data.Name` for the line-start guard, `import /- why -/ Lean.Data.Options`
for the comment guard). The third — a newline inside a header leaf — is unreachable through this
harness: the lexer accepts `import «a⏎b»` (`Lean/Parser/Basic.lean:986`, `takeUntilFn
isIdEndEscape`), but such a module must exist on disk to elaborate. It is defensive and documented as
such rather than left to be discovered.

**`Doc`'s break behaviour is still not exercised by real source.** Every layout so far is a flat run
of tokens one space apart, so no `group`, `line`, or `nest` reaches the engine from a real module.
`RLC-FINAL`'s standing caveat narrows from "nothing consumes the layout stack" to "nothing yet asks it
to break a line". `RLF-EXPRESSIONS` is where that changes.

**Corpus figures drift silently, and no gate catches it.** They are quoted in prose in
`LeanFmt/Printer.lean`'s module docstring, `notes/01-command-printing.md` §2 and §7, and
`state/current.md`, while the evidence file is regenerated by a probe nothing compares against them.
This prompt found them stale, and then moved them **twice more while fixing them**: adding `headerGap`
took the corpus from 39,836 nodes to 39,869, and adding the `section` layout took it to 40,027, both
purely because this repository is its own corpus. One of the stale sentences was also wrong when
written — it paired "84.7% that carry tokens" with the ambiguous-placement figure rather than the
empty-node one, and the right number is 64.0%. Re-running the probe after touching `LeanFmt/` is part
of the work, not a tidy-up; a gate that diffed the quoted figures against the evidence would be better
and does not exist.

## Files changed

| file | what |
| --- | --- |
| `LeanFmt/Printer.lean` | the printer: tree view, extents, layouts, claims, header |
| `LeanFmtTest.lean` | `printer-roundtrip`, `printer-report`, `printer-format`, `printer-unclaimed` |
| `tests/printer/run.sh` | corpus round-trip, floors, hostile shapes, goldens, idempotence |
| `experiments/run-projection-shape.sh` | projection shape, ownership census, layout reach |
| `experiments/run-printer-sample.sh` | the printer over the frozen mathlib sample |
| `experiments/compare_tokens.py` | tokens and comments preserved across a formatting pass |
| `docs/.../notes/01-command-printing.md` | the interface designed twice, and the decision |
| `docs/.../evidence/01-projection-shape.txt` | probe output |
| `docs/.../evidence/01-printer-sample.txt` | frozen-sample output |
