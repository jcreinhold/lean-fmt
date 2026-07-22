---
claim_id: RCT-FINAL
status: planned
depends_on: [RCT-SEMANTIC]
---

# Accept the expanded catalog

## Task

Deliver **RCT-FINAL**: Place every new rule in the lifecycle against `ruff-12b`'s criteria, accept the
catalog on corpus evidence, measure the shipped default path on both build states, reconcile the
documentation surface, and correct `docs/adding-a-rule.md` from what authoring ten rules actually
required.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- `results/05-acceptance.md` records the catalog as shipped: every rule, its tier, lifecycle, default
  status, fixability, and — for anything in preview — the condition that would graduate it. It must be
  readable without the four prior result notes, because it is what a later reader will actually open.
- Lifecycle placement uses `ruff-12b-rule-graduation/results/01-criteria.md`. If a new rule's evidence
  meets the default standard, it ships default; if it does not, it ships preview **with its stated
  path out**. A preview rule with no condition attached is how the catalog got into the state
  `ruff-12b` existed to fix, and repeating that here would be the same mistake with fresher rules.
- **Correct `docs/adding-a-rule.md` from experience, not from review.** Ten consecutive authorings
  are the best test that document will ever get: every place it was wrong, thin, or silent about
  something you had to discover is a defect with a known repair. `RCT-SOURCE` through `RCT-SEMANTIC`
  recorded those as they went; this prompt applies them.
- Measure the shipped default path on `ordinary-built` and `formatter-integrated-built` under
  `ruff-19`'s workload definitions, with its variance policy in full: median of at least three, never
  the first run, spread reported beside the median, machine conditions recorded. Report a before/after
  against the pre-stack catalog on the same workloads.
- `ruff-19`'s gates pass as shipped, or any re-derived gate carries its derivation and has been
  re-proven to discriminate via `tests/performance/negative.sh`.
- Reconcile every surface: `lean-fmt rules`, `lean-fmt explain` for every live and retired code, the
  generated docs, `docs/adding-a-rule.md`, and **every rule count quoted in repository prose**. A
  quoted count that drifts is the kind of small false claim that makes a reader distrust the large
  true ones, and this stack changes a number that appears in several places.
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

- Do not ship a new rule to preview without its stated path out of preview.
- Do not accept a catalog whose shipped behaviour differs from the authoring prompts' measurements
  without explaining the difference.
- Do not relax a `ruff-19` gate; re-derive with a recorded derivation or reconsider the rule.
- Re-running the complete corpus needs `ruff-20`'s authorization.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build`, `lake lint`, `lake exe lean-fmt-tests`, and every suite in
  `tests/*/run.sh`.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Run `tests/performance/run.sh` and `tests/performance/negative.sh`.
- Run `lake exe lean-fmt docs --check`.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-21-rule-catalog`.
- Run `git diff --check` and read all output before marking RCT-FINAL verified.
