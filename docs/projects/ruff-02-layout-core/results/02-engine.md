# RLC-IMPL — The renderer and comment attachment

`RLC-SPEC` froze a contract (`notes/01-layout-design.md` §4) and this prompt implements it. The
contract is the specification; where implementation contradicted it, the note was corrected rather
than the discrepancy tolerated — §"Decisions changed during execution" records every such case.

## What was built

- **`LeanFmt/Doc.lean`** — the algebra and the renderer. `Doc` with the nine constructors of §4.1,
  `render : Nat → Doc → String × Array Mark`, and the predicates the contract made checkable rather
  than conventional: `Doc.wellFormed` (no newline inside `text`), `Doc.width`, `Doc.lastLine`,
  `Doc.spansLines`, `Doc.size`. The renderer is a bounded work list over `Cmd`, with a `fits` test
  bounded in columns. No `Except`: layout cannot fail (§4.6).
- **`LeanFmt/Comments.lean`** — ownership. `attach` assigns every comment in a `LosslessSource`
  projection to exactly one of `tokens[i].leading`, `tokens[i].trailing`, or `trailer`. `partitions`
  reduces the roadmap's "preserve every comment exactly once" to a decidable check by comparing
  `attach` against `allTrivia`, a deliberately independent second walk.
- **`tests/layout/run.sh`** — attachment over the real parser: this repository's 18 modules, plus a
  generated fixture for the comment positions the repository does not contain.
- `LeanFmtTest.lean` — `testDoc` (unit cases + 400 generated property tests, seed 20260716) and
  `testComments` (three hand-built projections), plus the `attach-report` subcommand `tests/layout`
  drives.

Both modules are in `LeanFmtCore` and deliberately **not** in `LeanFmtCompilerPlugin`: the plugin runs
inside every compilation of every downstream module, and nothing the compiler does needs to render a
document. `lakefile.lean` carries that reasoning at the declaration.

## Commands

```bash
LEAN_NUM_THREADS=1 lake build          # Build completed successfully (32 jobs).
lake exe lean-fmt-tests                # lean-fmt module-artifact tests passed
tests/boundary/run.sh                  # lean-fmt native module and dependency boundary passed
tests/layout/run.sh                    # failures=0        (frozen: evidence/02-attachment.txt)
git diff --check                       # no output
# from /Users/jcreinhold/Code/kan-proofs, with pyyaml available:
uv run --with pyyaml python scripts/check_stack.py docs/projects/ruff-02-layout-core
uv run --with pyyaml python scripts/write_next.py --check docs/projects/ruff-02-layout-core
```

## Measurements

### Comment attachment over real parsed modules (`tests/layout/run.sh`)

`evidence/02-attachment.txt`, 18 modules + `Main.lean`, every one parsed by `lake setup-file` and
projected by `__analyze-exact`:

```
modules_checked=18 comments_attached=59 dangling=0 failures=0
```

`partitions` holds on every module. **Every module reports `trailing=0`** — all 59 comments are
leading. This is genuine, not a bug: `grep -rnE '[^ /-][ ]+--[ ]' --include='*.lean' LeanFmt Main.lean`
returns nothing, so this repository contains no same-line trailing comment at all. Its style puts
comments on their own lines above declarations.

That is a finding about the corpus, and it is why the corpus is not sufficient. See §"Defects found".

### Comment positions, on the real parser (generated fixture)

The setup is borrowed exactly as `tests/lossless/run.sh` borrows one; only the source is generated, so
the parser and the projection are the real ones:

```
positions.lean                     comments=5 leading=1 trailing=3 dangling=1 header_bytes=8 tokens=24
```

Each number is a separate claim about the rule, so each is asserted exactly:

| count | what it pins |
| --- | --- |
| `trailing=3` | `-- trailing`, `/- inline block -/`, and a block comment spanning a newline |
| `leading=1` | a comment past the first newline leads the *next* token — the split itself |
| `dangling=1` | nothing follows the last token to lead it |
| `comments=5` | each owned once; `partitions` independently agrees |

### Renderer complexity

Unchanged from `RLC-SPEC`, which measured the model before it was implemented; `notes/01-layout-design.md`
§4.6 carries the table and `evidence/01-layout-probes.txt` the transcripts. The renderer here is the
bounded work list that note selected. The known hole named there — the fit test is bounded in columns,
not in nodes — is unchanged and still belongs to `RLC-FINAL`, which the roadmap already tasks with
"benchmark adversarial deeply nested documents".

## Decisions changed during execution

1. **`verbatim` was added to the algebra.** §4.1 froze `text` as newline-free and `hard` as the only
   newline — a deliberate departure from `Std.Format`. Implementation showed that departure has a cost
   the note had not paid: a block comment and a multi-line string literal are *single tokens* whose
   text contains newlines and whose interior bytes are not the formatter's to touch. `text` cannot
   carry them without violating its invariant, and `hard` re-indents to the current level, which
   rewrites their content — exactly what `Std.Format` does at `Basic.lean:269-276`, and precisely the
   bug this project exists to avoid. `verbatim s` emits `s` byte-for-byte. `notes/01-layout-design.md`
   §4.1, §4.2, and §4.6 were corrected; the frozen contract has to stay true, and a contract that
   cannot express a block comment is not one.

2. **`chooseNiceTrailStop`'s rule was adopted with a correction.** `RLC-SPEC` established that the
   parser does not split trivia (`Lean.Syntax.updateLeading` is dead code in 4.32; measured
   `verdict=trailing-greedy`), so the formatter must. Lean's rule is `trail.posOf '\n'` — a raw
   character scan. A block comment may contain newlines, so that scan can split *inside* a comment.
   Lean survives it because it only moves a substring boundary and `leading ++ trailing` still
   reconstructs the text. This module does not: it attaches whole comments by range, so a torn comment
   belongs to neither side and is **lost**. `splitPoint` therefore splits at the first newline *outside
   any comment*. This is not a heuristic: a line comment provably cannot contain a newline
   (`LosslessSource.scanTrivia`), so only a block comment can be torn, and the projection already
   records which trivia is which. The mutation test below confirms the correction is load-bearing.

3. **The prompt's "repeated string concatenation" stop rule does not apply to Lean.** The stop section
   names it as a hazard to protect against, which is true in most languages and assumes an immutable
   string. `RLC-SPEC` measured it (`assemble`, n = 200,000 fragments,
   `evidence/01-layout-probes.txt`): `append_ms=1.148 join_ms=3.373 same=true`. Repeated `++` into a
   uniquely-referenced string is not merely linear, it is **three times faster** than accumulating an
   array and joining, because Lean appends in place when the reference is unique. The renderer builds
   its output by `++` deliberately. The stop rule was honored by measuring rather than by assuming, and
   the measurement pointed the other way.

## Defects found

1. **The corpus could not catch the bug `splitPoint` exists to prevent.** All 18 modules pass, and
   `trailing=0` on every one of them — so the corpus never exercises the split. To check this was not
   complacency, `splitPoint` was mutated to Lean's raw rule
   (`return firstNewline source start stop`, discarding the run) and the suite re-run: **all 18 corpus
   modules still passed**, and only the generated fixture failed —

   ```
   uncaught exception: .../positions.lean: attachment did not preserve every comment exactly once
   ```

   Caught by `partitions`, which is the roadmap's stop rule itself rather than a count I chose. The
   fixture was added because of this, not decoratively.

2. **An invented threshold.** `tests/layout/run.sh` first asserted `total_comments -lt 100` — a number
   with no basis, which failed at the corpus's actual 59. Lowering it to make the test pass would have
   made the guard a claim about nothing. The failure was the useful part: it forced the question of
   whether `trailing=0` was real, and the answer (it is, and the corpus is therefore blind to the
   split) produced the fixture in defect 1. The guard is now a floor at 25 against a broken walk, with
   the real assertions on the fixture where they can be exact.

## Files changed

| file | change |
| --- | --- |
| `LeanFmt/Doc.lean` | new — algebra, renderer, source marks |
| `LeanFmt/Comments.lean` | new — leading/trailing/dangling attachment |
| `LeanFmtTest.lean` | `testDoc`, `testComments`, `attach-report` subcommand |
| `tests/layout/run.sh` | new — real-parse corpus + generated position fixture |
| `lakefile.lean` | both modules into `LeanFmtCore` only, with the reason |
| `notes/01-layout-design.md` | §4.1, §4.2, §4.6 — `verbatim`; §4.6 — `render`'s real signature |
| `evidence/02-attachment.txt` | new — frozen corpus and fixture output |

## Remaining uncertainty

- **The fit test's node bound.** Unchanged from §4.6 and owned by `RLC-FINAL`. Every shape measured is
  linear; an adversarial zero-width document is not demonstrated.
- **Units.** Columns are codepoints, ranges are bytes. This is correct for the projection and for
  Lean's own column model, but a codepoint is not a display column for CJK or combining marks. No
  language decision here depends on it yet; the first printer that formats a string literal will.
- **`leading` is handled but never exercised by a real parse.** `nonempty_leading=0` on 4.32 and
  `comments_attached=59` all arriving via trailing runs agree. The code handles a non-empty leading run
  because the projection permits one and a rule that is correct only by accident of one toolchain
  should not also be unable to express the other case — but that path is covered only by the hand-built
  projections in `testComments`, not by any parser output.
- **Comment *placement* is not decided.** This prompt decides who owns each comment. Where an owned
  comment is printed — and whether a trailing comment can force its group to break — is a printer
  question, and `notes/01-layout-design.md` §5 leaves it to the language layer.
