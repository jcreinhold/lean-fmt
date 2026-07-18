# 03-acceptance — RYR-FINAL result

**Claim:** RYR-FINAL — test custom syntax, quotations, generated syntax, comments, malformed files, all
applicability classes, and the frozen sample; manually review every sample finding.

**Status:** delivered. The six preview rules **FMT008–FMT013** were run over the frozen 62-module
mathlib sample through the exact frontend and every finding was reviewed by eye. The review found **one
true positive** (FMT013) and **one false positive** (FMT009); the false positive was a real correctness
bug in a shipped rule and was **fixed** here, with two regression fixtures. The category matrix the
prompt names (custom syntax, quotations, generated syntax, comments, malformed, both applicability
classes) is now closed by persistent fixtures in `tests/syntax/run.sh`. No rule was demoted; all six
remain preview.

## Frozen-sample differential run

Runner: `experiments/run-syntax-rule-sample.sh` (new). It runs `check --select FMT008 … --select
FMT013 --no-cache` under `LEAN_FMT_DISABLE_ARTIFACT=1` — the sample modules are unbuilt mathlib
sources with no formatter facet, so disabling the artifact forces the exact frontend, which
re-elaborates each single module against mathlib's prebuilt deps. For every finding it records the
module, code, byte range, message, and the exact normalized source slice the range names, so each can
be reviewed as a true or false positive.

```sh
experiments/run-syntax-rule-sample.sh          # -> experiments/results/syntax-rule-sample-<stamp>/
```

Authoritative post-fix run (`experiments/results/syntax-rule-sample-20260718T212144Z/summary.txt`):

```
modules=62
total_findings=1
  FMT008=0
  FMT009=0
  FMT010=0
  FMT011=0
  FMT012=0
  FMT013=1
broken_modules=0: []
infra_failures=0: []
seconds_total=191.2 seconds_max=14.5
```

FMT008/009/010/011/012 are zero because mathlib is heavily self-linted for their equivalents
(`linter.style.setOption`, `Mathlib.Linter` structure/style linters). FMT013 (redundant nested parens)
has **no** mathlib linter, and it is the rule whose true tree-shape rate this run measures.

## Every finding, reviewed

**FMT013 — `Mathlib/GroupTheory/NoncommPiCoprod.lean`, bytes 6977–6987 = `((ϕ i x))` — TRUE
POSITIVE.** Line 173: `(comm : ∀ i (x : N i), Commute m ((ϕ i x)))`. Every other occurrence of that
term in the file is single-parenthesised `(ϕ i x)` (lines 97, 145, 216, 232, 248); the double at line
173 is a genuine redundant outer pair. The `.safe` fix deletes bytes `6977..6978` and `6986..6987`
(the outer `(` and `)`), leaving `(ϕ i x)` — the form used everywhere else. Reviewed by reading the
byte-exact slice and the surrounding declaration; confirmed real. Evidence:
`experiments/results/syntax-rule-sample-20260718T212144Z/findings.tsv`.

**FMT009 — `Mathlib/Probability/Kernel/Deterministic.lean` (pre-fix run) — FALSE POSITIVE, now
fixed.** The pre-fix implementation popped exactly one scope per `end`, so `end Alpha.Beta` (which
closes both a `namespace Alpha` and a `namespace Beta` in one command) left one scope on the stack and
reported a spurious unclosed namespace. Fixed in `LeanFmt/Rules.lean`: `OpenScope` gained a `name`
field, and `end`-handling now pops the *group* the dotted name spells (name-stack matching) rather than
one scope per `end`. Post-fix, this module is clean and the whole sample reports FMT009=0. This was a
correctness bug in a shipped rule caught by the differential review — fixed, not worked around, per the
review's mandate.

Slice-evidence note: lean-fmt byte offsets index the CRLF→LF-normalized source (Lean `String.Pos` is a
byte position). The runner's first pass sliced the source by Python codepoint, which is wrong for the
sample's multibyte glyphs (`↦`, `·`, `ϕ`) and printed a garbage slice for the FMT013 range. The runner
now slices normalized **bytes** and decodes after; `findings.tsv` was regenerated from the saved
per-module JSON reports with the corrected logic, and the slice reads `((ϕ i x))` as it should.

## Category coverage (persistent fixtures, `tests/syntax/run.sh`)

| category | fixture(s) | asserted behaviour |
| --- | --- | --- |
| custom syntax | `CustomSyntax.lean` | `syntax "wrap(" term ")"` preserved, fires nothing |
| quotation / generated syntax | `QuoteParen.lean`, `QuoteAttr.lean` | `((1))` and `@[simp, simp]` inside `` `(…) `` fire nothing (`inQuotation` guard) |
| comments | `Comment.lean` (new) | dev `set_option`, `((paren))`, `@[simp, simp]`, `end` buried in line/block comments fire nothing — comment text is trivia, absent from the leaf walk |
| malformed | `Malformed.lean` | unparseable file is `broken`, reported without a crash or false finding |
| applicability `.safe` | `Duplicates.lean`, `NestedParen.lean` | FMT010/011/013 fix spans pinned (`42..48`, `110..116`, `51..52`+`55..56`) |
| applicability report-only | `NoModuleDoc`, `Unclosed`, `DevOption` | FMT008/009/012 fire with `fix? = none` |
| FMT009 dotted/nested scopes | `EndDotted.lean`, `ScopesBalanced.lean` (new) | `end Alpha.Beta` closing two namespaces, and a dotted namespace + named section, report nothing — the false-positive regression |
| FMT012 `set_option … in` | `ScopedInOption.lean` (new) | the inline scoped form fires FMT012 (same command node; report-only, so no byte-safety question) |

## Decisions changed / resolved during execution

1. **FMT009 name-stack matching (bug fix).** `end <dotted>` now closes the group the name spells;
   RYR-IMPL's one-pop-per-`end` was source-false for `end A.B`. Regression-pinned by `EndDotted.lean`
   and `ScopesBalanced.lean`.
2. **FMT012 `set_option … in` coverage resolved.** RYR-IMPL left open whether FMT012 should fire on the
   inline scoped form. It already does — `set_option x v in decl` is the same `Command.set_option`
   node, and FMT012 is report-only, so the scoped boundary raises no byte-safety question a fix would.
   Firing on both forms is uniform and correct; pinned by `ScopedInOption.lean`. FMT012's docstring
   already reserves byte-safety concerns for a hypothetical *fix*, which it does not have.
3. **All six stay preview.** The prompt's stop condition is "a noisy default rule blocks completion or
   moves to preview." No rule is default-on, and the one true positive in 62 modules (FMT013) is a
   correct finding, not noise — nothing forces a demotion or blocks completion.

## Commands run (exact)

```sh
LEAN_NUM_THREADS=1 lake build
lake exe lean-fmt-tests
tests/syntax/run.sh
tests/check/run.sh
tests/compiler/run.sh
tests/suppression/run.sh
tests/lossless/run.sh
tests/modes/run.sh
tests/scale/run.sh
tests/service/run.sh
tests/boundary/run.sh
experiments/run-syntax-rule-sample.sh
check_stack.py docs/projects/ruff-10-syntax-rules --structural
write_next.py docs/projects/ruff-10-syntax-rules --check
git diff --check
```

## Checks read

| check | result |
| --- | --- |
| `lake build` | exit 0 — `Build completed successfully (42 jobs).` |
| `lake exe lean-fmt-tests` | `lean-fmt module-artifact tests passed` |
| `tests/syntax/run.sh` | `lean-fmt syntax-tier rule integration tests passed` |
| `tests/check/run.sh` | `lean-fmt check integration tests passed` |
| `tests/compiler/run.sh` | `lean-fmt compiler facet tests passed` |
| `tests/suppression/run.sh` | `lean-fmt suppression acceptance tests passed` |
| `tests/lossless/run.sh` | `lean-fmt lossless projection corpus passed` |
| `tests/modes/run.sh` | `lean-fmt product mode integration tests passed` |
| `tests/scale/run.sh` | `lean-fmt complete-selection and module-evidence tests passed` |
| `tests/service/run.sh` | `lean-fmt editor service integration tests passed` |
| `tests/boundary/run.sh` | `lean-fmt native module and dependency boundary passed` |
| frozen sample | 62 modules, 0 broken, 0 infra, 191.2s; FMT013=1 (true), FMT009=0 (post-fix), rest 0 |
| `check_stack.py … --structural` | see close-out commit |
| `write_next.py … --check` | fresh for `first_unresolved` after state update |
| `git diff --check` | clean |

## Remaining uncertainty

- **FMT013 prevalence is measured but small-sample.** One true positive in 62 modules (~1.6% of
  modules) confirms the rule finds real redundancy and produces no false positives here, which supports
  keeping it a low-noise preview rule; it does not by itself justify graduation to default-on. That
  decision, with its full-corpus measurement and the default-run cost budget, belongs to
  `ruff-12-rule-lifecycle` / `ruff-19`, not this stack.
- **Canonical-coordinate syntax fix application** remains the one deferred piece. `ruff-06`'s RFX-SPEC
  froze the composition model (re-project canonical text) and handed the wiring forward to the stack
  shipping the first syntax-tier rule with a fix; the `fix`-command application is owned by the
  successor stack **`ruff-10b-syntax-fix-composition`** (scaffolded from this deferral). `check` reports
  the `.safe` fixes, `fix` does not yet apply them. Documented and pinned; not reopened in ruff-10.
- The frozen sample is 62 modules, not full mathlib (forbidden during development by `CLAUDE.md`); the
  named-stress and near-miss fixtures cover the edge shapes the corpus sample does not exercise.
