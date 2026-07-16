---
kind: roadmap
topic: "Stable formatter product semantics"
main_results: [RFP-FINAL]
prereq_stacks: [ruff-03-language-formatting]
blueprint_tracked: false
---

# Stable formatter product semantics

## Goal

Integrate canonical formatting into the private intent-to-report operation with a deliberately small stable style surface and unambiguous non-writing previews versus atomic writes.

## Completion contract

- Formatting is a canonical transformation distinct from selectable lint rules and therefore does not enter rule selection.
- `check`, `format`, and `diff` remain read-only; `fix` is the sole source writer and may apply formatting plus selected fixes in one validated atomic patch.
- Expose only line width, indentation style/width, line ending policy, and explicitly justified language options; avoid a knob for every layout decision.
- Formatting and lint diagnostics compose deterministically without duplicate edits or order-dependent output.

## Work order

1. **RFP-SPEC — Freeze formatting policy and CLI semantics.** Write the style guide, configuration schema, command truth table, exit behavior, and formatter/linter interaction. Characterize compatibility consequences for existing commands and name any migration aliases.
2. **RFP-IMPL — Integrate formatter output and atomic publication.** Connect canonical formatting to reports, diffs, cache identity, exact validation, conflict planning, stale checks, and permission-preserving publication. Ensure formatter-only checks avoid semantic capabilities not required by the source.
3. **RFP-FINAL — Establish stable formatter behavior.** Run command matrices, formatting goldens, idempotence, syntax/elaboration validation, cache invalidation, and frozen-sample timing. Publish the stable style policy and migration notes.

## Evidence and verification

Every prompt writes `results/01-policy.md`-style result notes with commands, raw measurements,
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
