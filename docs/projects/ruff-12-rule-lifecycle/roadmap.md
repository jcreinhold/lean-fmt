---
kind: roadmap
topic: "Rule lifecycle, explanation, and generated documentation"
main_results: [RRL-FINAL]
prereq_stacks: [ruff-07-suppressions, ruff-08-source-rules, ruff-09-import-rules, ruff-10-syntax-rules, ruff-11-semantic-rules]
blueprint_tracked: false
---

# Rule lifecycle, explanation, and generated documentation

## Goal

Make the rule catalog discoverable and evolvable through stable/preview/deprecated lifecycle states, canonical explanations, fixability controls, and generated documentation.

## Completion contract

- One metadata source generates `rules`, `explain RULE`, configuration validation, JSON schema fragments, and human documentation.
- Stable codes never silently change meaning; experimental rules require preview; deprecated codes produce a migration path.
- Support select/extend-select/ignore, fixable/extend-fixable/unfixable, and safe/unsafe overrides with deterministic precedence.
- Detect duplicate codes, undocumented rules, invalid examples, and lifecycle contradictions at build/test time.

## Work order

1. **RRL-SPEC — Design lifecycle and selector semantics.** Specify metadata fields, stable/preview/deprecated transitions, selector prefix/category rules, configuration precedence, `explain`, and generated-doc layout. Map current codes without breaking FMT001/FMT002.
2. **RRL-IMPL — Implement registry-derived CLI and docs.** Add lifecycle-aware selection, fixability configuration, `explain`, config introspection, generated rule pages/index, and executable examples sourced from the registry.
3. **RRL-FINAL — Audit the complete rule catalog.** Run metadata invariants, example tests, selector precedence matrices, preview/deprecation migrations, suppression interaction, and documentation link checks.

## Evidence and verification

Every prompt writes `results/01-schema.md`-style result notes with commands, raw measurements,
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
