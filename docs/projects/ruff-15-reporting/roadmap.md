---
kind: roadmap
topic: "CI and machine-readable report formats"
main_results: [RRF-FINAL]
prereq_stacks: [ruff-12-rule-lifecycle, ruff-13-config-discovery]
blueprint_tracked: false
---

# CI and machine-readable report formats

## Goal

Add concise compiler-style, GitHub annotation, SARIF, and JUnit outputs from one canonical report without contaminating semantic execution.

## Completion contract

- Renderers consume `RunReport` only and cannot trigger analysis, alter rule selection, or reorder semantic results.
- Every format preserves path, byte/line location, severity, rule code, message, fix applicability, suppression state where relevant, and infrastructure failures.
- JSON remains versioned and backward-compatible or receives an explicit schema version migration.
- Broken pipes and output-file failures map to infrastructure exit semantics without corrupt partial files.

## Work order

1. **RRF-SPEC — Map canonical reports to target formats.** Specify concise, GitHub, SARIF 2.1.0, and JUnit mappings; line/column encoding; artifact URIs; rule metadata; run failures; stdout/file behavior; and schema compatibility.
2. **RRF-IMPL — Implement pure deterministic renderers.** Add `--output-format`, optional output files with atomic replacement, format-specific golden tests, and rule metadata embedding without adding branches to application execution.
3. **RRF-FINAL — Validate formats with independent parsers.** Parse SARIF/JUnit/JSON outputs using independent validators, inspect GitHub commands and concise paths, test Unicode and failures, and benchmark large synthetic reports.

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
