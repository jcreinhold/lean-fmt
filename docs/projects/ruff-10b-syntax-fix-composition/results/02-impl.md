# 02-impl — RYC-IMPL result

**Claim:** RYC-IMPL — wire the RYC-SPEC seam so `fix` applies a syntax-tier rule's `.safe` fix by
re-projecting the rendered canonical text, driven by the real FMT010/011/013 rules; retire the
deferral path.

**Status:** delivered. `fix --select FMT013` (and FMT010/FMT011) now applies the fix and writes the
corrected file; `format` composes it into the previewed output; a re-`check` of the written file is
clean. All twelve build/test gates pass.

## Before (deferral reproduced)

`fix --select FMT013 tests/syntax/NestedParen.lean` left the file **byte-identical** with
`written: 0, changed: 0`, `status: clean`, FMT013 reported — the exact limit `tests/syntax/run.sh`
pinned.

## What changed (production)

Design A from `notes/01-model.md`, implemented as the smallest deep seam:

- **`LeanFmt/Application.lean` — `ExactRun.reprojectCanonical` (new).** Given a base analysis whose
  canonical text carries only source-rule findings, re-run the exact frontend on the *rendered* text
  (`snapshot.withSource canonical.text` → `run.envelope` → `canonicalAnalysis renderCanonical:=false`)
  and replace `canonical.findings` with the whole registry over that projection. The findings index the
  canonical text they came from, so every fix `Edit` is natively in canonical coordinates — no byte
  translation. A canonical text that fails to re-analyze keeps the source-only findings (never a
  fabricated fix).
- **`ExactRun.analyzeSnapshot` gains `needsSyntax : Bool := false`.** When `renderCanonical &&
  needsSyntax`, it calls `reprojectCanonical` on the base analysis; otherwise the base is untouched.
  The orchestration passes `needsSyntax := plan.requiredTier == .syntax` at the fix/format call site.
- **`availableAnalysis` gate.** When `renderCanonical && plan.requiredTier == .syntax`, it declines to
  serve from the official artifact (which projects the *original* and cannot carry canonical syntax
  findings), forcing the exact-run + re-projection path. `check` never renders canonical, so it still
  takes the artifact path.
- **`LeanFmt/Semantic.lean` — schema `v5 → v6`.** `CanonicalText.findings` now includes syntax-tier
  findings on the write path, changing what a `format`/`fix` cache entry means; the bump makes every
  pre-RYC entry miss rather than serve a source-only canonical for a syntax selection.
- **`renderCanonicalText` docstring** rewritten: the deferral it documented is closed; the doc now
  points at `reprojectCanonical`.

Nothing downstream changed: admission (`Applicability.admitted`), `preparePatch`,
`Edit.validateConflicts`, atomic publication, and the output re-elaboration validator already handle
any-tier findings — the composition reduced to populating `CanonicalText.findings`, exactly as
RYC-SPEC predicted.

## Evidence (apply-and-verify)

| rule | before | after `fix` | written | re-`check` |
| --- | --- | --- | --- | --- |
| FMT013 | `def a : Nat := ((1))` | `def a : Nat := (1)` | 1, status `fixed` | 0 findings |
| FMT010 | `@[simp, simp]` | `@[simp]` | 1, status `fixed` | 0 findings |
| FMT011 | `deriving Repr, Repr` | `deriving Repr` | 1, status `fixed` | 0 findings |

`format --select FMT013` (preview) reports `would-format` with `(1)` in the formatted text and writes
nothing. A `fix --select FMT010` on a clean file writes nothing (`status: clean`) — the fast path is
unaffected when no defect matches.

`tests/syntax/run.sh` retired the fix-deferral pin and replaced it with `fix_applies` cases asserting
written bytes and idempotent re-`check` for all three fixable rules, on in-tree probe copies the trap
removes.

## Re-projection cost (sanity)

On `NestedParen.lean` with the artifact disabled (so both runs pay the base frontend once):
source-only `format --select FMT001` 0.66 s; `format --select FMT013` (base + re-projection) 1.03 s.
The ~0.37 s delta is the single extra frontend run, paid only on a canonical-rendering syntax run, as
gated. RYC-FINAL measures this on the frozen sample and decides whether the Design B parse-only
optimization is warranted.

## Commands run

```sh
LEAN_NUM_THREADS=1 lake build            # 42 jobs, success
lake exe lean-fmt-tests                  # module-artifact tests passed
tests/syntax/run.sh                      # passed (apply-and-verify)
tests/check/run.sh tests/modes/run.sh tests/boundary/run.sh
tests/compiler/run.sh tests/suppression/run.sh tests/lossless/run.sh
tests/scale/run.sh tests/service/run.sh  # all passed
```

## Checks read

| check | result |
| --- | --- |
| `lake build` | exit 0 — `Build completed successfully (42 jobs).` |
| `lake exe lean-fmt-tests` | `lean-fmt module-artifact tests passed` |
| `tests/syntax/run.sh` | `lean-fmt syntax-tier rule integration tests passed` |
| check / modes / boundary / compiler / suppression / lossless / scale / service | all passed |
| `git diff --check` | (recorded in close-out) |

## Decisions changed during execution

1. **`availableAnalysis` gate added.** RYC-SPEC named the render-path threading as the mechanism but
   left the batch/artifact path implicit. Implementing exposed that a syntax `fix`/`format` served from
   the official artifact would render source-only canonical findings with no run to re-project; the gate
   forces the exact-run path for exactly `renderCanonical && requiredTier == .syntax`.
2. **Schema bump to v6.** Not called out in the spec; required because `CanonicalText.findings` changed
   meaning on the write path and a stale entry would otherwise serve a source-only canonical for a
   syntax selection.

## Remaining uncertainty (handed to RYC-FINAL)

- **Adversarial exercise** is owed: a token-moving fix under re-projection, a UTF-8 boundary (`ϕ`),
  FMT013's multi-edit, a syntax-vs-source conflict on overlapping canonical ranges, and a frozen-sample
  composition run with per-edit manual review.
- **Re-projection cost at corpus scale** is measured on one tiny file only; RYC-FINAL runs the frozen
  sample and decides on Design B.
