---
claim_id: RCT-SOURCE
status: planned
depends_on: [RCT-SPEC]
---

# Author the source-tier rules

## Task

Deliver **RCT-SOURCE**: Write, fixture, and evidence every source-tier rule in `results/01-gaps.md`'s
selection.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- **This is the tier that is free.** A source-tier rule needs no compiler artifact and no frontend,
  so it runs on the default path at no cost above reading bytes that are already read. `ruff-19`'s
  §1c gate — zero `exact_child` and zero `exact_setup` on a served workload — stays true no matter
  how many rules land here. That makes this the tier where a rule most easily earns a default slot,
  and the tier to prefer whenever it can answer the question.
- Source-tier rules see **normalized** source. Every compiler-produced offset and digest indexes
  `raw.crlfToLf`, because `Parser.mkInputContext` normalizes before assigning any position
  (`CLAUDE.md`). A rule that reasons about raw bytes is comparing two different strings.
- The existing source-tier rules (`FMT003`, `FMT004`) are the shape to follow, and `ruff-08`'s
  results are the stack that built them.
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

- Write `results/02-source-rules.md` with exact commands, raw outputs or evidence locators,
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

- Do not author a rule that is not in `results/01-gaps.md`'s selection. Amend the list, with its
  count, or do not write it.
- If the selection contains no source-tier rules, record that and close the prompt. An empty tier is
  a finding about where Lean's real defects live, not a gap to fill by inventing work.
- Do not reach for the syntax tier because a source-tier implementation is awkward. If the question
  genuinely needs syntax, `RCT-SPEC` mis-assigned it — amend the list and say so.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Run `tests/catalog/run.sh`, `tests/suppression/run.sh`, and the suites covering the new rules.
- Run `tests/performance/run.sh`; §1c must still pass unchanged, since nothing here leaves source tier.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-21-rule-catalog`.
- Run `git diff --check` and read all output before marking RCT-SOURCE verified.
