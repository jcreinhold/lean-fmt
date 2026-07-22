---
kind: state
first_unresolved: 01-gaps
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are `ruff-05-rule-engine`,
`ruff-05b-semantic-facts`, `ruff-06-fix-safety`, `ruff-12b-rule-graduation`, and
`ruff-20-acceptance`. Before starting, confirm those roadmaps are verified and their live
implementation still matches recorded state.

**It runs after `ruff-20-acceptance`, deliberately.** `ruff-20` holds the family's only licence to run
the complete 8,795-file mathlib corpus, and that run is the best available evidence about what Lean
code in the wild actually contains. Authoring rules first and validating them against the audit
afterwards would invert the dependency and produce rules chosen for being easy to write.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-gaps | RCT-SPEC | planned | — |
| 02-source-rules | RCT-SOURCE | planned | RCT-SPEC |
| 03-syntax-rules | RCT-SYNTAX | planned | RCT-SOURCE |
| 04-semantic-rules | RCT-SEMANTIC | planned | RCT-SYNTAX |
| 05-acceptance | RCT-FINAL | planned | RCT-SEMANTIC |

The three authoring prompts are split by tier because tier is the project's organizing axis and its
cost boundary, and because it forces each rule to be placed in the cheapest tier that can decide it
rather than the most convenient one. **A tier prompt whose selection contains no rules records that
and closes** — an empty tier is a finding about where Lean's real defects live, not a gap to be
filled by inventing work for it.

## Why this stack exists

The family's coverage contract promises "a useful rule catalog". Stacks 08-11 delivered the machinery
for one — three tiers, fix safety, suppressions, a lifecycle, a documented contribution path — and
fifteen rules across nine categories, which is enough to prove every tier works and not enough to be
the reason anyone adopts the tool.

**No stack in the family owns adding more.** Stacks 08, 09, 10, and 11 are closed; `ruff-12b` decides
the fate of what already exists; `ruff-20` audits and accepts. The catalog's size is therefore an
accident of what each machinery stack needed to demonstrate itself, and this is the first stack to
treat it as a product question.

## What the ranking must be able to do

Every rule earns its place with a count before a line of it is written. `RCT-SPEC` produces a ranked
list where each entry carries frequency, tier, false-positive risk, fix availability, and prior art.

**The field most likely to be filled in optimistically is false-positive risk**, and the candidate it
protects against is the dangerous one: a high count with no way to separate the violation from
legitimate code, where the count itself makes the rule look justified. If `RCT-SPEC` rejects nothing,
that is evidence the field was filled in optimistically rather than evidence the candidates were
good.

## Inherited constraints that shape the authoring

- **Tier cost is asymmetric and the asymmetry is measured.** `ruff-19` found one syntax-tier rule
  over four modules costing **3,283 ms in four frontend children** on an `ordinary-built` project
  against **105 ms in one facet fetch** when plugin-integrated
  (`ruff-19-performance/results/02-optimize.md`). Source tier is free on the default path.
- **The integration does not buy back semantic cost.** `ruff-19` found `format --check` on integrated
  modules recording no `official_artifacts` phase at all and four `exact_child` runs: a semantic
  demand skips the facet and goes to the frontend regardless. Generalizing the syntax-tier saving to
  the semantic tier would be wrong, and `RCT-SEMANTIC` is required to say so plainly.
- **A `Syntax` leaf walk is not a linear cover of the source.** `choice` nodes hold several parses of
  one byte range; terminal commands (`eoi`, `#exit`) never appear in the command stream. Both hit
  ordinary files — `choice` in 1 of 5 sampled mathlib modules, `#exit` in every file containing one.
  A rule assuming a flat token stream will be right on every fixture you would think to write and
  wrong on real input.
- **The module artifact holds facts, never findings.** `LeanFmt.Rules` must stay unreachable from
  `LeanFmtCompilerPlugin`, by import and by glob — Lake links every module a library globs. When the
  rules were reachable, editing one rule's message string invalidated every integrated module's Lake
  trace.
- **`ruff-19` rejected private concurrency on measurement.** No public `-j`, pinning, or strategy flag
  is available to pay for a more expensive default path.
- **No runtime third-party plugin ABI.** The coverage contract deliberately does not promise one, and
  ten new first-party rules are not the measured use case that would justify it.

## Blockers and prerequisites

- **`ruff-20-acceptance` must have run.** `RCT-SPEC` reads its audit and corpus evidence; without
  them this stack has nothing to be audit-driven by and should not start.
- **`ruff-12b-rule-graduation` must have run**, because `RCT-FINAL` places new rules against its
  frozen criteria rather than inventing a second standard.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- `ruff-20`'s recorded complete-corpus evidence may be read freely. Re-running the complete corpus
  requires that stack's authorization and is not development evidence here.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
