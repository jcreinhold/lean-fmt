---
kind: roadmap
topic: "Three-tier rule engine and contribution system"
main_results: [RRE-FINAL]
prereq_stacks: [ruff-01-lossless-source]
blueprint_tracked: false
---

# Three-tier rule engine and contribution system

## Goal

Replace the two-level source/syntax registry with a deep internal rule engine whose declared requirements derive the cheapest exact capability: raw source, lossless syntax, or semantic/elaboration evidence.

## Completion contract

- Rule selection is a projection over canonical facts and never selects worker, artifact, cache, or scheduling strategy.
- A rule declares metadata, required fact tier, diagnostic construction, and optional fixes without receiving application/project/cache authority.
- Compiled first-party rule contribution is simple and testable; no public runtime plugin ABI or speculative trait hierarchy is introduced.
- Mixed-tier batches produce deterministic byte-sorted findings and exact cache identities.

## Work order

1. **RRE-SPEC — Design rule facts and contribution interfaces twice.** Inventory anticipated source, syntax, import, and semantic rules. Compare function tables, namespaces, and typeclass/trait-like registration; select the shallowest contribution interface and specify fact ownership and cache boundaries.
2. **RRE-IMPL — Implement tier derivation and registry execution.** Add private source/syntax/semantic fact views, metadata, registration, deterministic execution, mixed-tier planning, and focused substitution seams. Migrate FMT001/FMT002 without behavior change.
3. **RRE-FINAL — Verify engine depth and contributor ergonomics.** Add a representative rule at each tier, mixed-selection tests, cache-collision tests, deterministic ordering, and a contributor guide. Audit common callers and remove scaffolding rules after their contracts are tested.

## Evidence and verification

Every prompt writes `results/01-design.md`-style result notes with commands, raw measurements,
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
