# RLF-EXPRESSIONS — results

Design and citations: `notes/02-expressions.md`. Evidence: `evidence/02-term-census.txt` (the census
that decided the scope), `evidence/01-printer-sample.txt` (the 62-module frozen sample).

## What the task line asked for, and what each item got

| item | outcome | why |
| --- | --- | --- |
| applications | **laid out** (`Term.app`, 11,679) | `argument`'s `checkWsBefore` — the parser *rejects* `f a` without the space (`Term.lean:885-892`) |
| binders | **laid out** (`explicitBinder` 2,100, `instBinder` 951, `implicitBinder` 800) | brackets declared bare, interior atoms declare their spaces; `withoutPosition` kills the column checks (`Term/Basic.lean:206-249`) |
| matches | **laid out** (`matchAlt`, 121) | `"| "` and `darrow := " => "` declare every gap the alternative owns (`Term.lean:265-270`, `:99`) |
| projections | **answered — nothing to build** (`Term.proj`, 1,448) | `checkNoWsBefore` rejects `e . f`, so every proj already reads `e.f`; a layout would be dead code on every accepted input |
| patterns | **answered — nothing to build** | Lean has no pattern syntax: `matchAlt` uses `termParser` (`:268`), and 0 of 600 census kinds are patterns. The `app` layout already runs inside them |
| strings, numerals | **answered — nothing to build** | tokens reach the output only via `.verbatim (tokenSpanText …)`; no path exists from a layout to a token's interior |
| syntax quotations | **answered — already reached, and safe** | every quotation wraps its contents in `withoutPosition` (`Command.lean:20-21`, `:50-51`; `Term.lean:1028-1029`, `:1124`, `:1126`) |
| antiquotations | **answered — conservative by construction** | no `spacingOf` entry, so an antiquot is an opaque part and `$x` cannot be split |
| operators | **deferred, cited** (13,219 notation nodes, 10.8%) | notations are an **open** set the corpus extends (`Arithcc.«term_≃[_]_»`); a core-only table would be silently incomplete, not merely stale. `RLF-EXTENSIONS`'s |
| records | **deferred, cited** (`structInst` 61) | `sepByIndent` makes a shared column *be* the field separator, so a horizontal collapse breaks a later line — under **any** model of spacing (`notes` §5b) |
| precedence | **discharged, not implemented** | the parser already applied it; the tree *is* the resolved precedence. Changing a parenthesis needs the table and is what the stop rule forbids anyway |

## Commands

    LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests   # 41 jobs; bare `lake build` does NOT build the tests
    ./tests/printer/run.sh                                  # failures=0
    ./experiments/run-printer-sample.sh                     # 62 modules, frozen sample
    ./experiments/run-term-census.sh                        # evidence/02-term-census.txt

All nine suites green: boundary, check, compiler, layout, lossless, modes, printer, scale, service.

## Measurements

    modules_analyzed=62 skipped=0 failures=0 reformatted=12
    commands=2734 canonical=1579 members=13 headers_canonical=62 app_slack=0 binder_slack=0 match_slack=0

**Every layout this prompt added changes nothing on 62 modules of foreign Lean**, over 11,679
applications, 3,851 binders and 121 alternatives. `reformatted` is 12 — the same 12 as before any of
them existed. Real Lean already writes `f a`, `(x : Nat)` and `| 0 => 1`.

That is the fifth time this corpus has answered this way (0 collapsible of 260 members, `reformatted`
unmoved by the member layout, then the three zeros here), and `notes/02-expressions.md` §8 stops
treating it as luck: **the citable part of term formatting is the part that changes nothing on code
people actually wrote; the part that would change something is vertical.**

No zero is believed on the corpus's word, because a broken counter reports 0 just as readily — which
is exactly what `RLF-COMMANDS`'s `misordered=0` turned out to be. Each is hand-counted against the
wonky fixture through the same code path: **7, 15 and 22**.

## Decisions changed during execution

- **The prompt's premise was wrong, and finding that out was most of the work.** It asks for
  "precedence-aware" formatting; precedence turned out never to be the blocker, because the parser
  already resolved it into the tree. **Spacing** is the blocker, and it lives in the atom's declared
  string, which the projection does not carry (`notes` §2-3).
- **"The projection cannot carry declared-atom spacing" was too strong**, and the binders are the
  counter-example. It is a verdict on *querying the table at runtime*, not on naming a declaration.
  The honest test is **closed versus open**, not core versus not: a `leading_parser` in the pinned
  compiler cannot be changed by the corpus being formatted; a `notation` can (§5).
- **`strictImplicitBinder`'s exclusion had a false reason and was rewritten.** The recorded reason was
  that its ASCII `{{` is two atoms that `bracketed` would space apart. That is wrong — `group` is
  `groupKind`, not `nullKind`, so `liftedParts` never lifts it. The real reason is better: it is the
  one bracketed binder whose interior is **not** wrapped in `withoutPosition` (§5).
- **"Collapse, do not break" was under-argued**, and `structInst` is the case that showed it. A purely
  horizontal collapse *can* break a later line, when a live column check compares two tokens whose
  relative columns the collapse changes. `sepByIndent` saves its position at the first field — inside
  the construct, to the right of it — and a shared column is a legal field separator (§5b).
  **`RLF-EXTENSIONS` found this rule under-applied as well as under-argued**: §5b cleared `app` by
  checking only the app's own saved position, and `evidence/04-coleq-break.txt` breaks a `theorem` with
  it. The rule was never wrong; the exemption was. See `results/04-extensions.md` and `Tree.mayCollapse`.
- **`matchAlt`'s collapse was withdrawn by `RLF-EXTENSIONS`, and this document's `match_slack` claims
  should be read as scope rather than as behavior.** The guard that makes the term layer
  parse-preserving is kind-free of necessity — a custom `syntax` can declare `withPosition` and `colEq`
  (`Lean/Parser.lean:39-42, 50`), so no census of kinds can be finished — and it therefore refuses every
  collapse inside a multi-line command, which is every match alternative there is. The grammar reading
  in §5 stands; what is gone is the printer's ability to act on it. `match_slack=0` on the sample, so
  the withdrawal costs nothing measurable and is visible only in `tests/printer/run.sh`'s golden.
- **The design-twice conclusion was corrected by a mutation.** See below.

## The interface, designed twice (Plan step 2)

The shipped **shape model** (`spacingOf : kind → flat | bracketed | keep`, separator chosen by the
gap's position) against a **declared-atom model** (a table keyed on (kind, token text), each gap
computed from the adjacent atoms' declared strings — which is what `pushToken` does).

The atom model is strictly more expressive, and **mutation 4 proves it rather than arguing it**:
lifting `null`s recursively reaches `matchAlt`'s `sepBy1 (sepBy1 termParser ", ")` and emits
`| 0 , m => m`, a space *before* the comma, because `flat` spaces every gap while `", "` declares only
a trailing one. The shape model cannot say "tight left, one space right" for a single gap. So the
one-level `null` lift is not a shortcut — it is the boundary of what `flat` can express correctly, and
stopping there is what keeps the pattern run's bytes safe.

But the atom model is not free-standing at this layer. The gaps it cannot derive from declared strings
— a bracket against an ident — are the ones `pushToken:393` hands to `parseToken`, which needs
`env := ← getEnv` and the token table (`Formatter.lean:357-364`). That is an `Environment`, which the
architecture excludes (`notes/01-command-printing.md` §3-5). What is available is a **hybrid**:
declared strings where they exist, plus a per-kind hardcoded rule for the tight gaps — which is what
`bracketed` already is, and `bracketed`'s "tight" should be read as a stand-in for a lexer this
printer cannot run, verified per kind by reading the grammar.

**The hybrid is deliberately not built**, because everything it would unlock is blocked for other
reasons: `structInst`'s fields on §5b's column check under any model, and `matchAlt`'s patterns are
already safe by keeping their bytes. It would be expressiveness with no claim behind it. It is the
recommended shape for whoever lands the first `sepBy`-bearing kind.

An earlier commit message (`8a078db`) states this conclusion too strongly — "the atom model is not
available at this layer", full stop. `8a823b5` corrects it: it is unavailable exactly where a gap
cannot be derived from a declared string, which is narrower and is why the hybrid exists.

## Non-vacuity: four mutations

The corpus cannot test these layouts — this repository is already canonical, so they run and decide
nothing, and `printer-roundtrip` would pass with every guard refusing. The wonky fixture and its
golden are the whole evidence, so the golden is checked by breaking the code:

| mutation | result | what it pins |
| --- | --- | --- |
| `bracketed` → always `some " "` | `( x y : Nat )`, **and 18 of this repository's 20 modules fail** | the rule, and that real code depends on it |
| `index + 2 == count` → `index + 1` | `[Inhabited Nat ]`, `(x y : Nat )` | the last-gap arithmetic; `instBinder`'s single interior gap is both first and last |
| drop `gapDoc`'s spaces-only test | `/- why -/` **deleted** from an app *and* from inside a binder's brackets; `id`/`11` rejoined across lines; **12 of 20 modules fail** | the guard, in three independent places |
| lift `null`s recursively | `| 0 , m => m`; `match_slack` 22 → 26 | the one-level lift, and the shape model's expressiveness limit |

The middle two are **invisible to the corpus round-trip** and rest entirely on the fixture.

## Remaining uncertainty

- **The margin is still unset**, and it is where the remaining value in this stack is. `Printer.format`
  requires `width` rather than defaulting it (`RLC-SPEC` §5: it enters cache identity), and no prompt
  in this stack has picked a value. Not this prompt's task line, so it stays open — but §8 says
  plainly that horizontal formatting is done and it changed nothing.
- **This printer never emits `nest`, so `hard` indents to column 0** (`startsLine`), and no layout here
  can break a line inside an indented command. Every rule this prompt added is horizontal for that
  reason. The gap is in the *printer*, not the engine: `Doc.nest` exists (`LeanFmt/Doc.lean:74`) and is
  honored by both `fits` (`:179`) and `go` (`:209`). So this is a call the printer has never made,
  which is a much smaller thing than a capability the stack lacks — `RLF-TACTICS` is where it gets made.
- **The `bracketed` trap is documented, not removed.** A fourth kind added by noticing it has brackets
  would be wrong; `structInst` is named in the constructor's docstring as the counter-example. The
  hybrid model above is what actually removes it.
- **`Term.quot` is 5 nodes and `dynamicQuot` is 2.** The claim that the layout inside a quotation is
  safe rests on `withoutPosition` in the grammar, which is sound; the empirical backing is 7 nodes.
- **Corpus-figure drift is systemic**: this repository *is* the printer corpus, so every code change
  moves the figures quoted in prose, and no gate catches it. Re-read from the generators rather than
  hand-maintained.
