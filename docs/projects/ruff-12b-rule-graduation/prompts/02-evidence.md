---
claim_id: RGR-EVIDENCE
status: planned
depends_on: [RGR-SPEC]
---

# Measure all ten preview rules against the frozen criteria

## Task

Deliver **RGR-EVIDENCE**: Run each of FMT008–FMT017 over the named corpus, record firing counts,
hand-audit the stated sample of findings per rule for true and false positives, exercise every fix
for safety and idempotence, and measure the default-path cost delta on both build states. Write a
per-rule verdict against `results/01-criteria.md`.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- `results/02-evidence.md` carries one section per rule, each citing the criteria section it is
  judged against and ending in a verdict the next prompt can apply without re-deciding anything.
- **Do not revise the criteria to fit a rule.** If a criterion turns out to be wrong — not
  inconvenient, wrong — record the disagreement and how you settled it, per `CLAUDE.md`'s rule for
  records that conflict. A criterion loosened between reading a rule's counts and writing its verdict
  is worthless and worse than none, because it carries the appearance of a standard.
- Hand-auditing means reading the finding against the source it fired on and judging whether a
  competent Lean author would call it correct. Record the audited findings, or a reproducible locator
  for them, in `evidence/`. A count without an audit is not evidence about correctness; it is
  evidence about volume.
- **Report zero-firing rules as a finding, not a pass.** A rule that never fires on 62 mathlib
  modules and the stress files has not demonstrated it is safe; it has demonstrated the corpus does
  not exercise it. Say which, and if the rule needs a focused fixture to fire at all, that is
  information about whether it earns a default slot.
- The fix audit covers the five fixable rules. For each: is the fix safe under `ruff-06`'s
  definition, is it idempotent, does re-running `fix` converge, and does the result still parse and
  elaborate. `ruff-10b`'s composition tests and `tests/syntax/run.sh` are the existing machinery.
- The cost measurement uses `ruff-19`'s workload definitions and profile channel. Measure the default
  path with the current five rules, then with each candidate graduated set, on **`ordinary-built`
  and `formatter-integrated-built`** (`ruff-19-performance/evidence/01-workloads.md` §3.1 defines the
  integrated workload and how to reach it). Report `phase.official_artifacts_ms`, `phase.exact_child_ms`
  counts, and `cache.index_hits`, not just wall time — `ruff-19`'s variance policy applies here in
  full, and a wall-time comparison under load will not survive review.

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

- Do not change any rule's implementation to make it pass. A rule that needs a fix to graduate is a
  rule whose verdict is "not yet, and here is the defect" — record it and let a later stack own the
  repair, or open one against this stack if it is small and in scope.
- Do not change `defaultEnabled` or `lifecycle` on any rule here. That is `RGR-IMPL`.
- No full mathlib run; the frozen sample and named stress files only.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Run `tests/performance/run.sh` and the suites covering the rules exercised.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden here.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-12b-rule-graduation`.
- Run `git diff --check` and read all output before marking RGR-EVIDENCE verified.
