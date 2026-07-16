# RLC-SPEC — Choose the layout model

Claim: **RLC-SPEC**. Design output is `notes/01-layout-design.md`; this note records the commands,
raw evidence, and what changed while executing.

- Base commit: `f82e42fae3878d9d1ea31cdf74e16385407bf178`
- Toolchain: `leanprover/lean4:v4.32.0` (target and experiment pinned identically)
- Machine: Apple M4 Pro, 24 GiB, Darwin 25.5.0 arm64, `LEAN_NUM_THREADS=1`
- Evidence transcript: `evidence/01-layout-probes.txt` (151 lines, 7 probes)
- Harness: `experiments/layout-core/run.sh` (22 checks, `failures=0`)

## What was built

`experiments/layout-core/` follows the precedent `RLS-SPEC` set: a self-contained experiment that
shares no module with `LeanFmt`. Here the isolation goes one step further — the two candidates do not
import each other either, because a prototype sharing code with its rival cannot contradict it.

- `Wadler.lean` — a Wadler/Leijen document algebra with **two** renderers for the same algebra:
  `renderTextbook` (Wadler's `best`/`fits`, transliterated) and `renderBounded` (a work list whose fit
  test stops at the margin). Both are kept because Wadler's linearity argument is a claim about
  Haskell's laziness, not about the algebra, and Lean is strict. Its `Doc.line` carries a `flat :
  String` — the one generalization the note turns on.
- `Oppen.lean` — Oppen 1980 scan/print over a token stream, the model behind rustfmt's `pp.rs`.
  Instrumented with `peakBuffer` so the bounded-memory claim is measured rather than repeated. The
  scan stack is a `HashMap`-backed deque; an `Array` would make `popFront` linear and turn the O(n)
  claim under test into O(n·w).
- `TriviaProbe.lean` — reads `SourceInfo` off the shipping toolchain to find where a comment actually
  lives.
- `LayoutProbe.lean` — subcommands `trivia`, `complexity`, `fit`, `express`, `stdfmt`, `width`,
  `assemble`. `Std.Format` is exercised through `express` and `stdfmt`: it is already in the tree, so
  "write our own" needed a reason that is a measurement.
- `fixtures/Comments.lean` — every position a comment can occupy in an accepted module.
- `run.sh` — asserts a declared outcome per check, pinning exact numbers so a toolchain bump that
  changes `Std.Format`'s renderer or the parser's trivia handling fails here instead of silently
  invalidating the note.

## Commands

```sh
experiments/layout-core/run.sh                  # 22 checks, failures=0
LEAN_NUM_THREADS=1 lake build                   # repo root
lake exe lean-fmt-tests
tests/boundary/run.sh
git diff --check
# from /Users/jcreinhold/Code/kan-proofs, with pyyaml available:
uv run --with pyyaml python .claude/skills/lean-plan/scripts/check_stack.py <stack>
uv run --with pyyaml python .claude/skills/lean-plan/scripts/write_next.py --check <stack>
```

## Measurements

### Comment ownership (`trivia`, `fixtures/Comments.lean`, 56 leaves)

```
leaves=56 nonempty_leading=0 trailing_spans_newline=11
comment_in_leading=0 comment_in_trailing=6
header_leaves=1 header_stop=331 comment_bearing_header_leaves=1 command_leaves=55
verdict=trailing-greedy
```

`Lean.Syntax.updateLeading` (`Lean/Syntax.lean:304`) is documented to split a token's trailing at the
first newline via `chooseNiceTrailStop` "so that e.g. comments are associated to the (intuitively)
correct token". **It has no caller in the 4.32 tree, and the split never happens.** Every comment sits
in the *preceding* token's trailing run, and one run routinely holds a trailing comment, a blank line,
and the next declaration's leading comments together:

```
token="0" span=392-393
  trailing=" -- trailing comment, same line as the token\n\n-- first of two stacked leading comments\n-- second of two stacked leading comments\n"
```

### Expressiveness — the mode-dependent separator (`express`)

A `do` block is `do act1; act2` flat and drops the `;` when broken.

| model | margin 40 | margin 12 |
| --- | --- | --- |
| Wadler bounded, `line (flat)` | `do act1; act2` | `do\n  act1\n  act2` |
| Oppen | `do act1; act2` | `do\n  act1;\n  act2` |
| `Std.Format` | `do act1; act2` | `do\n  act1;\n  act2` |

Oppen's `Break` inserts blanks only; `Std.Format.line` flattens to `" "` only. Both strand the
semicolon. This is the measurement that decides the prompt.

### Break decisions (`fit`, `group(f(arg))` + ` => tail`, 10 margins from 30 to 5)

```
margins_where_models_disagree=0
```

They agree at every margin, including the flip at 13/14, by different mechanisms: Wadler's `fits`
walks the tail explicitly, Oppen's `check_stream` forces the oldest undecided group to infinity once
the buffer exceeds the line. Candidate B is not the weaker model on this axis.

At margins 8, 6, and 5 both emit a 9-column line: `) => tail` is atomic text with no break in it. A
margin is not a guarantee.

### Complexity (`complexity`)

Textbook Wadler, `n` sibling groups at margin 20:

| n | steps | ms | out B | growth per group |
| --- | --- | --- | --- | --- |
| 1 | 8 | 0.004 | 9 | — |
| 5 | 113 | 0.007 | 45 | 1.9386 |
| 10 | 1,309 | 0.032 | 90 | 1.6322 |
| 14 | 8,976 | 0.209 | 126 | 1.6182 |
| 16 | 23,495 | 0.537 | 144 | 1.6179 |
| 18 | 61,503 | 1.391 | 162 | 1.6179 |
| 20 | 161,006 | 3.533 | 180 | 1.6180 |

Θ(φⁿ) — the growth factor converges to the golden ratio, because at this margin roughly every other
group fits and the recurrence is Fibonacci-shaped. Nested groups are *not* exponential for the
textbook renderer (steps track output at a constant 2.77, measured 2.765–2.769 over n = 14…20);
sibling groups are the blowup.

Linear shapes, exact:

| shape | renderer | steps | at n | ms | out B | peak buffer |
| --- | --- | --- | --- | --- | --- | --- |
| siblings | bounded | `18n − 1` = 1,799,999 | 100,000 | 30.267 | 900,000 | — |
| siblings | Oppen | `10n` = 1,000,000 | 100,000 | 99.870 | 900,000 | **12** |
| nested | bounded | `10n + 485` = 100,485 | 10,000 | 502.855 | 200,050,001 | — |
| nested | Oppen | `11n + 11` = 110,011 | 10,000 | 513.036 | 200,050,001 | **32** |

Both nested rows render byte-identical output (200,050,001 B) at every depth measured, which `run.sh`
now asserts before comparing anything else about them.

**Oppen's bounded-memory claim holds on both shapes.** `peak_buffer` is 12 at every sibling n from 10
to 100,000, and **32** at every nested n from 100 to 10,000 — constant while the document grows four
orders of magnitude. This is a real advantage that the chosen model does not have, and the note
records it as a cost accepted rather than a claim dismissed. See "Decisions changed" #2: this is the
*opposite* of what the first fixture reported.

Oppen's 3.3× wall-time deficit on siblings (99.870 ms against 30.267 ms) is an artifact of this
prototype's `HashMap` deque, **not** of the algorithm; its step count is genuinely lower (1.0M against
1.8M). B is not rejected for being slow. On nesting the two are within 2% (513.036 ms against
502.855 ms), both dominated by emitting 200 MB.

### What core already decides (`stdfmt`, `width`)

`Std.Format` counts `String.Internal.length` — codepoints — in `spaceUptoLine` and `pushOutput`
(`Basic.lean:401`). A 6-codepoint, 12-cell CJK string stays flat at width 8 (`cjk_at_width_8="世界世界世界 x"`)
and breaks at 7. Core's `defWidth = 120`.

| text | bytes | codepoints | cells |
| --- | --- | --- | --- |
| `→` | 3 | 1 | 1 |
| `α` | 2 | 1 | 1 |
| `x₁` | 4 | 2 | 2 |
| `世界` | 6 | 2 | 4 |
| `🎉` | 4 | 1 | 2 |
| `é` precomposed | 2 | 1 | 1 |
| `é` decomposed | 3 | 2 | 1 |

Codepoint width is right for Lean's actual notation, wrong for CJK by 2×, and not
normalization-stable.

Core's renderer `be` (`Basic.lean:252`) is already a bounded work list, and `pushGroup` (line 244)
already measures a group together with the remainder. Core reached both of this note's structural
conclusions independently, for the same reason (Lean is strict). Its `tag : Nat → Format → Format`
hook exists but carries no range.

### Output assembly (`assemble`, n = 200,000 fragments)

```
n=200000 append_ms=1.148 join_ms=3.373 bytes=2000000 same=true
```

Repeated `out := out ++ s` in Lean is **linear**, not quadratic — the runtime mutates a string in
place when its reference is unique — and beats `Array` + `String.join`. This contradicts the common
assumption and is directly relevant to prompt 02's "repeated string concatenation" stop rule: the
quadratic risk is real only where the accumulator is shared, which a renderer's is not.

## Decisions changed during execution

1. **The comparison the prompt asked for is not the comparison that decided anything.** Wadler and
   Oppen make identical break decisions at every margin measured. The real discriminator is one
   constructor — whether `line` carries its flat text — and on that axis **`Std.Format` fails
   identically to Oppen**. The starting assumption was that core's `Format` would be adopted or
   thinly wrapped; it is rejected, and the reason is a measurement rather than a preference.
2. **Oppen's memory advantage was recorded as false, and that was my fixture's fault, not Oppen's.**
   The first nested Oppen stream omitted the closing `)` its Wadler counterpart emitted. It therefore
   rendered half the bytes — the two models were never given the same document — and reported
   `peak_buffer = 2n`, which I wrote up as "the bounded-memory advantage does not survive nesting".
   That conclusion was an artifact: with no width in the tail, `check_stream` never saw the buffer
   exceed the margin, never forced a flush, and undecided entries piled up. With the fixture matched,
   `peak_buffer` is a **constant 32** from n = 100 to 10,000 and both models emit 200,050,001 bytes.
   Oppen's headline claim is real, on both shapes. The rejection now rests on expressiveness and the
   balance obligation alone, and the note records A's O(n) memory as a cost accepted. `run.sh` asserts
   nested byte-identity so this cannot recur silently.

   The wrong reading was caught only because I tried to *explain* the byte discrepancy in prose and
   the explanation did not survive reading the fixture. The lesson is the one the roadmap already
   encodes: a number that has not been explained is not yet a measurement.
3. **The renderer was expected to be an implementation detail.** It is part of the contract: the same
   algebra is Θ(φⁿ) under Wadler's own algorithm in a strict language and exactly `18n − 1` under a
   bounded work list. §4.6 of the note states the renderer, not just the algebra.
4. **Comment attachment was expected to be read off `updateLeading`.** It is dead code in 4.32. The
   split is the formatter's to perform; the note adopts `chooseNiceTrailStop`'s documented rule as a
   specification rather than inheriting it as behavior.
5. **The alternative constructor was dropped, not avoided.** The roadmap forbids "unbounded
   alternative retention". With no `Union`/`best_fitting`/`conditionalGroup` in the algebra, that is
   unrepresentable rather than a discipline the implementation must keep.

## Defects found

None in shipped code. `LeanFmt` has no layout engine yet (`Rules.lean` produces `Finding`s from text
rules only), so there was nothing to contradict.

Three self-caught defects in the probes themselves, each of which had produced a false reading. Every
one of them made a measurement *look* clean while measuring the wrong thing, which is the failure mode
an experiment stack exists to catch:

- **Mismatched nested fixtures** (`LayoutProbe.oNest`) — the Oppen stream omitted the closing `)`, so
  it rendered a different document from `wNest` and reported a `2n` buffer where the truth is a
  constant 32. This one reached a written conclusion in the note before it was caught; see "Decisions
  changed" #2. `run.sh` now asserts byte-identity across the two nested renderings.
- **A no-op timer** (`LayoutProbe.timed`) — reported `ms=0.000` for every row, because nothing ordered
  the pure computation against `monoNanosNow` and the compiler could sink it past the second
  timestamp. Fixed by forcing the value into an `IO.Ref` between the timestamps. This mattered because
  the `assemble` comparison is wall-time-only.
- **A silently normalized fixture** (`width`) — the combining `é` was normalized to the precomposed
  form by the editor, so both rows read `bytes=2 codepoints=1` and the check tested nothing. Fixed by
  constructing from explicit codepoints (`String.ofList ['e', Char.ofNat 0x301]`).

## Files changed

- `experiments/layout-core/{lakefile.lean,lean-toolchain,lake-manifest.json,README.md,run.sh}`
- `experiments/layout-core/{Wadler.lean,Oppen.lean,TriviaProbe.lean,LayoutProbe.lean}`
- `experiments/layout-core/fixtures/Comments.lean`
- `docs/projects/ruff-02-layout-core/notes/01-layout-design.md`
- `docs/projects/ruff-02-layout-core/evidence/01-layout-probes.txt`
- `docs/projects/ruff-02-layout-core/results/01-design.md`
- `docs/projects/ruff-02-layout-core/state/{current.md,next.md}`

No production module changed.

## Remaining uncertainty

- **The fit test's linearity is measured, not proved.** It is bounded in columns of *text*, not in
  nodes between columns: `empty`, `nest`, `group`, and `mark` consume no width, so an adversarial
  zero-width document could make one fit test walk arbitrarily far, giving O(n·w) → O(n²). Every
  shape measured here is linear. `RLC-FINAL` owns demonstrating the adversarial one — the roadmap
  already assigns it. There is now a concrete lead for it: the discarded mismatched fixture was
  effectively a zero-width tail, and it *did* defeat Oppen's buffer bound (`peak_buffer = 2n`). That
  is the same pathology from the other side, and it is evidence the hole is reachable rather than
  theoretical.
- **A's O(n) memory is accepted, not bounded by measurement.** Peak RSS was never measured for either
  model; the buffer instrumentation counts Oppen's scan entries, and there is no counterpart for the
  tree. The argument that O(document) is affordable rests on `RLS-FINAL`'s artifact sizes (660 KB
  largest), not on a measured resident-set figure for a rendered document. The roadmap's 8 GiB
  envelope is unverified for this component.
- **`mark` is specified but not measured.** No probe carries source ranges through a render, so its
  cost and its interaction with `group` are unknown. `RLC-IMPL` owns it.
- **The comment rule is validated on one synthetic fixture**, adversarial by construction rather than
  representative. The frozen mathlib sample has not been run through the trivia probe, and
  `nonempty_leading=0` is asserted only over 56 leaves.
- **No `fill`/inconsistent-breaking need has been demonstrated or ruled out.** The note omits it
  because no Lean construct measured here requires it, which is weaker than knowing none does.
- **Codepoint width is a compromise adopted for agreement with core**, not because it is correct. It
  under-counts CJK by half and is not normalization-stable.
- **Neither model's rendering time is on the critical path**, so the performance measurements here
  discriminate nothing: `RLS-FINAL` measured analysis at a median 1.96 s per mathlib module against
  tens of milliseconds to render a document larger than any real one. They are recorded to bound the
  algebra, not to choose it.
