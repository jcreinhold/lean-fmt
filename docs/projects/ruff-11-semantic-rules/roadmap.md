---
kind: roadmap
topic: "Compiler and elaboration-backed lint rules"
main_results: [RMR-FINAL]
prereq_stacks: [ruff-05-rule-engine, ruff-05b-semantic-facts, ruff-06-fix-safety]
blueprint_tracked: false
---

# Compiler and elaboration-backed lint rules

## Goal

Expose stable compiler/elaboration facts to high-value rules such as deprecated declaration use, unused binders or declarations where Lean can prove them, and other diagnostics with precise source ownership.

The **semantic fact tier** these rules run at (`Tier.semantic`, the `Environment`-capture producer, and
the immutable semantic projection in the artifact) is **not built here** — it is the
`ruff-05b-semantic-facts` foundation, shared with `ruff-03`'s reflowing formatter. This stack's
`RMR-SPEC` characterizes the *rule-facing* semantic facts (deprecation, unused binders, …) and consumes
`ruff-05b`'s tier; it does not re-derive it. `ruff-05` shipped `Tier` without `semantic` deliberately
and pointed here; that pointer now resolves to `ruff-05b`.

## Completion contract

- Inventory Lean messages, info trees, environment extensions, and existing linters; normalize only diagnostics with stable semantics and ranges.
- Semantic rules consume immutable projections, never a mutable `Environment`, `CoreM` action, or elaborator lifecycle.
- At least four rules ship, including deprecated declaration use and unused-binder/variable diagnostics where the exact toolchain supplies trustworthy evidence.
- Compiler diagnostics and lean-fmt diagnostics deduplicate predictably and preserve original detail.

## Work order

1. **RMR-SPEC — Select semantic facts and rule catalog.** Characterize the exact Lean 4.32 compiler APIs and diagnostics on fixtures. Specify projections, stable codes, range recovery, defaults, fixes, and toolchain-version behavior for at least four rules.
2. **RMR-IMPL — Implement semantic projection and rules.** Produce immutable facts in exact analysis/compiler artifacts, execute the approved rules, classify fixes, and preserve source-only/syntax-only fast paths when no semantic rule is selected.
3. **RMR-FINAL — Verify semantics, cache separation, and cost.** Run exact fresh-worker differentials, toolchain mismatch tests, stale artifacts, fix validation, mixed-tier selection, and frozen-sample time/RSS measurements.

## Evidence and verification

Every prompt writes `results/01-authority.md`-style result notes with commands, raw measurements,
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
