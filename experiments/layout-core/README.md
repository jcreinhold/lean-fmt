# layout-core

Toolchain experiment for `docs/projects/ruff-02-layout-core` (`RLC-SPEC`). It answers one question:
which layout model should this formatter's document algebra be, and it answers it by building the
candidates and measuring them rather than by citing their papers.

Nothing here imports `LeanFmt`, and the two candidates do not import each other. A prototype that
shared code with the product, or with its rival, could not contradict either.

```sh
./run.sh            # 22 checks, expects 0 failures
```

Findings are frozen in `docs/projects/ruff-02-layout-core/notes/01-layout-design.md`; the transcripts
are under `docs/projects/ruff-02-layout-core/evidence/`.

## Candidates

- `Wadler.lean` — a Wadler/Leijen-style document algebra, with **two** renderers for the same
  algebra: `renderTextbook` (Wadler's `best`/`fits`, transliterated) and `renderBounded` (a work list
  whose fit test stops at the margin). Keeping both is the point: Wadler's linearity argument is a
  statement about Haskell's laziness, not about the algebra, and Lean is strict.
- `Oppen.lean` — Oppen's 1980 scan/print prettyprinter over a token stream, the model behind
  rustfmt's `pp.rs`. Instrumented with `peakBuffer` so its bounded-memory claim is measured. It holds:
  the buffer is constant on both sibling and nested groups. A comparison against it is only honest if
  both models are handed the *same* document — `run.sh` asserts the nested renderings are
  byte-identical, because the first version of this fixture was not and reported a buffer growth that
  does not exist.
- `Std.Format` — Lean core's own Wadler algebra (`Init/Data/Format/Basic.lean`), exercised through
  the `express` and `stdfmt` subcommands. It is in the tree already, so "write our own" needs a
  reason that is a measurement.

## Parts

- `LayoutProbe.lean` — the subcommands: `trivia`, `complexity`, `fit`, `express`, `stdfmt`, `width`,
  `assemble`.
- `TriviaProbe.lean` — where a comment actually lives, read off `SourceInfo` on the shipping
  toolchain. `Lean.Syntax.updateLeading` is documented to split trailing trivia at the first newline
  "so that e.g. comments are associated to the (intuitively) correct token", and has no caller in the
  4.32 tree. This measures which is true.
- `fixtures/Comments.lean` — every position a comment can occupy in an accepted module.
- `run.sh` — asserts a declared outcome per check.

## What each subcommand decides

| subcommand | question | what it decided |
| --- | --- | --- |
| `trivia` | which token owns a comment | the preceding one; the parser never splits |
| `express` | can each model state a mode-dependent separator | only a `line` carrying its own flat text can |
| `fit` | do the models break differently | no, at any of 10 margins |
| `complexity` | what does each cost | textbook Θ(φⁿ); bounded and Oppen linear; Oppen's buffer constant on both shapes |
| `stdfmt` | what does core already measure and carry | codepoints, and a `Nat` tag |
| `width` | what is a column | a codepoint, and not normalization-stable |
| `assemble` | how should output be concatenated | either; Lean's `++` mutates a unique string in place |

`run.sh` pins the numbers, not just the shapes, so a toolchain bump that changes `Std.Format`'s
renderer or the parser's trivia split fails here instead of silently invalidating the note.
