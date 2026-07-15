# ECV2-RESET design note

## Revisions and archive

- Recorded base: `0f1f1561b9c7974dd802de70c45cb31b01660f43`.
- Archived dirty attempt: branch `codex/archive-execution-core-attempt`, commit
  `629d157694c9cbaa4dae29323db4711b9004ee39`.
- Active replacement branch: `codex/execution-core-v2`, created from the recorded base.

The archive commit contains all 30 tracked and source-relevant untracked paths from the abandoned
attempt (1,304 insertions and 688 deletions). Its new `batch.rs`, worker fleet/budget changes,
project orchestration, cache changes, CLI sequencing, Lean project-union work, tests, and documents
are preserved together. Build artifacts and caches were excluded.

## Why this is a replacement

The abandoned design composed a project batch layer, CLI orchestration, a worker fleet, mutable
resource budgets, pinned project-union environments, cache strategy identities, and fallback paths.
The parts exposed one another's decisions, so changing memory or parsing policy amplified across
crates and callers. More importantly, a mathlib-scale attempt reached roughly 60 GiB RSS. The model
treated per-child controls as if they established a process-tree ceiling, while concurrent Lean
processes multiplied resident environments and allocator headroom.

The reset deletes the seven-crate production decomposition instead of preserving pass-through
layers. Characterization fixtures were moved under the application package, but orchestration code
was not copied into the replacement.

## Dependency and link boundary

The workspace now has exactly two packages and no library targets:

- `lean-fmt`: application package and binary, intentionally Lean-free;
- `lean-fmt-worker-child`: worker host, the only package depending on
  `lean-rs-worker-child`, and therefore the only `libleanshared` boundary.

The application may depend on `lean-rs-worker-parent` and the protocol crate because those supervise
a subprocess and do not link Lean. `scripts/check-boundary.sh` checks package count, target kinds,
manifest ownership of the linking dependency, and raw-FFI/unsafe opt-outs on every test run.

The bundled Lean capability moved to `crates/lean-fmt/lean` so the application package owns the
runtime source it must package. Its capability remains a dynamically loaded child concern; it does
not make the application a Lean-linked artifact.

## Frozen invariants

- The CLI crate and binary are named exactly `lean-fmt`; `lean-fmt-cli` does not exist.
- There is no application library API or third workspace member.
- Worker construction and lifecycle will be private, concrete, and structurally valid after open.
- Each source is interpreted under its exact ordered header/import context. No accumulated or union
  grammar is an admissible optimization.
- Runtime work begins with one child and one Lean task thread. The memory envelope is aggregate
  parent-plus-child RSS.
- Only fix mode may write, after conflict checking and exact-context validation.

## Preserved and excluded material

Preserved: repository policy, licenses, CI, scripts, lint configuration, corpus fixtures, package
metadata, and the unique process boundary. Restored capability behavior is written anew behind the
boundary. Excluded from the active production tree: every legacy CLI/project/runtime/worker/edit/
diagnostics module and all strategy-oriented tests.

The active worktree is intentionally large because the reset is staged as one coherent foundation.
The archive commit makes every pre-reset source change recoverable without leaving legacy production
modules in the active workspace.

