---
claim_id: RYC-IMPL
status: planned
depends_on: [RYC-SPEC]
---

# Wire re-projection into the fix lifecycle

## Task

Deliver **RYC-IMPL**: Implement the RYC-SPEC seam so `fix` applies a syntax-tier rule's `.safe` fix by
re-projecting the rendered canonical text and routing the canonical-coordinate fixes through the
existing `ruff-06` applicability/conflict/transaction path. Drive it with the real FMT010/011/013
rules; remove the deferral path instead of leaving a parallel one.

Read `results/01-spec.md`, `roadmap.md`, `AGENTS.md`, the current fix lifecycle, and the relevant
compiler/Lake sources before changing an interface. Write interface comments and characterization
tests before implementation where the behavior is not already frozen.

## Target

- Implement behind the existing private intent-to-report architecture; keep CLI presentation in
  `LeanFmt.Cli` and lifecycle/cache/project complexity below callers. `renderCanonicalText` (or its
  RYC-SPEC replacement) gains the re-projection step; the fix/publish path consumes canonical-
  coordinate syntax fixes through the `ruff-06` transaction unit.
- Gate re-projection so it runs only when a selected rule needs it, exactly as `requiredTier` gates
  projection; a file with no selected syntax fix keeps the current source-only path and pays no second
  parse.
- Preserve exact ordered imports, search-path precedence, file-local syntax effects, validation
  identity, atomic per-file publication, and cache identity. `check`, `format`, and `diff` never write
  source; only `fix` acts on the safe/unsafe distinction.
- Retire the `tests/syntax/run.sh` fix-deferral pin and replace it with an apply-and-verify assertion:
  `fix --select FMT013` on `NestedParen.lean` writes the corrected bytes, `fix --select FMT010`/`FMT011`
  on `Duplicates.lean` drop the duplicate, and a re-`check` of the written file is clean. Add or update
  focused fixtures and persistent regression tests at the owning layer (`tests/modes/run.sh`,
  `tests/syntax/run.sh`).
- Write `results/02-impl.md` with exact commands, raw outputs or evidence locators, measurements
  (the re-projection cost), decisions changed during execution, and remaining uncertainty. Update
  `state/current.md` only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Reproduce the deferral: `fix --select FMT013` on `NestedParen.lean` currently leaves the file
   byte-identical; capture that as the before-state.
2. Add the re-projection seam per RYC-SPEC and route canonical-coordinate fixes into the transaction.
3. Exercise positive, negative, malformed, custom-syntax, quotation, and Unicode cases; confirm the
   source-only fast path is unchanged when no syntax fix is selected.
4. Remove the superseded deferral path; do not retain parallel apply architectures.
5. Inspect all callers and documentation for leaked mechanism or claims stronger than evidence.

## Stop

- Unknown/custom syntax is preserved and ignored unless a rule explicitly owns it; a defect inside a
  quotation stays silent through re-projection too.
- Deterministic ranges come from the re-projected canonical model; no edit is translated onto moved
  bytes.
- Stop rather than weakening exact semantics, write safety, cache identity, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules.
- Run `tests/modes/run.sh`, `tests/syntax/run.sh`, `tests/check/run.sh`, and `tests/boundary/run.sh`,
  and inspect every changed module boundary manually.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden in this
  stack.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-10b-syntax-fix-composition`.
- Run `git diff --check` and read all output before marking RYC-IMPL verified.
