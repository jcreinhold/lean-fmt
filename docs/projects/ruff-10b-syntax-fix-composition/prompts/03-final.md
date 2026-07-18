---
claim_id: RYC-FINAL
status: verified
depends_on: [RYC-IMPL]
---

# Adversarial acceptance for syntax-fix composition

## Task

Deliver **RYC-FINAL**: Drive the adversarial cases `ruff-06` handed forward — a fix moving tokens under
formatter re-projection — plus UTF-8 boundaries, multi-edit fixes, syntax-vs-source conflicts on
overlapping canonical ranges, idempotence, and a frozen-sample composition run. Manually review every
applied edit for exactness and pass-order independence.

Read `results/01-spec.md`, `results/02-impl.md`, `roadmap.md`, `AGENTS.md`, the implemented lifecycle,
and `ruff-06-fix-safety/results/03-acceptance.md` (the cases it named as owed) before changing an
interface. Write characterization tests before implementation where the behavior is not already frozen.

## Target

- Implement the review behind the existing private intent-to-report architecture; keep CLI presentation
  in `LeanFmt.Cli` and lifecycle/cache/project complexity below callers.
- Add or update focused fixtures and persistent regression tests at the owning layer for each
  adversarial case.
- Write `results/03-final.md` with exact commands, raw outputs or evidence locators, measurements,
  decisions changed during execution, and remaining uncertainty. Update `state/current.md` only after
  reading the checks, then regenerate `state/next.md`.

## Plan

1. Reproduce and characterize the composed fix path RYC-IMPL delivered.
2. Construct the adversarial fixtures: a syntax fix whose canonical re-projection moves the fixed
   tokens (so a byte-translation approach would corrupt them), a fix at a multibyte-glyph boundary, and
   a multi-edit fix. For the mixed-tier conflict, note that the shipped rules are disjoint by design —
   the only source `.safe` fixes (`FMT001` trailing whitespace, `FMT002` final newline, `FMT005`
   duplicate import) edit whitespace/import/EOF bytes that cannot intersect a term-paren or attribute
   range, so no file produces a natural syntax-vs-source overlap. Exercise the conflict path at its
   owning layer instead (`Edit.preparePatch`/`validateConflicts`, tested in `LeanFmtTest.lean` as
   `ruff-06` established for conflict cases): feed an overlapping finding set carrying a syntax code
   (`FMT013`) and a source code (`FMT001`) and assert the conflict rejects with provenance naming both
   rules.
3. Assert idempotence: applying the fix and re-running `check` on the written file yields no finding,
   and a second `fix` is a no-op.
4. Run the frozen sample through the composed path; manually review every applied edit for exactness
   and pass-order independence (fix-then-format vs format-then-fix agree).
5. Inspect callers and documentation for leaked mechanism or claims stronger than evidence.

## Stop

- A composed fix that corrupts bytes, depends on pass order, or writes under a failed validation blocks
  completion.
- No full mathlib run.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules.
- Run `tests/boundary/run.sh`, `tests/modes/run.sh`, and `tests/syntax/run.sh`, and inspect every
  changed module boundary manually.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden in this
  stack.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-10b-syntax-fix-composition`.
- Run `git diff --check` and read all output before marking RYC-FINAL verified.
