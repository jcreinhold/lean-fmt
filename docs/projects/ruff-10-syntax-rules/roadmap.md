---
kind: roadmap
topic: "Exact-syntax lint rule family"
main_results: [RYR-FINAL]
prereq_stacks: [ruff-01-lossless-source, ruff-05-rule-engine, ruff-06-fix-safety]
blueprint_tracked: false
---

# Exact-syntax lint rule family

## Goal

Add a curated high-value syntax rule family for documentation, namespace structure, redundant syntax, and maintainability while preserving custom syntax and avoiding proof-style dogma.

## Completion contract

- Begin with a written catalog of at least six rules selected from corpus evidence, including module documentation, namespace/module consistency, duplicate attributes/modifiers, and mechanically redundant syntax.
- Every rule names exact syntax kinds/categories, false-positive exclusions, default/preview state, and applicability.
- Style already enforced by canonical formatting is not duplicated as lint.
- Unsafe proof or term simplifications require elaboration validation and are preview or display-only by default.

## Work order

1. **RYR-SPEC — Freeze the syntax-rule catalog from corpus evidence.** Inventory compiler syntax kinds and existing Lean/mathlib linters, sample real defects, and specify at least six stable or preview rules with codes, examples, exclusions, and fix safety.
2. **RYR-IMPL — Implement syntax rules over immutable facts.** Add the approved rules, metadata, fixes, suppressions, docs inputs, and exact category dispatch without giving rules parser or application lifecycle authority.
3. **RYR-FINAL — Run differential and false-positive review.** Test custom syntax, quotations, generated syntax, comments, malformed files, all applicability classes, and the frozen sample; manually review every sample finding.

## Evidence and verification

Every prompt writes `results/01-catalog.md`-style result notes with commands, raw measurements,
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
