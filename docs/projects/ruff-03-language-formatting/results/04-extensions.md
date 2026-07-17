# RLF-EXTENSIONS — results

## What shipped

The extension boundary was already in place as two closed matches with conservative defaults
(`Tree.canonical? | _ => none`, `spacingOf | _ => .keep`), and this prompt added no registry to it.
What it added is the guard that makes the default's **recursion** sound: `Tree.mayCollapse`, which
refuses every whitespace collapse outside a one-line command.

The prompt's four named cases all pass and are pinned in `tests/printer/run.sh`
(`--- the extension boundary ---`). The finding is that they were never the hard part.

## The headline: the term layer was not parse-preserving, and now is

Two breaks, both found here, both recorded in `evidence/04-coleq-break.txt` with input and output
re-analyzed:

| # | fixture | printer emitted | verdict |
|---|---|---|---|
| 1 | `theorem tA : (id     True) := by skip` / `trivial` | `unexpected identifier; expected command` | fixed by `882a076` |
| 2 | custom `withPosition(term:max colEq term:max)` | `expected checkColEq` | **defeated `882a076`**; fixed by `b9034ea` |

Break 1 falsifies a sentence in `notes/02-expressions.md` §5b, which cleared `app` by checking only the
app's *own* saved position. The one that breaks belongs to the `by` block, opened to the app's right on
the same line. Break 2 falsifies the first fix: a user's `withPosition` compiles to **no node**, so a
census of cross-line nodes opening to a gap's right cannot see it. `tacticSeq1Indented` was caught in
break 1 only because it happens to be its own node.

Both corrections are recorded in `notes/02-expressions.md` §5b and `results/02-expressions.md`.

## Exact commands

Build (`lake build` with no arguments does not build `LeanFmtTest`):

    LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests        # 41 jobs

Reproducing either break — `$app`/`$tests` from `lake -q query lean-fmt --text` and
`lake -q query lean-fmt-tests --text`, `$work/setup.json` from `lake setup-file`:

    lake env "$app"   __analyze-exact "$work/setup.json" "$work/tbl.lean" tbl.lean 8589934592 >tbl.json
    lake env "$tests" printer-format  "$work/tbl.json"   "$work/tbl.lean" 100              >tbl.out
    lake env "$app"   __analyze-exact "$work/setup.json" "$work/tbl.out"  tblout.lean 8589934592

`__analyze-exact` emits `{"artifact": …, "diagnostics": []}` on a clean parse and **omits `artifact`
entirely** when the module has parse errors. That absence is the assertion; a byte comparison alone
would have compared text that was never Lean.

Gates:

    for s in boundary check compiler layout lossless modes printer scale service; do bash tests/$s/run.sh; done
    bash experiments/run-printer-sample.sh
    git diff --check
    uv run --with pyyaml python3 …/check_stack.py docs/projects/ruff-03-language-formatting
    uv run --with pyyaml python3 …/write_next.py --check docs/projects/ruff-03-language-formatting

## Measurements

Frozen sample, before and after the guard — byte-identical:

    modules_analyzed=62 skipped=0 failures=0 reformatted=12
    commands=2734 canonical=1579 members=13 headers_canonical=62
    app_slack=0 binder_slack=0 match_slack=0

All three slack counters are 0, so **the term layer's collapse fires zero times on real Lean** and
every restriction of it is free on the sample. `gapDoc` hands any gap containing a newline to
`.verbatim`, so the layer's whole effect is narrowing a same-line run of spaces — and mathlib contains
no such run. The guard is therefore carried by fixtures, not by the corpus, which is why the fixtures
assert the break directly.

Fixture-visible price, `wonky`'s golden:

    unguarded                     47 lines rewritten
    per-gap node census (882a076) 47 lines rewritten
    mayCollapse (b9034ea)         39 lines rewritten   <- the 8 are match alternatives, one per line

## Mutations

Every mutation was applied to `LeanFmt/Printer.lean`, rebuilt, and run against `tests/printer/run.sh`.

Against `882a076` (the node census, since superseded):

| mutation | result |
|---|---|
| guard disabled | caught |
| anchor neutered (`respectsLines` always true) | caught |
| guard refuses everything | caught |
| sentinel removed | caught |

Against `b9034ea` (`mayCollapse`):

| mutation | result |
|---|---|
| guard disabled (`raw.all (· == ' ')` alone) | caught |
| guard refuses all (`false &&`) | caught |
| single-line test off (sentinel alone) | caught |
| sentinel off (single-line test alone) | caught |
| `span.extent` instead of the command's tokens | caught |

The last one is not hypothetical — it is the bug I wrote. An extent runs to the end of the last token's
*trailing* run, so it reaches the next command's line for every command followed by a blank line.
Reading it answers "multi-line" for a one-line `def`, switches the whole layer off, and every byte
assertion that only checks *refusal* still passes. `tB` and `dC` — which must still collapse — are what
catch it.

## Decisions changed during execution

- **The guard moved from per-claim to per-gap and then to per-command.** Per-claim refused `wonky`'s
  `|     0     =>` / `1`, which is safe (`many1Indent` saves at the first `|`, left of both gaps).
  Per-gap restored it and was then defeated by break 2, which no node census can see. Per-command is
  the first version that is *complete*, and it costs the cross-line `matchAlt` collapse back again —
  this time for a reason that is proved rather than incidental.
- **"`matchAlt` is now unreachable on every input" was written, and is false.** It was asserted from the
  golden's diff without being measured. `def inlineAlts : Nat → Nat | 0 => 1 | n => n` is a one-line
  command and still collapses; `inline.lean` now holds it. What was withdrawn is "matchAlt spread
  across lines". Corrected in `tests/printer/run.sh`, `notes/02-expressions.md` and
  `results/02-expressions.md`.
- **The clearance table was designed and refused** (`notes/04-extensions.md` §5). A cross-line ancestor
  is harmless iff its `withPosition` wraps the whole node — true of `matchAlts`, false of `termTbl` —
  so the exact rule is a list of such kinds with refusal as the default. Refused because it buys a
  collapse that fires zero times, because every entry is a claim about `Lean/Parser/Term.lean` that goes
  stale silently (§6's objection to the notation table), and because a table can only ever widen what
  gets collapsed.
- **The first break fixture was invalid and the error was mine, not Lean's.** `` `(tbl $a $x $y) ``
  does not compile: `$a $x` parses as one application, and with `colEq` between `$x` and `$y` the
  pattern needs them column-aligned. `term:max` plus a two-line quotation fixes both. The
  `unexpected token ')'` I first read as a fixture parse failure was the *macro pattern* failing.

## Remaining uncertainty

- `mayCollapse` is sound against Lean's column checks, which the parser aliases (`Lean/Parser.lean:39-42,
  50`) make the only mechanism a `syntax` command has for making a column load-bearing. It is not proved
  against a parser this stack has not read. The `.keep` default is the mitigation.
- The cross-line collapse is refused, not proved impossible. §5 records the exact rule that would
  recover it and the grounds for not writing it.
- `evidence/04-coleq-break.txt`'s second half was appended after `882a076` landed, so it documents a
  guard that no longer exists. That is deliberate: it is the record of why the shipped guard asks about
  the command rather than about nodes, and deleting it would leave the current design looking
  arbitrary.
