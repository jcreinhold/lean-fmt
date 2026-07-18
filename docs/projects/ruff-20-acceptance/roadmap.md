---
kind: roadmap
topic: "Fresh Ruff-class product acceptance"
main_results: [RCP-ACCEPT]
prereq_stacks: [ruff-18-integrations, ruff-19-performance]
blueprint_tracked: false
---

# Fresh Ruff-class product acceptance

## Goal

Audit the entire formatter, linter, workflow, architecture, correctness, packaging, and performance surface from fresh evidence and close the family only when every capability is real.

## Completion contract

- Map every row in `docs/projects/ruff-class-roadmap.md` to implementation, focused tests, documentation, and evidence with no missing or indirect claims.
- Run whole-language formatting — including the phase-2 *reflow* of over-width constructs — auditing idempotence **and** parse-tree + token-stream preservation over rebroken output (the reflow hard ceiling, enforced by `ruff-03`'s RLF-ACCEPT tree-reading differential, which a token-only gate would miss), all rule tiers, fix safety, suppressions, config, streaming/ranges, report formats, watch, LSP, integrations, packaging, and deep-module audits.
- Only a plausible release candidate runs complete already-built mathlib cold/warm acceptance; require complete sorted coverage, exact validation, under ten minutes cold as a goal, 8 GiB/pressure/swap bounds, and worker-free cache hits.
- No public application API, strategy DTO, runtime plugin ABI, temporal lifecycle protocol, duplicated semantic engine, or foreign-language architecture may have appeared.

## Work order

1. **RCP-SPEC — Perform the fresh product and architecture audit.** Read all nineteen stack roadmaps/results and every live module. Build a requirement matrix, rerun focused suites and clean-source packaging, inspect generated docs/assets, and repair root causes rather than waiving failures.
2. **RCP-ACCEPT — Run final candidate acceptance and close the family.** Run the permitted monitored 8,795-file already-built mathlib cold formatter/linter trial and immediate all-hit trial when digest rules require it; validate path count/order, idempotence and parse-tree-preservation samples over reflowed output, reports, RSS, pressure, swap, worker absence, and timing. Record final measurements and update all state.

## Evidence and verification

Every prompt writes `results/01-audit.md`-style result notes with commands, raw measurements,
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
