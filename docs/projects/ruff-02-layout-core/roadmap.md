---
kind: roadmap
topic: "Deep formatter document and layout engine"
main_results: [RLC-FINAL]
prereq_stacks: [ruff-01-lossless-source]
blueprint_tracked: false
---

# Deep formatter document and layout engine

## Goal

Build one private, general-purpose document algebra that turns formatting intent into deterministic text while hiding grouping, indentation, line-breaking, source marks, and comment attachment.

## Completion contract

- Interfaces are comments-first and designed twice; callers express logical structure, not column arithmetic or mutable printer state.
- Rendering is deterministic, width-aware, linear or demonstrably near-linear on adversarial nesting, and preserves marked source spans needed by range formatting.
- Comments attach by explicit rules derived from the lossless source model; no later language formatter invents its own comment recovery.
- Property tests cover determinism, bounded width where feasible, nesting, Unicode width policy, idempotent rendering inputs, and memory.

## Work order

1. **RLC-SPEC — Design the layout abstraction twice.** Compare at least a Wadler/Leijen-style algebra and a token-stream constraint model. Specify document constructors, group/line semantics, indentation, source marks, comment ownership, rendering complexity, and failure behavior in `notes/01-layout-design.md`.
2. **RLC-IMPL — Implement the renderer and comment attachment.** Implement the selected private algebra, bounded renderer, source-map output, and centralized leading/trailing/dangling comment attachment. Add focused unit and property tests before language-specific printers.
3. **RLC-FINAL — Audit layout depth and complexity.** Benchmark adversarial deeply nested documents and representative Lean fragments, inspect allocations/RSS, and audit all callers. Record the stable layout contract and remaining language decisions.

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
