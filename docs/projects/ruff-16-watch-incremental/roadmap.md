---
kind: roadmap
topic: "Watch mode and changed-files workflows"
main_results: [RWI-FINAL]
prereq_stacks: [ruff-13-config-discovery, ruff-15-reporting]
blueprint_tracked: false
---

# Watch mode and changed-files workflows

## Goal

Add bounded watch mode and version-control changed-file selection without weakening normal complete-project semantics or creating a second execution engine.

## Completion contract

- Watch mode coalesces filesystem events, invalidates project/config/cache state correctly, cancels superseded work where safe, and emits one complete deterministic generation at a time.
- Changed-files mode selects from an explicit Git base/index/worktree contract and reports deleted, renamed, untracked, ignored, and out-of-root paths predictably.
- Both modes feed ordinary `execute` requests; filesystem/Git adapters own observation only.
- Queues and retained snapshots are bounded and shutdown is clean.

## Work order

1. **RWI-SPEC — Specify watch generations and Git selection.** Define event coalescing, generation identity, configuration/Lake change invalidation, output framing, signal handling, Git comparison modes, rename behavior, and failure recovery.
2. **RWI-IMPL — Implement bounded observers over execute.** Add private filesystem and Git selection adapters, bounded coalescing, generation reporting, graceful shutdown, and focused test hooks while preserving the single semantic engine.
3. **RWI-FINAL — Stress event storms and repository states.** Test rapid edits, config/lakefile changes, rename/delete, branch/index/worktree states, signals, analysis failures, stale generations, memory retention, and deterministic final output.

## Evidence and verification

Every prompt writes `results/01-contract.md`-style result notes with commands, raw measurements,
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
