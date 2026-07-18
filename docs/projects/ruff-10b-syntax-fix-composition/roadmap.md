---
kind: roadmap
topic: "Canonical-coordinate syntax-tier fix composition"
main_results: [RYC-FINAL]
prereq_stacks: [ruff-04-formatter-product, ruff-06-fix-safety, ruff-10-syntax-rules]
blueprint_tracked: false
---

# Canonical-coordinate syntax-tier fix composition

## Goal

Make `fix` apply a syntax-tier rule's `.safe` fix. Today `check` reports FMT010/011/013 fixes on
original coordinates, but `format`/`fix` render canonical text and run only `runSourceRules`, so a
syntax fix is reported and never applied. Close that gap by the model `ruff-06`'s RFX-SPEC already
froze — a syntax-tier fix composes by **re-projecting the canonical text**, not by translating
original-coordinate edits onto moved bytes — wired into the fix lifecycle behind the private
`Application` boundary, and exercised by the real FMT010/011/013 rules.

## Origin

`ruff-05`'s RRE-FINAL left the decision "what does `format` do with the first syntax-tier fix" to
`ruff-06`. `ruff-06`'s RFX-SPEC (`notes/01-model.md` §3, verified) froze the composition model and
explicitly handed the wiring and adversarial exercise forward: *"Syntax-tier fix composition stays
specified and unexercised until a syntax-tier rule ships (a future stack). Its adversarial cases — a
fix moving tokens under formatter re-projection — belong to that stack, with a real rule to drive
them."* `ruff-10` shipped the first such rules (FMT010/011/013) and reports their fixes, but its
roadmap scoped only rule authoring and differential review, not `fix`-command composition. This stack
is that future stack: it holds the wiring `ruff-06` specified and `ruff-10` is the first to be able to
drive with real rules.

## Completion contract

- `fix --select FMT013` (and FMT010/FMT011) on a file whose only defect is that rule's applies the
  `.safe` fix and writes the corrected file, atomically, under the existing conflict/applicability/
  transaction machinery.
- Composition is by re-projection of the rendered canonical text, never by translating original-source
  edits onto moved bytes; the applied artifact does not depend on fix-then-format vs format-then-fix
  pass order.
- Re-projection is paid only when a selected rule needs it, gated exactly as `requiredTier` already
  gates projection; a file with no selected syntax fix keeps the current source-only fast path.
- `check` behavior and the `SemanticResult` cache identity are unchanged; this stack owns the `fix`/
  `format` write path only.
- Exact ordered imports, search-path precedence, file-local syntax effects, validation identity,
  private application boundaries, and atomic writes are preserved. `check`, `format`, and `diff` never
  write source.

## Work order

1. **RYC-SPEC — Freeze the composition interface.** Characterize the current `renderCanonicalText`/fix
   path and the `ruff-06` transaction machinery. Specify the re-projection seam: when a selected rule
   is syntax-tier with a fix, parse the rendered canonical text once, run the syntax registry against
   that projection, and hand the canonical-coordinate fixes to the existing applicability/conflict/
   transaction path. Design the interface twice (re-project-in-render vs a separate post-render fix
   pass) and justify the choice against caller knowledge, exactness, cache identity, critical path, and
   determinism. Name the gating, the determinism argument, and the adversarial cases RYC-FINAL must
   drive.
2. **RYC-IMPL — Wire re-projection into the fix lifecycle.** Implement the smallest deep capability that
   applies syntax `.safe` fixes through canonical re-projection, behind the `Application` boundary,
   driven by the real FMT010/011/013 rules. Remove the deferral path rather than leaving a parallel
   one. Add or update persistent regression tests at the owning layer and retire the
   `tests/syntax/run.sh` fix-deferral pin, replacing it with an apply-and-verify assertion.
3. **RYC-FINAL — Adversarial acceptance.** Drive the cases `ruff-06` named — a fix moving tokens under
   formatter re-projection — plus UTF-8 boundaries, multi-edit fixes, syntax-vs-source fix conflicts on
   overlapping canonical ranges, idempotence (fix then re-check clean), and a frozen-sample composition
   run. Manually review every applied edit for exactness and pass-order independence.

## Evidence and verification

Every prompt writes a `results/<stem>.md` note with commands, raw measurements or evidence locators,
changed design decisions, and remaining uncertainty. Use focused fixtures, the frozen representative
mathlib sample, and named stress files. Do not run complete mathlib in this stack.

Run the affected Lean build/tests, the touched integration suites (`tests/modes/run.sh`,
`tests/syntax/run.sh`, `tests/check/run.sh`, `tests/boundary/run.sh`), this stack's structural checker,
generated-next check, and `git diff --check`. A performance record for the re-projection pass names
workload, profile, cache/build state, machine/toolchain/commit, wall time, peak aggregate RSS,
pressure, and swap delta.

## Blueprint

This is genuine formatter repository maintenance and introduces no mathematical theorem claim.
Therefore this roadmap sets `blueprint_tracked: false`.

## Stop rules

- Preserve exact ordered imports, search-path precedence, file-local syntax effects, validation
  identity, private application boundaries, and atomic writes. `check`/`format`/`diff` never write.
- Stop rather than making the applied artifact depend on fix pass order, or translating
  original-coordinate edits onto reflowed canonical bytes.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Prefer pure Lean; another language requires a named unavailable Lean capability and measured benefit.
- Do not restore workers, public strategy controls, accumulated/superset parsing, or per-file Lake
  runs. Do not give rules parser or application-lifecycle authority.
