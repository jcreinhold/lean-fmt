---
kind: roadmap
topic: "Lean import organization and redundancy"
main_results: [RIR-FINAL]
prereq_stacks: [ruff-01-lossless-source, ruff-05-rule-engine, ruff-06-fix-safety]
blueprint_tracked: false
---

# Lean import organization and redundancy

## Goal

Provide deterministic duplicate-import detection, canonical organization, and sound redundant-import diagnostics without changing import order when order can affect syntax or elaboration.

## Completion contract

- Duplicate removal is safe only when exact ordered header behavior is unchanged; ordering/grouping fixes are separate and validated.
- Redundancy uses the exact Lake module graph plus a proof that removing an import preserves required direct dependencies; heuristic reachability is never called semantic equivalence.
- Import rewrites preserve header comments, attributes/modifiers, blank-group policy, and file-local syntax behavior.
- Expose an organize-imports capability usable by CLI and LSP without exposing graph internals.

## Work order

1. **RIR-SPEC — Characterize Lean import-order and redundancy semantics.** Build fixtures for duplicated imports, transitive imports, scoped syntax, plugins, preludes, modifiers, and comments. Specify IMP rule codes, canonical grouping, safety, and cases that remain report-only.
2. **RIR-IMPL — Implement import diagnostics and organizer.** Use the shared typed Lake graph and lossless header model to implement duplicate, order/group, and validated redundant-import rules plus one private organizer operation.
3. **RIR-FINAL — Differentially verify import changes.** Run fresh exact-context before/after differentials, comment preservation, plugin/prelude cases, suppressions, fix conflicts, and frozen-sample performance.

## Evidence and verification

Every prompt writes `results/01-semantics.md`-style result notes with commands, raw measurements,
changed design decisions, and remaining uncertainty. Use focused fixtures, the frozen representative
mathlib sample, and named stress files. Do not run complete mathlib in this stack unless this is the
final acceptance stack and its prompt explicitly authorizes it.

Run the affected Lean build/tests, `tests/boundary/run.sh`, this stack's structural checker, generated-next
check, and `git diff --check`. Performance records name workload, profile, cache/build state,
machine/toolchain/commit, wall time, peak aggregate RSS, pressure, and swap delta.

## Blueprint

This is genuine formatter repository maintenance and introduces no mathematical theorem claim.
Therefore this roadmap sets `blueprint_tracked: false`.

## Stop rules

- Preserve exact ordered imports, search-path precedence, file-local syntax effects, validation identity,
  private application boundaries, and atomic writes.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Prefer pure Lean; another language requires a named unavailable Lean capability and measured benefit.
- Do not restore workers, public strategy controls, accumulated/superset parsing, or per-file Lake runs.
