---
kind: state
first_unresolved: 02-impl
---

# Current state

**Foundation stack; RSF-SPEC verified** (created 2026-07-17). It exists because `ruff-03`'s reflowing
formatter and `ruff-11`'s compiler-backed rules both need the same missing infrastructure — a
semantic fact tier — and neither should own infrastructure the other depends on. `ruff-05` shipped
`Tier` with `source` and `syntax` only, deliberately, and named the semantic tier as future work
(`ruff-05` state: "a tier nothing can produce is a tier nothing tests"). This stack builds it.

The first fact is declared notation/atom spacing, captured where the frontend `Environment` is live
from the notation's **registered formatter** (RSF-SPEC F1 corrected the earlier "token table" premise:
the parser trims the symbol, so only the formatter's untrimmed `sym` carries the gap), and carried as
an immutable projection in a bumped `ModuleArtifact` (`v3` → `v4`). It unblocks operator
canonicalization and margin line-breaking in `ruff-03` reflow; the same tier later carries `ruff-11`'s
elaboration facts.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | RSF-SPEC | verified | — |
| 02-impl | RSF-IMPL | planned | RSF-SPEC |
| 03-final | RSF-FINAL | planned | RSF-IMPL |

## RSF-SPEC — what it settled (`notes/01-semantic-facts.md`, `results/01-spec.md`)

- **F1 — declared spacing is a formatter pp-hint, not a token-table entry.** The parser trims the
  symbol (`Lean/Parser/Basic.lean:1114`; `Token := String`, `Types.lean:37,39`); only the formatter's
  untrimmed `sym` (`Formatter.lean:442-446`) carries the gap, which `pushToken` turns into a breakable
  `Format.line` (`Formatter.lean:412-414`). The compiler documents it as a pp-hint
  (`Init/Prelude.lean:5389`). Evidence: `evidence/01-declared-spacing.txt`. The roadmap stop-rule and
  the ruff-03 reflow note were corrected from "parser/token table" to "registered formatter."
- **F2 — no import-closure growth.** `import Lean` is already in the plugin closure
  (`ArtifactModel.lean:4`); `tests/boundary/run.sh` bans only lean-fmt's own volatile modules
  (`LeanFmt.Rules`/app), not Lean core. Reading the formatter tables is closure-legal.
- **F3/F4 — two producers, one demand-gated.** Always-on plugin
  (`CompilerPlugin.lean:26-39`) emits `semantic = none`; on-demand `analyzeExact`
  (`Analysis.lean:53-87`, final command state at line 77, currently discarded) emits `semantic = some`
  only when the run's required tier reaches `semantic`. `format` always does, so it drives a fresh
  `analyzeExact` and pays a recorded cost. This is honest demand-gating, not an always-on tax.
- **Representation chosen: Design B — per-kind ordered spacing template.** One entry per distinct
  `SyntaxNodeKind` present (atoms ordered by position), over Design A (per-node inline gaps). The
  multi-atom `«term_≃[_]_»` fixture rejects per-*token* keying: the key is (syntax-kind, atom position).
- **Specified for RSF-IMPL:** `Tier.semantic` (lattice `source ≤ syntax ≤ semantic`; formatter demand
  outside the rule fold); `ModuleArtifact.semantic : Option SemanticProjection := none` at schema
  `lean-fmt.module-artifact.v4` (additive; `v3` misses); demand-gating cost model (plugin `none`,
  `analyzeExact` `some` on demand; the semantic table is part of the digest).

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
