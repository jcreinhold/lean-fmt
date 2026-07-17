---
claim_id: RSF-FINAL
status: verified
depends_on: [RSF-IMPL]
---

# Verify the semantic fact, cache separation, and cost

## Task

Deliver **RSF-FINAL**: prove the notation-spacing fact matches Lean's own spacing, that the schema
bump keeps cache identity exact, that demand-gating leaves the syntax-only path untouched when nothing
semantic is needed, and that the cost is within budget. This is the foundation's acceptance; its
consumers (`ruff-03` reflow, `ruff-11` rules) build on what it certifies here.

Read `roadmap.md`, `notes/01-semantic-facts.md`, both prior result notes, `AGENTS.md`, and the relevant
Lean compiler sources. This is an audit prompt: it adds tests and evidence and changes production code
only to fix a defect it finds.

## Target

- **Fresh-frontend differential.** For core notations and at least one corpus-declared notation,
  assert the captured declared spacing equals what Lean's own `pushToken` emits — the fact is the
  compiler's, not this stack's guess. Record the comparison harness and its output.
- **Cache separation.** A `v4` artifact has a distinct, stable digest; a `v3` artifact is a clean miss;
  editing an unrelated rule's prose does not perturb the semantic fact's bytes (the `ruff-05`
  invariant). Pin each.
- **Demand-gating.** With no semantic rule selected and no format requested, no semantic capture runs
  and the artifact carries `semantic = none` (its `source` projection byte-identical to the pre-`v4`
  content; only the schema tag advances to `v4`). With a format requested, `analyzeExact` runs the
  capture and the fact is present (`semantic = some`), and a cached `semantic = none` artifact is
  rejected rather than silently accepted. Prove all three: no-capture fast path, present-on-format, and
  cache rejection.
- **Cost envelope.** Time and peak aggregate RSS for semantic capture on the frozen representative
  sample, against the syntax-only baseline; name workload, machine, toolchain, commit, wall time, RSS,
  pressure, swap delta. Stay within 8 GiB / 256 MiB-swap.
- Add or update persistent regression tests and a mutation check that the differential is non-vacuous
  (a deliberately wrong captured spacing must fail it).
- Write `results/03-final.md`; update `state/current.md` after reading checks; regenerate
  `state/next.md`.

## Plan

1. Build the `pushToken` differential harness; run it on core and corpus-declared notations.
2. Pin schema/cache identity: `v4` digest, `v3` miss, rule-prose independence.
3. Prove demand-gating both directions (nothing-needed fast path; format demands the fact).
4. Measure and record the cost envelope against the baseline.
5. Mutation-test the differential; inspect callers/docs for claims stronger than evidence.

## Stop

- Completion requires the differential to pass for core *and* a corpus-declared notation, and the
  demand-gating fast path to be proven, not assumed.
- No full mathlib run.
- Stop rather than weakening exact semantics, cache identity, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the full artifact/engine suites plus any harness added.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Use the frozen sample for scale; complete mathlib is forbidden.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-05b-semantic-facts`.
- Run `git diff --check` and read all output before marking RSF-FINAL verified.
