# RLC-FINAL — Audit layout depth and complexity

The audit found the note's central complexity claim was **false when it was written**, and found it by
measuring the claim rather than restating it. That is the headline; everything else confirms.

## What was built

- **`LeanFmtTest.doc-bench`** — five document shapes chosen to decide §4.6 rather than to pass it, and
  `doc-dump`, which renders every generated document at every margin so equivalence claims about the
  renderer can be settled by diff instead of by argument.
- **`tests/layout/bench.sh`** — the complexity claim as a persistent test. Growth *ratios*, not
  wall-clock budgets: a machine-time threshold would be a number invented here, whereas linear and
  quadratic differ by 8–100× across the size steps used and mean the same thing on any machine.
- **`experiments/run-attachment-sample.sh`** — comment attachment over the frozen 62-module mathlib
  sample. Complete mathlib is forbidden and was not run.
- **`LeanFmt/Doc.lean`** — one defect fixed, below.

## Commands

```bash
LEAN_NUM_THREADS=1 lake build                        # Build completed successfully (32 jobs).
lake exe lean-fmt-tests                              # lean-fmt module-artifact tests passed
tests/boundary/run.sh                                # native module and dependency boundary passed
tests/layout/run.sh                                  # failures=0   (evidence/02-attachment.txt)
tests/layout/bench.sh                                # failures=0   (evidence/03-layout-bench.txt)
experiments/run-attachment-sample.sh                 # 62 modules   (evidence/03-attachment-sample.txt)
/usr/bin/time -l lake exe lean-fmt-tests doc-bench   # RSS, below
git diff --check                                     # no output
# from /Users/jcreinhold/Code/kan-proofs, with pyyaml available:
uv run --with pyyaml python .claude/skills/lean-plan/scripts/check_stack.py docs/projects/ruff-02-layout-core
uv run --with pyyaml python .claude/skills/lean-plan/scripts/write_next.py --check docs/projects/ruff-02-layout-core
```

## Measurements

### The defect: nested groups were quadratic (`evidence/03-layout-bench.txt`)

`go` decided every `group` with a fit test **regardless of the mode it was already in**. A group nested
inside a group already rendering flat re-ran the whole test, so `n` nested groups ran `n` tests over the
tail:

| n | before | after |
| --- | --- | --- |
| 1000 | 2.639 ms | 0.026 ms |
| 2000 | 10.533 ms | 0.051 ms |
| 4000 | 45.244 ms | 0.101 ms |
| 8000 | 190.599 ms | 0.200 ms |

72× across an 8× size step (quadratic) became 7.6× (linear) — **854× faster at n=8000**. This is the
roadmap's line 18 verbatim, "linear or demonstrably near-linear on adversarial nesting", and it was
**not met before this prompt**.

The fix is one line of dispatch on the mode, and the argument for it is not performance: `fits` reaches
its answer by pushing inner groups as `.doc i .flat d`. It has *already assumed* they render flat. `go`
re-deciding could only re-derive the same answer — or, if it ever derived a different one, emit a break
inside a group `fits` had certified as flat. Honoring the mode is what keeps the two functions the same
function; the 854× is a side effect of them agreeing on purpose rather than by accident.

**Byte-identical output.** "This should not change layout" is exactly the kind of claim this project
does not accept unsourced, so it was diffed: `doc-dump` renders 400 generated documents at 41 margins
each, and all **16,400 renders are identical** before and after. The fix removes work, not decisions.

### Complexity, by shape

| shape | growth | verdict |
| --- | --- | --- |
| `zero-width-nesting` | 7.6× over 8× | linear — the roadmap's bar |
| `call-args` | 92.2× over 100× | linear — the shape a printer emits |
| `marked-call-args` | 105.4× over 100× | linear — `mark` costs a constant |
| `nested-calls` | 2.24 → 2.21 ns/output byte | flat |
| `zero-width-siblings` | 66.6× over 8× | **quadratic — the known hole** |

`nested-calls` is billed per output *byte* because `nest` is unclamped by contract (§4.6): depth n at
unit 2 emits Θ(n²) bytes — 200 MB at n=10,000 and 20 GB at n=100,000. The cost is the output, not the
fit test, and per byte it is flat. Note the live engine reproduces the frozen probe exactly:
`out_bytes=200050001` at n=10,000, the same number `evidence/01-layout-probes.txt` recorded for the
model before it was implemented.

### The known hole is real, and it is Wadler's, not this implementation's

`zero-width-siblings` — n sibling groups spending no column and offering no break — is Θ(n²) and the
nesting fix does not touch it. Unlike the nesting case this one is **semantic**: "does this fit up to
the next break" genuinely depends on the whole tail when there is no next break. Only a running total
over the tail closes it, which is Oppen's `rightotal`, the model §3 rejected on expressiveness.

Lean core was measured on the identical shape, and **`Std.Format` is quadratic too**: 6.56 / 26.21 /
107.40 / 431.76 ms at n = 1000 / 2000 / 4000 / 8000 — 4.0× per doubling. (Interpreted, so the constant
factor against `Doc` is not comparable and is not compared; the growth is the finding.) This is a
property of Wadler fit testing that core's own pretty printer shares.

The bound is therefore stated exactly rather than hoped for, and §4.6 now carries it: `render` is
O(n·k) for k the largest node-distance between break opportunities. A printer that emits a token per
node has every node spending a column, and one that offers a break at each line boundary — which any
Lean printer must, a module not being one line — has k bounded by its widest construct. That is a
precondition on printers, recorded as one.

### Comment attachment on code nobody wrote for the rule (`evidence/03-attachment-sample.txt`)

`RLC-IMPL` recorded the blocker: the rule had only ever met fixtures written against it, plus this
repository's own modules, which have **no trailing comments at all**. The frozen sample answers it:

```
modules=62 failures=0 tokens=119856
comments=127 leading=116 trailing=11 dangling=0
modules_with_trailing=7 modules_with_dangling=0
```

`partitions` holds on all 62 modules and 119,856 tokens. Real mathlib **does** contain the position this
repository lacks: 11 trailing comments across 7 modules. Spot-checked by hand rather than trusted —
`Mathlib/NumberTheory/LSeries/ZMod.lean` reports 5, and its same-line comments are exactly lines 111,
173, 174, 362 and 366.

**The `splitPoint` correction is load-bearing on real code.** `RLC-IMPL` departed from Lean's
`chooseNiceTrailStop` because its raw `posOf '\n'` scan can tear a block comment, and justified it by
reasoning. `Mathlib/Probability/Kernel/Deterministic.lean:146` is that case in the wild — a three-line
block comment opening after `·` on the same line. Mutating `splitPoint` back to Lean's rule and
re-running the module:

```
Mathlib/Probability/Kernel/Deterministic.lean	uncaught exception: attachment did not preserve every comment exactly once
```

Lean's own rule, applied verbatim, loses a comment in real mathlib. Restored, the comment attaches as
`trailing` of `·` (`comments=1 leading=0 trailing=1 dangling=0`).

### Allocations and RSS

`/usr/bin/time -l` over the whole benchmark: **672 MB maximum resident set size**, 132 MB peak memory
footprint, 2.81e9 instructions retired, 1.79 s real. The benchmark's largest single output is the
200 MB `nested-calls` document, so peak RSS is ≈3.4× output size — the cost of `out ++ s` reallocating
as it grows. Against the roadmap's 8 GiB envelope, with the largest real artifact at 660 KB
(`RLS-FINAL`), the margin is four orders of magnitude. The 3.4× ratio, not the 672 MB, is the number
that generalizes.

### Callers

There are none. `grep` over the tree finds `LeanFmt.Doc` and `LeanFmt.Comments` imported **only by
`LeanFmtTest.lean`**. Nothing in production consumes the layout core: `Rules.lean` still produces
`Finding`s from text rules, and no language-specific printer exists — the roadmap places printers in a
later stack. So "audit all callers for leaked mechanism" passes with nothing to report, and that is a
weaker result than it sounds: see remaining uncertainty. The boundary that *is* checked is the plugin's
— both modules are in `LeanFmtCore` and neither is in `LeanFmtCompilerPlugin`, and `tests/boundary/run.sh`
passes.

## Decisions changed during execution

1. **§4.6's complexity claim was rewritten, because measuring it refuted it.** The note said "every
   shape measured here is linear" and deferred the zero-width case to this prompt. Both halves needed
   correction: adversarial *nesting* was quadratic (a real defect, now fixed), and the zero-width
   sibling case is quadratic and stays that way. The replacement states the bound as O(n·k) with k the
   node-distance between breaks, which is checkable, rather than "linear at every size measured", which
   was true only of the sizes measured.
2. **The hole was not fixed, and the reason is recorded rather than elided.** Closing
   `zero-width-siblings` means a running total over the tail — Oppen's `rightotal`. `RLC-SPEC` rejected
   Oppen on the mode-dependent separator, which is unaffected by anything found here, so the rejection
   stands and the cost is accepted a second time on the same terms. Discovering core has the identical
   quadratic is what makes this an accepted cost rather than an outstanding bug: it is the model's, not
   the implementation's.
3. **The benchmark asserts ratios, not milliseconds.** The first draft would have needed a wall-clock
   bound, which is a number with no basis that fails on slow machines and catches little. Growth across
   a size step separates linear from quadratic by 8–100× and is machine-independent.

## Defects found

1. **Nested groups were quadratic** — `go` ignored its own mode. Fixed; 854× at n=8000; output
   byte-identical across 16,400 renders. Caught by `tests/layout/bench.sh`, which was verified
   non-vacuous by reverting the fix (`FAIL zero-width-nesting: 66.1x ... over the 24x bound`) while its
   other three assertions still passed — so that shape, and only that shape, discriminates.
2. **The benchmark measured nothing at first.** A pure `let` in Lean is not evaluated where it is
   written, so `let out := renderText 80 d` between two clock reads timed an unforced thunk: 166 ns at
   n=1000 and *decreasing* to 42 ns at n=8000. A benchmark whose cost falls as its input grows is not
   reporting a fast renderer, it is reporting no renderer. Every timed region now forces its result, and
   `benchOne` says so at the point where it matters.

## Remaining uncertainty

- **Nothing consumes this.** The strongest statement available is that the engine is internally correct
  and linear on the shapes a printer *would* emit. No printer exists, so every claim about realistic
  documents rests on fixtures written here — `call-args` is my model of a Lean call, not a Lean call.
  The printer stack is where this becomes evidence.
- **The O(n·k) precondition is stated, not enforced.** `Doc.wellFormed` checks the newline invariant;
  nothing checks that a document offers breaks at bounded node-distance. It is unreachable from a
  token-per-node printer by construction, but "by construction" is an argument about printers that do
  not exist yet.
- **`leading` is still exercised by no parser output.** 127 mathlib comments, all arriving via trailing
  runs; `nonempty_leading=0` holds across the sample as it did on the fixture. The non-empty-leading
  path remains covered only by hand-built projections.
- **No dangling comment exists in the sample.** `dangling=0` across all 62 modules — no mathlib module
  ends with a comment after its last token. The `trailer` path is real and structural, and it is covered
  only by the generated fixture in `tests/layout/run.sh`.
- **Unicode width is unresolved and now measured against nothing.** Columns are codepoints (§4.7), which
  under-counts CJK and emoji by half and is not normalization-stable. No benchmark or corpus here
  contains either. The first printer to format a string literal inherits this.
- **RSS was measured on one machine, one allocator, one run.** The 3.4×-output-size ratio is a single
  observation, not a distribution.
