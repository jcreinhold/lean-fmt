---
kind: state
first_unresolved: 03-acceptance
---

# Current state

The layout contract is frozen in `notes/01-layout-design.md` and backed by a toolchain experiment
(`experiments/layout-core/`) that shares no module with `LeanFmt`, and whose two candidates share no
module with each other. Its external prerequisite stack `ruff-01-lossless-source` is verified and its
live implementation still matches recorded state.

The engine is **live**. `LeanFmt/Doc.lean` implements the frozen contract — the algebra, the bounded
renderer, and source marks — and `LeanFmt/Comments.lean` implements ownership. Both are in
`LeanFmtCore` and deliberately not in `LeanFmtCompilerPlugin`: the plugin runs inside every
compilation of every downstream module, and nothing the compiler does needs to render a document. No
printer consumes them yet; `Rules.lean` still produces `Finding`s from text rules only, and no
language-specific printer exists. `RLC-FINAL` owns acceptance.

The chosen model is a **Wadler/Leijen document tree whose `line` carries its flat text, rendered by a
bounded work list**. Lean core's own `Std.Format` is rejected: it is a closed inductive and the one
constructor that decides this cannot be added from outside it.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-design | RLC-SPEC | verified | — |
| 02-engine | RLC-IMPL | verified | RLC-SPEC |
| 03-acceptance | RLC-FINAL | planned | RLC-IMPL |

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

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.
- **The known complexity hole is `RLC-FINAL`'s.** The fit test is bounded in columns of *text*, not in
  nodes between columns: `empty`, `nest`, `group`, and `mark` consume no width, so an adversarial
  zero-width document could give O(n·w) → O(n²). Every shape measured is linear. There is a concrete
  lead: a discarded fixture with a zero-width tail *did* defeat Oppen's buffer bound, which is the
  same pathology from the other side.
- **`mark`'s cost is still unmeasured.** `RLC-IMPL` resolved the *semantic* half of this: `mark` is
  implemented, its interaction with `group` is settled (it consumes no width, `fits` walks through it,
  and a `closeMark` command records the output end), and `testDoc` covers it. The *cost* half is not
  resolved. Each mark costs one extra work-list entry, so linearity is a structural argument, not a
  benchmark — no probe carries source ranges through a render at scale. `RLC-FINAL` inherits this with
  its other benchmarks.
- **Peak RSS was never measured for either model.** A's O(n) memory is argued affordable from
  `RLS-FINAL`'s artifact sizes, not from a resident-set figure. The roadmap's 8 GiB envelope is
  unverified for this component.
- **The comment rule has never met code it did not anticipate.** `RLC-IMPL` widened coverage from one
  synthetic fixture to 18 real modules, but they are *this project's own* modules, in a house style
  with no trailing comments — so the positions that matter are still covered only by fixtures written
  against the rule they test. The frozen 62-module mathlib sample has still not been run through
  attachment, and it is the only corpus available that nobody wrote to suit this rule. `RLC-FINAL`.
- **`leading` is exercised by no parser output.** `nonempty_leading=0` on 4.32, and all 59 corpus
  comments arrive via trailing runs. The non-empty-leading path exists because the projection permits
  it, but only hand-built projections in `testComments` cover it.
- **Deliberately deferred to `RLC-FINAL` as remaining language decisions**, so silence is not mistaken
  for a ruling: inconsistent (`fill`) breaking, align-to-current-column, indentation clamping, and the
  margin value itself. The margin is configuration and must enter cache identity; the `Doc` is never
  serialized and never does.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
