---
claim_id: ROS-FINAL
status: verified
depends_on: [ROS-IMPL]
---

# Adversarial acceptance and the info-tree cost

## Task

Deliver **ROS-FINAL**: Accept the owned, fixable FMT014 and the capability split on semantics (the
rename applies and re-elaborates clean, non-qualifying occurrences stay report-only), on fix safety
(unsafe gating, validator, pass-order independence), on cache separation (capability demand-gating,
monolithic-era miss), and on cost (the info-tree walk is paid only under the fixable demand, measured).

Read `roadmap.md`, `notes/01-model.md`, `results/01-spec.md`, `results/02-impl.md`, `AGENTS.md`, the
current implementation and tests, and the relevant Lean sources before changing an interface. Write
characterization tests before implementation where the behavior is not already frozen.

## Target

- Implement the acceptance behind the existing private intent-to-report architecture; keep CLI
  presentation in `LeanFmt.Cli` and lifecycle/cache/project complexity below callers.
- Drive, through the product `check`/`fix` CLI and persistent tests at the owning layer:
  - **Applied rename** — `fix --select FMT014 --unsafe` on a file whose only defect is a bare-identifier
    deprecated use rewrites the occurrence to `newName?`, writes atomically, and re-`check`s clean.
  - **Unsafe gating** — without admission the fix is withheld: reported with its applicability, source
    byte-identical, no write.
  - **The fixable predicate** — dot-notation, applied-receiver, and `open`-shadowed occurrences, and
    entries with `newName? = none`, stay report-only: FMT014 is reported, no fix is offered or applied,
    and the source is unchanged.
  - **Idempotence** — a second `fix` is a no-op and a re-`check` of every written file is clean.
  - **Capability demand-gating, both directions** — the whole-file info-tree walk is absent from a plain
    `format` and from a surfaced-only FMT014 selection, and present only under the fixable demand; a
    monolithic-era cache entry misses a fixable-FMT014 demand rather than serving a false clean.
  - **Pass-order independence** — `--select` order and fix-vs-format pass order write byte-identical
    bytes.
- Measure the info-tree capture cost on a named stress file: wall time and peak aggregate RSS with the
  walk demanded vs a surfaced-only run without it, showing the walk is the demanded delta the capability
  split exists to bound, and that both stay inside the 8 GiB / pressure / swap envelope. Review the
  frozen sample read-only for any real deprecation rename and confirm it composes to exactly that defect.
- Manually review every applied rename for exactness — the occurrence text, its resolved constant, and
  the replacement — and confirm no `Environment`/`InfoTree`/`Position`/`FileMap` crosses into a rule.
- Write `results/03-final.md` with exact commands, raw outputs or evidence locators, measurements,
  decisions changed during execution, and remaining uncertainty. Update `state/current.md` only after
  reading the checks, then regenerate `state/next.md`.

## Plan

1. Reproduce and characterize the shipped capability and fix boundaries relevant to this claim.
2. Build the adversarial fixtures — bare-identifier, dot-notation, applied, `open`-shadowed,
   `newName? = none`, multi-occurrence — and the demand-gating and monolithic-era-miss cases.
3. Drive each through the product CLI and pin it with a persistent regression test at the owning layer.
4. Exercise positive, negative, malformed, stale, custom-syntax, Unicode, and resource cases, including
   the cost measurement of the info-tree walk.
5. Inspect all callers and documentation for leaked mechanism or claims stronger than evidence.

## Stop

- No fixable semantic rule may cause silent file omission on elaboration failure, and no rename may be
  applied to an occurrence the frozen predicate excludes.
- The info-tree walk must not run for a demand that did not ask for the fixable capability.
- No full mathlib run in this stack.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules
  (`tests/semantic/run.sh`, `tests/modes/run.sh`, `tests/check/run.sh`, `lake exe lean-fmt-tests`).
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden in this
  stack.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-11b-owned-semantic-fix`.
- Run `git diff --check` and read all output before marking ROS-FINAL verified.
