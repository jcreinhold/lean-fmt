---
kind: roadmap
topic: "High-confidence source rule family"
main_results: [RSR-FINAL]
prereq_stacks: [ruff-05-rule-engine, ruff-06-fix-safety]
blueprint_tracked: false
---

# High-confidence source rule family

## Goal

Deliver the raw-source rule family while keeping formatter-owned style out of lint and avoiding rules that need syntax to prevent false positives.

## Completion contract

- Preserve FMT001 and FMT002 compatibility, but document that canonical formatting subsumes their visual effect.
- Add only source-global rules with honest byte-level semantics: mixed line endings, UTF-8 BOM, forbidden control bytes, and suspicious bidirectional controls; classify fixes conservatively.
- Rules must work without syntax artifacts or frontend construction and remain linear in source size.
- Every rule has positive, negative, Unicode, malformed-source, applicability, suppression, and documentation fixtures.

## Work order

1. **RSR-SPEC — Freeze source-rule specifications.** Characterize Lean acceptance and meaning for BOM, CRLF/mixed endings, controls, and bidirectional marks. Assign stable codes, messages, ranges, defaults, and fix applicability; reject any candidate requiring token context.
2. **RSR-IMPL — Implement and document source rules.** Add the approved linear byte/string scans, registry metadata, configuration selectors, suppressions, JSON applicability, and generated rule examples.
3. **RSR-FINAL — Benchmark and audit the source family.** Run property/fuzz-style boundary tests and microbenchmarks on large files, verify worker-free execution, and record the final catalog.

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
