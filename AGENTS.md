# lean-fmt

A Ruff-style formatter and linter for Lean 4. The execution core is intentionally two binary crates:

- `lean-fmt` is the Lean-free application. CLI, discovery, cache, rules, edits, reports, packaging,
  and execution modules are private implementation details; it exposes no Rust library API.
- `lean-fmt-worker-child` is the sole Lean-linking artifact and the only `libleanshared` boundary.

The application spawns the child through `lean-rs-worker-parent`. Lean owns exact header
interpretation, import-dependent parsing, syntax projection, and validation. Rust owns product
policy, conservative edits, writes, and reports.

## Read first

Read this file and the topic document governing the area. The replacement roadmap is
`docs/projects/execution-core-v2/roadmap.md`; performance work is governed by
`docs/performance.md`.

## Build and verify

```sh
scripts/fmt.sh
scripts/lint.sh
scripts/test.sh
scripts/lean.sh
scripts/check-boundary.sh
```

CI uses stable Rust and the same workspace gates.

## Architecture invariants

- The workspace has exactly the `lean-fmt` and `lean-fmt-worker-child` binary crates.
- `lean-fmt` is the CLI crate and binary name. Do not create `lean-fmt-cli`.
- No application library target, public strategy DTO, single-implementor trait, pass-through facade,
  or caller-visible worker lifecycle protocol.
- Only `lean-fmt-worker-child` may depend on `lean-rs-worker-child` or link `libleanshared`.
- Parse each file under its exact ordered header/import context. Never substitute accumulated,
  sorted, deduplicated, or project-union grammar.
- Start with one worker and one Lean thread. The 8 GiB current-machine budget applies to aggregate
  parent-plus-child RSS, not independently to each process.
- `unsafe-code = "deny"`; no `unwrap`, `expect`, `panic`, `unreachable`, or direct indexing in
  non-test Rust. Test modules may opt out locally.
- No `TODO` or unimplemented production path.
- Edits remain conflict-checked and reversible. Only fix mode writes, and only after exact-context
  validation.
- Fix causes at their owning layer and update governing documentation with design changes.

## Dirty worktrees

Preserve unrelated user changes. Use `apply_patch` for source edits and never use destructive Git
commands unless explicitly requested.
