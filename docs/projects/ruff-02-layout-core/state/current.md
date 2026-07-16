---
kind: state
first_unresolved: none
---

# Current state

The layout contract is frozen in `notes/01-layout-design.md` and backed by a toolchain experiment
(`experiments/layout-core/`) that shares no module with `LeanFmt`, and whose two candidates share no
module with each other. Its external prerequisite stack `ruff-01-lossless-source` is verified and its
live implementation still matches recorded state.

The engine is **live and audited**. `LeanFmt/Doc.lean` implements the frozen contract — the algebra,
the bounded renderer, and source marks — and `LeanFmt/Comments.lean` implements ownership. Both are in
`LeanFmtCore` and deliberately not in `LeanFmtCompilerPlugin`: the plugin runs inside every
compilation of every downstream module, and nothing the compiler does needs to render a document.

**Nothing consumes it.** `LeanFmt.Doc` and `LeanFmt.Comments` are imported only by `LeanFmtTest.lean`;
`Rules.lean` still produces `Finding`s from text rules, and no language-specific printer exists — the
roadmap places printers in a later stack. This stack is complete, and that completeness is bounded by
this fact: every claim about *realistic* documents rests on fixtures written here.

The chosen model is a **Wadler/Leijen document tree whose `line` carries its flat text, rendered by a
bounded work list**. Lean core's own `Std.Format` is rejected: it is a closed inductive and the one
constructor that decides this cannot be added from outside it.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-design | RLC-SPEC | verified | — |
| 02-engine | RLC-IMPL | verified | RLC-SPEC |
| 03-acceptance | RLC-FINAL | verified | RLC-IMPL |

## Known evidence

- **A mode-dependent separator is the whole decision.** A `do` block is `do act1; act2` flat and drops
  the `;` when broken. Only a `line` carrying its own flat text can state this: at margin 12, Oppen
  and `Std.Format` both render `do\n  act1;\n  act2` and strand the semicolon, while `line "; "`
  renders `do\n  act1\n  act2`. The gap is not "Wadler vs Oppen" — **core's `Format` fails identically
  to Oppen**. The same generalization subsumes Wadler's `line` (`flat=" "`) and Leijen's `softline`
  (`flat=""`).
- **The two models are not distinguished by their break decisions.** `margins_where_models_disagree=0`
  across 10 margins from 30 to 5, including the flip at 13/14. They agree by different mechanisms:
  Wadler's `fits` walks the tail explicitly, Oppen's `check_stream` forces the oldest undecided group
  to infinity once the buffer exceeds the line.
- **Wadler's linearity is a claim about Haskell, not about the algebra.** Transliterated into strict
  Lean, `best`/`fits` is **Θ(φⁿ)** in sibling groups — growth converges to 1.6180, and n=20 costs
  161,006 steps to emit 180 bytes. The *same algebra* under a bounded work-list renderer is exactly
  `18n − 1`, measured to n=100,000. The renderer is therefore part of the contract. Lean core reached
  the same conclusion independently for the same reason: `Std.Format.be` is already a work list and
  `pushGroup` already measures a group with the remainder of its line.
- **Oppen's bounded-memory advantage is real, on both shapes.** `peak_buffer` is a constant 12 across
  sibling n=10…100,000 and a constant 32 across nested n=100…10,000. The chosen model does not have
  this: a tree is O(n) by construction. Candidate B is rejected on expressiveness and on its balance
  obligation, **not** on memory, and the note records A's memory as a cost accepted. The bill is
  O(one module) against `RLS-FINAL`'s 660 KB largest artifact.
- **Comments are attached by the formatter, not by the parser.** Measured over 56 leaves:
  `nonempty_leading=0`, `comment_in_leading=0`, `comment_in_trailing=6`, `verdict=trailing-greedy`.
  `Lean.Syntax.updateLeading` is documented to split trailing trivia at the first newline "so that
  e.g. comments are associated to the (intuitively) correct token" and **has no caller in the 4.32
  tree**. The parser leaves `leading` empty and runs `trailing` greedily to the next token, so one run
  routinely holds a trailing comment, a blank line, and the next declaration's leading comments
  together. The contract adopts `chooseNiceTrailStop`'s first-newline rule as a specification.
- **Comments before the first command are header text and are not attachable.** `header_stop=331` on
  the fixture, and the single header leaf carries both the module docstring and the first
  declaration's leading comment. A module linter never receives the header.
- **Attachment is checkable, not merely intended.** `LosslessSource.structurallyValid` already
  requires trivia runs to tile `[headerStop, terminalStop)` exactly once; attachment is a partition of
  that tiling, so "every comment preserved exactly once" reduces to an invariant the projection
  already carries.
- **A column is one codepoint, because core says so.** `Std.Format` counts `String.Internal.length`;
  a 6-codepoint, 12-cell CJK string stays flat at width 8 and breaks at 7. `defWidth = 120`. The cost
  is recorded rather than hidden: codepoints under-count CJK and emoji by half and are **not
  normalization-stable** (`é` measures 1 column precomposed, 2 decomposed).
- **A margin is not a guarantee.** The renderer never breaks `text` and never invents a break
  opportunity. At margins 8, 6, and 5 both models emit a 9-column line, because `) => tail` is atomic.
  Indentation is likewise unclamped: depth 10,000 at unit 2 emits 200 MB, nearly all spaces.
- **Repeated string append in Lean is linear, not quadratic.** The runtime mutates a unique string in
  place, so `out := out ++ s` beats `Array` + `String.join` (200,000 fragments: 1.148 ms against
  3.373 ms, identical output). The quadratic risk is real only where the accumulator is shared. This
  contradicts the assumption behind prompt 02's "repeated string concatenation" stop rule.
- **The error surface is empty by construction.** With no alternative constructor — no Wadler `Union`,
  no `best_fitting`, no `conditionalGroup` — the roadmap's "no unbounded alternative retention" is
  unrepresentable rather than a discipline to keep, and `render` is total.
- **The newline-free `text` invariant forced a ninth constructor** (`RLC-IMPL`). A block comment and a
  multi-line string are single tokens containing newlines whose bytes are not the formatter's to
  touch: `text` cannot hold them, and `hard` would re-indent them — which is exactly the
  `Std.Format` bug at `Basic.lean:269-276` that this project exists to avoid. `verbatim` emits bytes
  unchanged and, unlike `hard`, does not force its group to break. `notes/01-layout-design.md` §4.1,
  §4.2, §4.6 were corrected to match.
- **Attachment holds on the real parser, and the split correction is load-bearing.** 18 modules +
  `Main.lean`, `comments_attached=59 dangling=0 failures=0`, `partitions` true on every one
  (`evidence/02-attachment.txt`). Adopting Lean's raw `chooseNiceTrailStop` scan verbatim **loses** a
  block comment that spans a newline, because range-based attachment cannot own a torn comment; Lean
  survives the same tear only because it moves a substring boundary. `splitPoint` therefore splits at
  the first newline *outside* any comment — sound because a line comment provably cannot contain one.
- **This repository has no same-line trailing comment.** Every corpus module reports `trailing=0`;
  `grep -rnE '[^ /-][ ]+--[ ]'` over `LeanFmt` and `Main.lean` returns nothing. So the corpus cannot
  exercise the split at all: under the raw-scan mutation above, **all 18 modules still passed** and
  only the generated fixture caught it. Real-parse coverage of trailing, inline-block, newline-spanning
  block, and dangling positions comes from `tests/layout/run.sh`'s generated fixture (`comments=5
  leading=1 trailing=3 dangling=1`), which borrows a setup exactly as `tests/lossless/run.sh` does.
- **Attachment holds on the frozen mathlib sample, and Lean's own rule loses a comment there**
  (`RLC-FINAL`, `evidence/03-attachment-sample.txt`). 62 modules, 119,856 tokens, `failures=0`;
  `comments=127 leading=116 trailing=11 dangling=0`, with real trailing comments in 7 modules. The
  `splitPoint` correction is load-bearing on real code, not only in argument:
  `Mathlib/Probability/Kernel/Deterministic.lean:146` opens a three-line block comment after `·` on the
  same line, and mutating `splitPoint` back to `chooseNiceTrailStop`'s raw scan **fails that module**
  on "preserve every comment exactly once". Restored, it attaches as `trailing` of `·`.
- **Nested groups were quadratic, and that was a real defect, now fixed** (`RLC-FINAL`). `go` decided
  every `group` with a fit test regardless of the mode it was already in, so `n` nested groups ran `n`
  tail walks: 72× across an 8× size step. A group inside an already-flat group must not be re-tested —
  `fits` reached its answer by *assuming* inner groups render flat, so re-deciding can only re-derive
  that answer or contradict the test that authorized it. Now 7.6× across the same step, 854× faster at
  n=8000, and **byte-identical across 16,400 renders** (400 documents × 41 margins): the fix removed
  work, not decisions. The roadmap's "near-linear on adversarial nesting" was **not met** before this.
- **The residual hole is Wadler's, not this implementation's.** `n` sibling groups spending no column
  and offering no break are Θ(n²) (66× across an 8× step), because "does this fit up to the next break"
  genuinely depends on the whole tail when there is no next break. **Lean core's `Std.Format` is
  quadratic on the identical shape** (4.0× per doubling, measured). Only Oppen's running total closes
  it, and §3's rejection of Oppen is untouched by anything found here — so the cost is accepted a second
  time on the same terms. The bound is now stated exactly: `render` is O(n·k) for k the largest
  node-distance between break opportunities, and a token-per-node printer bounds k by its widest
  construct.
- **`mark` costs a constant, and peak RSS is ≈3.4× output size.** 100,000 marks render in 14.8 ms,
  growth 105× over a 100× size step; `/usr/bin/time -l` reports 672 MB peak RSS for a benchmark whose
  largest output is 200 MB. Against the 8 GiB envelope and a 660 KB largest real artifact, the margin is
  four orders of magnitude. The ratio, not the 672 MB, is what generalizes.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.
- **Nothing consumes the layout core, so it is unvalidated by any real caller.** This is the binding
  limit on everything above and the reason the stack is complete rather than finished: `call-args` is
  my model of a Lean call, not a Lean call. The printer stack turns these claims into evidence.
- **The O(n·k) precondition is stated, not enforced.** `Doc.wellFormed` checks the newline invariant;
  nothing checks that a document offers breaks at bounded node-distance. It is unreachable from a
  token-per-node printer by construction — an argument about printers that do not exist yet.
- **`leading` is exercised by no parser output.** `nonempty_leading=0` on 4.32, and all 127 sample
  comments arrive via trailing runs, as did all 59 corpus comments. The non-empty-leading path exists
  because the projection permits it, but only hand-built projections in `testComments` cover it.
- **No dangling comment exists in the mathlib sample.** `dangling=0` across all 62 modules. The
  `trailer` path is structural rather than heuristic, and it is covered only by the generated fixture in
  `tests/layout/run.sh`.
- **Unicode width is unresolved and measured against nothing.** Columns are codepoints, which
  under-count CJK and emoji by half and are not normalization-stable. No corpus or benchmark here
  contains either; the first printer to format a string literal inherits it.
- **Deliberately deferred to `RLC-FINAL` as remaining language decisions**, so silence is not mistaken
  for a ruling: inconsistent (`fill`) breaking, align-to-current-column, indentation clamping, and the
  margin value itself. The margin is configuration and must enter cache identity; the `Doc` is never
  serialized and never does.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
