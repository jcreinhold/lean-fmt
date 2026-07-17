---
kind: state
first_unresolved: 01-spec
---

# Current state

**New foundation stack, not started** (created 2026-07-17). It exists because `ruff-03`'s reflowing
formatter and `ruff-11`'s compiler-backed rules both need the same missing infrastructure — a
semantic fact tier — and neither should own infrastructure the other depends on. `ruff-05` shipped
`Tier` with `source` and `syntax` only, deliberately, and named the semantic tier as future work
(`ruff-05` state: "a tier nothing can produce is a tier nothing tests"). This stack builds it.

The first fact is declared notation/atom spacing, captured from the parser table where the frontend
`Environment` is live (`LeanFmt/CompilerPlugin.lean:27`) and carried as an immutable projection in a
bumped `ModuleArtifact` (`v3` → `v4`). It unblocks operator canonicalization and margin line-breaking
in `ruff-03` reflow; the same tier later carries `ruff-11`'s elaboration facts.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | RSF-SPEC | planned | — |
| 02-impl | RSF-IMPL | planned | RSF-SPEC |
| 03-final | RSF-FINAL | planned | RSF-IMPL |

## Design commitments (from the roadmap, to be verified in execution)

- **Facts are immutable data, never a live `Environment`.** Capture happens at the plugin producer and
  crosses the boundary as serializable spacing, matching `ruff-11`'s standing contract.
- **`Tier.semantic` is added to the engine**, folded through `requiredTier` and mixed-tier planning;
  selection stays a projection over facts.
- **Schema bumps `v3` → `v4`, additively.** The lossless `source` projection is unchanged; the
  semantic fact sits beside it and enters the digest.
- **Demand-gating is honest.** No semantic capture when nothing needs it; `format` always needs the
  notation fact, so it demands the semantic artifact — a recorded cost, not a hidden one.
- **The plugin's import closure must not grow** (`tests/boundary/run.sh` pins it): the plugin is linked
  into every target build, so the spacing lookup must use modules already in closure or the change
  stops and is recorded.

## Blockers and prerequisites

- Prerequisite stacks `ruff-01-lossless-source` and `ruff-05-rule-engine` are verified.
- If live code contradicts a prerequisite's results, reopen the owning prerequisite rather than
  patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
