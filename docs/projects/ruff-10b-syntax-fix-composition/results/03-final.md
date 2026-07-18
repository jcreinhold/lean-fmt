# 03-final — RYC-FINAL result

**Claim:** RYC-FINAL — drive the adversarial cases `ruff-06` handed forward (token-moving fix under
re-projection, UTF-8 boundary, multi-edit, mixed-tier conflict, idempotence) and a frozen-sample
composition run; review every applied edit for exactness and pass-order independence.

**Status:** delivered. Every adversarial case is a persistent regression test; the one real
frozen-sample syntax edit was reviewed and composes exactly. All build/test gates pass.

## Prompt repair (source-false clause)

Step 2 asked for "a file where a syntax `.safe` fix and a source `.safe` fix touch overlapping
canonical ranges." That file is **not constructible from the shipped rules** — they are disjoint by
design. The only source-tier `.safe` fixes are `FMT001` (trailing whitespace, `Rules.lean:159`),
`FMT002` (final newline, `Rules.lean:194`), and `FMT005` (duplicate import, `Imports.lean:199`); each
edits whitespace, EOF, or an import-line byte range that can never intersect a term-paren (`FMT013`) or
attribute (`FMT010/011`) range. So no `check`/`fix` over any input yields two admitted edits whose
byte ranges overlap.

Per the loop directive, `prompt-repair` narrowed the clause: the mixed-tier conflict is exercised at
the conflict path's **owning layer** — `Edit.preparePatch`/`validateConflicts`, unit-tested in
`LeanFmtTest.lean`, exactly as `ruff-06`'s RFX-FINAL tested every other conflict case. This preserves
the intent (the tier-carrying-nothing conflict path rejects an overlap and names both rules) while
being source-true. The clause, `state/current.md`, and this note were updated together.

## Adversarial cases (all persistent regression tests)

### 1. Token-moving fix under re-projection — `tests/syntax/run.sh`, `AttrThenParen.lean`

`@[simp, simp] def a : Nat := ((1))` with `--select FMT010 --select FMT013`. Applying `FMT010` (drop
`, simp`) shifts everything after it, and the attribute reflows onto its own line, so `((1))`'s
canonical offset differs from its original offset. The composed write is `@[simp]\ndef a : Nat := (1)`
— both fixes land exactly. A byte-translation of the original-coordinate `FMT013` edit onto the moved
canonical bytes would corrupt here; re-projection derives every edit from one canonical model, so it
does not. The canonical renderer is near-identity (it applies fixes but does not reflow arbitrary
whitespace — verified directly: `format` on a file with blank-line runs and trailing whitespace left
both untouched), so under the current product a defect moves precisely when an **earlier fix** moves
it. This fixture is that case.

### 2. UTF-8 boundary — `NestedParenUtf8.lean`

`def f (ϕ : Nat) : Nat := ((ϕ))` → `(ϕ)`. `ϕ` is 2 bytes; every compiler-produced offset indexes the
normalized bytes, so the outer-pair deletion must land on the `(`/`)` boundaries and leave `ϕ` intact.
It does, and a re-`check` is clean. This is the frozen-sample `((ϕ i x))` shape in a writable miniature.

### 3. Multi-edit / nested defects — `NestedParenTriple.lean`

`(((1)))` produces two `FMT013` findings; their point-deletions are distinct bytes and compose in one
transaction to `(1)` with no false conflict. (`check` reports the two findings at `(34,41)` and
`(35,40)`; the four deleted parens are distinct.)

### 4. Mixed-tier conflict — `LeanFmtTest.lean`, `testFixAllAdversarial`

Two overlapping findings, one carrying a syntax code (`FMT013`, edit `{0,2}`) and one a source code
(`FMT001`, edit `{1,3}`), fed to `preparePatch "abc"`. It rejects with `.conflict` and the provenance
names **both** rules distinctly (`{left,right}` sorted == `["FMT001","FMT013"]`). This proves the
conflict path carries no tier: a syntax finding and a source finding that overlap are rejected
identically to the same-tier cases `ruff-06` already pinned. (No file drives it, per the repair above.)

### 5. Idempotence — `tests/syntax/run.sh`

Every `fix_applies` case re-`check`s the written file and asserts zero findings. The token-mover block
additionally runs a **second** `fix` on the written file and asserts `written == 0, changed == 0,
status == clean` — nothing is left to change.

### 6. Pass-order independence — `tests/syntax/run.sh`

`fix --select FMT010 --select FMT013` and `fix --select FMT013 --select FMT010` on copies of
`AttrThenParen.lean` write **byte-identical** files (`cmp`). The edits live in one coordinate system and
one atomic transaction, so `--select` order cannot change the bytes.

## Frozen-sample composition run (read-only)

The frozen 62-module sample has exactly one syntax `.safe` finding: `FMT013` on
`Mathlib/GroupTheory/NoncommPiCoprod.lean:173`, `Commute m ((ϕ i x))`. Reviewed with
`format --select FMT013` (preview — **never writes**) through the exact frontend, root `~/Code/mathlib4`:

```
env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  lean-fmt format --root ~/Code/mathlib4 --json --no-cache --select FMT013 \
  Mathlib/GroupTheory/NoncommPiCoprod.lean
# status would-format; findings [FMT013]; real 5.78s
```

The composed `formatted` text has `((ϕ i x))` **absent** and `(ϕ i x)` **present** — line 173 becomes
`Commute m (ϕ i x)`. The module has five other `(ϕ i x)` occurrences that were already single-paren;
all five are unchanged. The fix touched exactly the one defect, exactly across the multibyte glyph.
This is the only applied edit in the sample; manual review is complete.

## Re-projection cost at corpus scale — Design B decision

The composed `format` on `NoncommPiCoprod` (a real, non-trivial mathlib module) took **5.78s** with the
artifact disabled — one extra frontend run over `check`, as gated (only a canonical-rendering syntax run
pays it; `check` and a source-only `fix` do not). **Design B (parse-only projection) is not warranted
for v1:** the cost is a single gated frontend run, the syntax rules are all **preview / default-off**
(`ruff-10`), so the cost is paid only on an explicit `--select`, and Design A keeps the "projection is
compiler evidence" invariant and reuses every downstream stage. The decision to revisit Design B belongs
to `ruff-12` (graduating a syntax rule to default would put the re-projection on every default run) or
`ruff-19` (default-run cost budget), not here.

## Commands run

```sh
LEAN_NUM_THREADS=1 lake build            # 42 jobs, success
lake exe lean-fmt-tests                  # module-artifact + edit/conflict tests passed
tests/syntax/run.sh                      # passed (adversarial composition cases)
tests/modes/run.sh tests/boundary/run.sh # passed
```

## Checks read

| check | result |
| --- | --- |
| `lake build` | exit 0 — `Build completed successfully (42 jobs).` |
| `lake exe lean-fmt-tests` | `lean-fmt module-artifact tests passed` (incl. mixed-tier conflict) |
| `tests/syntax/run.sh` | `lean-fmt syntax-tier rule integration tests passed` |
| `tests/modes/run.sh`, `tests/boundary/run.sh` | passed |
| structural checker, `write_next.py --check` | (recorded in close-out) |
| `git diff --check` | (recorded in close-out) |

## Decisions changed during execution

1. **Conflict case moved from a file to `preparePatch`.** The shipped rules are disjoint by design, so a
   natural syntax-vs-source overlap is unconstructible; the faithful exercise is the owning-layer unit
   test `ruff-06` established. Recorded as the prompt repair above.
2. **Token-mover reframed around the near-identity renderer.** The canonical renderer does not reflow
   arbitrary whitespace, so a fix does not move tokens by *reformatting*; it moves them when an earlier
   fix shifts bytes. The token-mover fixture is a two-rule composition, not a reflow.

## Remaining uncertainty

- Full mathlib is unrun by policy; the composition is validated on the frozen sample's one real edit
  plus the synthetic adversarial fixtures. Broad-corpus fix prevalence is a `ruff-12`/late-candidate
  question.
- Design B remains the named optimization if a syntax rule graduates to default and the gated
  re-projection lands on the default run cost budget.
