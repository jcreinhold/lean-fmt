---
claim_id: RCT-SEMANTIC
status: planned
depends_on: [RCT-SYNTAX]
---

# Author the semantic-tier rules

## Task

Deliver **RCT-SEMANTIC**: Write, fixture, and evidence every semantic-tier rule in
`results/01-gaps.md`'s selection.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- **This is the most expensive tier, so the selection must have justified each rule explicitly.** A
  semantic rule needs `Environment` capture through `ruff-05b`'s fact tier. If a candidate arrives
  here without a recorded reason that syntax could not decide it, `RCT-SPEC` mis-assigned it — amend
  the list rather than absorbing the cost silently.
- The existing semantic-tier rules (`FMT014`–`FMT017`) are the shape to follow. `ruff-11` built them,
  `ruff-05b` built the fact tier they consume, and `ruff-11b` built the one owned semantic fix
  (`FMT014`'s rename via info-tree occurrence capture) — which is the precedent for any fix here.
- **Semantic facts are captured by the producer, and rules consume them outside the compiler.** The
  same constraint as the syntax tier applies: findings are computed in the reporting process, from
  facts. A rule that needs a fact nobody captures is a `ruff-05b` change, and that is a reopening of
  a prerequisite stack rather than something to bolt on here.
- Measure cost on both build states, as in `RCT-SYNTAX`. Semantic demand skips the artifact facet and
  goes to the frontend regardless — `ruff-19` found `format --check` on integrated modules recording
  no `official_artifacts` phase at all and four `exact_child` runs — so the integration does **not**
  buy back a semantic rule's cost the way it does a syntax rule's. Say so plainly in the result; a
  reader who generalizes the syntax-tier saving to this tier will be wrong.
- A rule's tier is its `RuleImpl` constructor and never a declared field (`CLAUDE.md`). A declared
  tier field goes unenforced and rots.
- Every rule ships with focused fixtures covering positive, negative, boundary, Unicode, and
  custom-syntax cases, and with recorded corpus firing behaviour.
- Fixes are safe and idempotent under `ruff-06`'s model, or the rule is report-only. There is no
  third option, and "probably safe" is report-only.
- Lifecycle placement is judged against `ruff-12b`'s frozen criteria
  (`ruff-12b-rule-graduation/results/01-criteria.md`). This stack does not invent a second standard.
  A rule whose evidence supports shipping default on day one may do so.
- Record, as you go, anything `docs/adding-a-rule.md` got wrong or left thin. `RCT-FINAL` collects
  those corrections, and they are only accurate if written while the authoring is fresh.

- Write `results/04-semantic-rules.md` with exact commands, raw outputs or evidence locators,
  measurements, decisions changed during execution, and remaining uncertainty.
- Update `state/current.md` only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Reproduce and characterize the current boundary relevant to this claim.
2. Design the interface twice when the prompt introduces a new abstraction; compare caller knowledge,
   invariants hidden, error surface, exactness, cache identity, critical path, and memory enforceability.
3. Implement the smallest deep capability satisfying the roadmap contract and remove superseded production
   paths rather than retaining parallel architectures.
4. Exercise positive, negative, malformed, stale, custom-syntax, Unicode, and resource cases appropriate to
   the feature.
5. Inspect all callers and documentation for leaked mechanism or claims stronger than evidence.

## Stop

- Do not author a rule that is not in `results/01-gaps.md`'s selection.
- If the selection contains no semantic-tier rules, record that and close the prompt.
- Do not add a semantic fact to `ruff-05b`'s capture to serve a rule here without reopening that
  stack. A fact added ad hoc is a second semantic engine starting.
- Do not duplicate a linter mathlib already runs over its own corpus.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Run `tests/semantic/run.sh`, `tests/catalog/run.sh`, and the suites covering the new rules.
- Run `tests/performance/run.sh` and `tests/performance/negative.sh`.
- Use the frozen sample or synthetic saved reports for scale; re-running complete mathlib needs
  `ruff-20`'s authorization.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-21-rule-catalog`.
- Run `git diff --check` and read all output before marking RCT-SEMANTIC verified.
