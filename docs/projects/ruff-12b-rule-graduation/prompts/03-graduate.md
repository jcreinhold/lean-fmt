---
claim_id: RGR-IMPL
status: planned
depends_on: [RGR-EVIDENCE]
---

# Graduate, park, or retire — and pay the default-path cost

## Task

Deliver **RGR-IMPL**: Apply `results/02-evidence.md`'s verdicts to the catalog and the lifecycle.
Adopt `ruff-10b` Design B or refuse it with a measurement. Update the default rule set, the
documentation, `explain`, and the generated docs. Re-derive `ruff-19`'s performance gates if the
default path changed.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- Implement the task behind the existing private intent-to-report architecture; keep CLI presentation in
  `LeanFmt.Cli` and lifecycle/cache/project complexity below callers.
- A rule's tier is its `RuleImpl` constructor and never a declared field (`CLAUDE.md`). Graduating a
  rule changes `defaultEnabled` and `lifecycle`; it does not move it between tiers, and any change
  that seems to require moving one is a design change this prompt should stop on rather than absorb.
- **`ruff-10b` Design B comes due here if any of FMT008–FMT013 graduates carrying a fix.** `ruff-10b`
  named the trigger — *"if a syntax rule graduates to default and the gated re-projection lands on
  the default run cost budget"* — and `ruff-19` verified it had not yet fired. If this prompt fires
  it, adopt Design B (a parse-only projection of rendered canonical text in place of full
  re-elaboration) or refuse it with the measurement that makes Design A affordable. Refusing without
  a measurement is not available: `ruff-10b` deferred precisely to this moment.
- If the default path now demands a tier above source, `ruff-19`'s gates change meaning and must be
  re-derived rather than relaxed. `tests/performance/run.sh` §1c asserts **zero `exact_child` and
  zero `exact_setup` on a served workload**; that assertion is correct today because every default
  rule is source or import tier. If graduation breaks it, the gate is re-derived with the derivation
  recorded in the result — not deleted, and not loosened until it stops firing.
- Retirement uses the existing machinery: `reservedCodes` and the retirement notice, as `FMT001` and
  `FMT002` already do. A retired code is never reused (`LeanFmt/Rules.lean` §10 invariant 1).
- Every remaining preview rule carries its stated path out of preview, in `explain` output where a
  user will see it and not only in a result note.
- Add or update focused fixtures and persistent regression tests at the owning layer.
- Write `results/03-graduate.md` with exact commands, raw outputs or evidence locators, measurements,
  decisions changed during execution, and remaining uncertainty.
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

- Do not graduate a rule whose verdict was not "graduate". The verdicts were reached against frozen
  criteria for exactly this reason.
- Do not relax a `ruff-19` gate to accommodate a graduation. Re-derive it with a recorded derivation
  or reject the graduation.
- No public `-j`, pinning, or strategy flag.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
- Stop immediately on resource breach.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Run `tests/performance/run.sh`, `tests/catalog/run.sh`, `tests/suppression/run.sh`, and the suites
  covering every rule whose lifecycle changed.
- Run `lake exe lean-fmt docs --check` and confirm the generated rule documentation matches the catalog.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden here.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-12b-rule-graduation`.
- Run `git diff --check` and read all output before marking RGR-IMPL verified.
