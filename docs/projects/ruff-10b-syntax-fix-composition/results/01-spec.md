# 01-spec — RYC-SPEC result

**Claim:** RYC-SPEC — specify the seam that lets `fix` apply a syntax-tier rule's `.safe` fix by
re-projecting the rendered canonical text, honoring `ruff-06`'s frozen model, without changing `check`,
cache identity, or the source-only fast path.

**Status:** delivered. The interface is frozen in `notes/01-model.md`. This is a specification prompt;
it changes no production code. It characterized the live fix lifecycle, confirmed the composition
reduces to one seam, designed that seam twice, and chose Design A.

## What was found (characterization)

The fix lifecycle already carries every mechanism except the syntax findings on canonical coordinates:

- `renderCanonicalText` (`LeanFmt/Application.lean:376-379`) runs **only** `runSourceRules text` — the
  sole gap.
- `prepareFile` builds the write patch from **`canonical.findings`** (`Application.lean:805-812`); it is
  tier-agnostic.
- Admission (`813-816`), `preparePatch`, `Edit.validateConflicts` (`Edit.lean:93`), `publishAtomic`
  (`599`), and the output re-elaboration validator (`fixFile`, `908-909`) all already operate on
  any-tier `Finding`s with `fix?`.

So the entire composition is: **put the canonical-coordinate syntax findings into
`CanonicalText.findings`.** Because those findings are computed *from the canonical projection*, their
edits are natively in canonical coordinates — ruff-06's "re-project, don't translate" is satisfied with
no byte-translation code to get wrong.

## Interface frozen (see `notes/01-model.md`)

**Design A (chosen).** When a canonical-rendering run's `plan.requiredTier == .syntax`,
`renderCanonicalText` re-projects the rendered `text` through the exact frontend
(`run.analyzeSnapshot (snapshot.withSource text) (renderCanonical := false)`) and uses that analysis's
whole-registry `result.findings` as `CanonicalText.findings`; otherwise it keeps `runSourceRules text`
unchanged. The render path threads the `ExactRun` and one bit (`needsSyntax`) down from
`ExactRun.analyzeSnapshot`; no rule or CLI code changes.

**Design B (rejected for v1).** A parse-only projection of the canonical text — cheaper (a parse, not
an elaboration, matching ruff-06's "second parse per file" phrasing) but it fabricates a projection
outside compiler evidence (`Semantic.lean:125-126`), adds coordinate surface, and duplicates registry
dispatch. Named as the optimization to reach for **only if** RYC-FINAL's frozen-sample measurement
shows Design A's elaboration cost is unacceptable.

**Gating / non-changes.** Re-projection fires only on a canonical-rendering run whose selected rules
demand syntax; source-only `fix`/`format` keep the fast path and pay no second frontend run. `check`,
`SemanticResult` cache identity, `cacheHitServes`, admission, conflict rejection, atomic publication,
and output validation are all unchanged.

**Determinism.** One order only — format, re-project, fix — so no fix-then-format vs format-then-fix
disagreement; this is why ruff-06 rejected apply-to-original-then-format.

## Adversarial obligations recorded for RYC-FINAL

Token-moving fix under re-projection; UTF-8 boundary (`((ϕ i x))`); multi-edit (FMT013's two edits);
syntax-vs-source conflict rejection with provenance; idempotence (fix → re-check clean → second fix
no-op); frozen-sample composition run with per-edit manual review. Detailed in `notes/01-model.md` §5.

## Commands run (this is a spec prompt)

```sh
# Characterization reads (evidence locators, no build):
#   LeanFmt/Application.lean:376,388,805,813,886,908,599,423,393
#   LeanFmt/Edit.lean:93 ; LeanFmt/Semantic.lean:21,104,125,151
#   LeanFmt/Rules.lean:79,88 ; LeanFmt/Config.lean:302 ; LeanFmt/Analysis.lean:107
check_stack.py docs/projects/ruff-10b-syntax-fix-composition --structural
write_next.py docs/projects/ruff-10b-syntax-fix-composition --check
git diff --check
```

## Checks read

| check | result |
| --- | --- |
| interface complete + sourced to live seams | yes — every claim cites file:line (`notes/01-model.md` §6) |
| `check_stack.py … --structural` | (recorded in close-out below) |
| `write_next.py … --check` | (recorded in close-out below) |
| `git diff --check` | (recorded in close-out below) |

## Remaining uncertainty (handed to RYC-IMPL / RYC-FINAL)

- **Elaboration cost of Design A** is unmeasured; RYC-FINAL measures it on the frozen sample and decides
  whether the Design B parse-only optimization is warranted.
- **Where exactly the `run`/`needsSyntax` thread enters** (`renderCanonicalText` signature vs a new
  helper at `analyzeSnapshot` level) is an RYC-IMPL implementation choice; the model fixes the behavior,
  not the parameter list.
- **Idempotence of a re-projected fix** (does applying FMT013's canonical fix ever expose a *new*
  nested paren?) is expected clean but must be proven by RYC-FINAL, not assumed.
