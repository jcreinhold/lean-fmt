# RLF-NOTATION — results

## What shipped

The first output bytes phase 2 changes, and the first layer to read a fact the lossless projection
cannot carry. `ruff-05b` captures each notation's declared, untrimmed atom strings from the live
`Environment` (`" + "`, `" * "`, `" ⊗"`) into the `v4` `ModuleArtifact`; this prompt is the printer
*consuming* them, so `1+2` becomes `1 + 2`, `8  +  9` collapses to `8 + 9`, and the corpus notation
`3⊗4` becomes `3 ⊗4`. Five golden lines in `tests/printer/run.sh` (`--- notation spacing ---`), each a
separate claim, plus conservative-fallback, parse-preservation, and idempotence gates.

The printer gains **no `Environment` and no frontend import**. It reads one immutable field —
`ArtifactModel`'s `SemanticProjection.notations`, threaded into `Tree` as a
`Std.HashMap String (Array String)` keyed by syntax kind — and nothing more. The boundary gate proves
it, and the boundary import set widened by exactly one already-in-library module (`LeanFmt.ArtifactModel`,
the same pure data the printer already round-trips).

## The headline: the separator is per-gap, and the `⊗` case is why

The obvious design is a rule — "one space between operator and operand" — and it is wrong on the
corpus's own notation. `notation:65 a:66 " ⊗" b:65 => Prod.mk a b` declares its atom as `" ⊗"`: a space
on the **left**, tight on the **right**. A uniform one-space rule emits `3 ⊗ 4`; the declaration says
`3 ⊗4`, and a formatter that respaces to a shape the author's own notation forbids is not canonicalizing,
it is corrupting.

So the unit that gets a separator is not the node, it is the **gap between two adjacent parts**, and each
gap's separator is read off the two atom strings bounding it:

- The atom string is emitted **verbatim** — its bytes are the source's, never synthesized. Only the gaps
  between parts are chosen.
- A gap's separator is `" "` if *either* bounding atom declares a space on the side facing that gap
  (`" ⊗"` ends without a space → tight-right; starts with one → space-left), `""` if neither does, and
  `none` — keep the source bytes — if neither side of the gap is an atom at all (two operands adjacent,
  the phase-1 conservative case).

`3 ⊗4` is that fidelity pinned: the gap left of `⊗` opens to one space, the gap right of it stays tight,
from one atom string, in one node. It is the phase-1 `matchAlt` insight — that a construct can declare
tight-left/space-right per gap and must be honored exactly — arriving from the notation table instead of
a hardcoded comma rule.

## The fact is load-bearing, and the fallback proves it

Every other fixture in `tests/printer/run.sh` analyzes with `captureSemantic=0`, so its artifact carries
no fact and its notations keep their bytes — which is why `wonky`'s `id 12 + id 13` still keeps the
spaces the author wrote. The contrast is a gate, not a footnote: the **same** `notation.lean` source
analyzed with `captureSemantic=0` comes back byte-identical to its input, and the run fails if it does
not. That is the line between reading a declaration and guessing one — the spacing above is the fact's,
because with the fact withheld the printer invents nothing.

A node with no fact (custom syntax `ruff-05b`'s producer could not resolve, a count mismatch, or a `v3`
artifact) keeps its source bytes. The mapping is **positional with a count guard**: the node's atom-parts
(child = `none`) map in order to `fact.atoms`, and a size mismatch — a `sepBy` notation whose atom count
the positional model cannot describe — falls to `.keep` rather than mis-spacing. Conservative fallback,
never invented spacing, is the same contract phase 1 shipped; this prompt only adds a second way *in* to
the declared path and keeps the door for everything else.

## The comment refusal reaches a notation

`6 /- keep -/ + 7` is **unchanged**. The comment sits in the gap left of `+`; the declared `" + "` would
put a single space there and so delete the comment, so that gap keeps its bytes, while the gap right of
`+` — already one space — takes the declared spacing. This is phase-1's per-gap `respaceable` guard,
which refuses any gap holding a comment or newline, reaching the notation path unchanged. No comment is
dropped or moved; the golden line pins it, and parse-preservation would catch a lost token regardless.

The respacing also only fires on single-line commands (`Tree.mayCollapse`): a notation spanning lines
could hold column-sensitive structure, and re-spacing it risks the offside law the whole stack is built
around. That guard is `RLF-EXTENSIONS`'s, reused, not rebuilt.

## The gates, and the proof they are non-vacuous

| gate | what it pins | how it fails |
|---|---|---|
| golden diff | the five declared shapes exactly | any byte off the golden |
| changed-something | the fact is actually consumed | output equals input → the fact is doing nothing |
| conservative fallback | `captureSemantic=0` → byte-identical | any respacing with no fact present |
| parse-preservation | output re-parses to the **same token count** | a token added, dropped, or merged |
| idempotence (fact path) | `format (format x) = format x` | a second fact-carrying pass that differs |

Two of these are the roadmap's named gates and both run on the **fact path specifically**: the generic
`check_idempotent` below re-analyzes with `captureSemantic=0`, so it cannot exercise notation layout at
all — the second idempotence pass here re-captures the fact (`captureSemantic=1`) so the layout actually
fires twice. Parse-preservation re-analyzes the *output* and asserts an artifact comes back (non-vacuous
because `__analyze-exact` withholds `artifact` on any parse error, pinned by `broken.lean`) **and** that
its token count equals the input's — respacing moves whitespace and nothing else.

## The boundary repair this prompt had to make first

Verifying RLF-NOTATION's boundary gate required `tests/boundary/run.sh` green, and it was not:
`tests/semantic/Emit.lean` — a `ruff-05b` oracle run via `lake env lean` — began with `import Lean`,
violating the invariant that every tracked `.lean` (bar lakefiles) begins with `module`. Its sibling
fixture `tests/semantic/Notation.lean` was already module-mode and worked, so the fix is one line:
prepend `module`. Verified rather than assumed — `tests/semantic/run.sh` still emits `1 + 2 * 3` and
`1 ⊕corpus 2` from the oracle's `run_cmd`/`ppTerm` path, so module mode did not change what Lean's own
pretty printer prints. A `ruff-05b` defect, corrected in place because the gate this prompt owns cannot
pass around it.

## Exact commands

    LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests
    for s in boundary check compiler layout lossless modes printer scale service; do bash tests/$s/run.sh; done
    experiments/run-projection-shape.sh          # regenerate evidence/01-projection-shape.txt
    experiments/check-quoted-figures.py          # 33 quoted figures vs. evidence
    git diff --check
    uv run …/check_stack.py --structural docs/projects/ruff-03-language-formatting
    uv run …/write_next.py --check docs/projects/ruff-03-language-formatting

All ten suites pass (`failures=0`). Structural checker: `OK: 10 prompt(s), 0 warning(s), no errors`.

## Measurements

The shape evidence moved, because **this repository is the printer's own corpus** and touching
`LeanFmt/` moves every figure quoted from it. `evidence/01-projection-shape.txt`, regenerated:

    nodes=47329 empty_nodes=16943 (35.8%) ambiguous=7367 (15.6%) commands=501 declarations=432

The prose that quotes these (`Printer.lean`'s docstring, `notes/01-command-printing.md`,
`state/current.md`) was re-synced and `check-quoted-figures.py` re-passes on all 33 figures — the
`RLF-FINAL` gate doing exactly the job it was built for, one prompt after it was built.

The notation fixture: 4 of its 5 defs are rewritten (`1+2`, `1+2*3`, `8  +  9`, `3⊗4`); the `notation`
command declaring `" ⊗"` and the commented def are the two the fact-or-comment path deliberately leaves
alone.

## What is left uncertain

- **The atom → gap mapping is positional, and a `sepBy` notation is out of its reach.** The count guard
  makes that safe — a mismatch keeps bytes — but it also means a notation whose atoms repeat is on the
  conservative path, not the declared one. `ruff-05b`'s fact shape (a flat `Array String`) is what
  bounds this; a richer fact is a `ruff-05b` question, not a printer one.
- **The margin is set (100) but still unexercised by breaking.** This prompt is the *horizontal* half of
  operator formatting — declared spacing within a line. Nothing here asks the engine to measure a width
  and break, and `1 + 2 * 3` keeps its tree because precedence is the parser's, untouched. Margin-driven
  line-breaking is `RLF-REFLOW` (prompt 08), and `RLC-FINAL`'s standing caveat — no `group`/`line`/`nest`
  reaches the engine from real source yet — narrows here but does not close.
- **Custom multi-line notations are declined, not laid out.** `mayCollapse` refuses them wholesale rather
  than reasoning about their column structure. That is the sound default `RLF-EXTENSIONS` established and
  the residue it named; offside layout for such constructs is `RLF-OFFSIDE`/`RLF-BLOCKS`, later in the
  stack.
