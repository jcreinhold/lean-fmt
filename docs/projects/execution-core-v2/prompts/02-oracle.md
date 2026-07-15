---
claim_id: ECV2-ORACLE
status: planned
depends_on: [ECV2-RESET]
---

# Establish the Lean behavioral oracle

## Task

Define the smallest versioned child protocol that lets the real Lean frontend describe a file's
exact header, ordered imports, syntax/semantic projection, diagnostics, and validated edits. Build
golden oracle fixtures before optimizing the Rust execution path.

## Read

- The bundled `crates/lean-fmt/lean` package and child binary entry point.
- Lean 4 frontend APIs for header parsing, import processing, command parsing, and messages in the
  pinned toolchain.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/04-modules-should-be-deep.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/05-information-hiding-and-leakage.md`.
- `~/.codex/plugins/cache/lean-rs-skills/lean-rs-skills/0.1.1/skills/optimizing-lean-performance/SKILL.md`.

## Target

- One narrow, versioned stdin/stdout protocol owned by the child binary.
- Oracle requests preserve header import order and repeated or modified import commands exactly as
  Lean interprets them; Rust never sorts or reconstructs the context.
- Golden fixtures cover ordinary files, custom syntax, comments/docstrings, malformed headers,
  parser errors, local notation, and validation failure.
- Oracle output contains only stable data the application needs; internal Lean objects and layout
  do not leak across the process boundary.

## Stop

Stop if a proposed projection requires Rust to emulate Lean parsing or if it loses information
needed for conservative edits. Do not optimize child lifetime or context reuse yet.

## Check

- Run the child directly against every fixture and byte-compare normalized golden output.
- Prove reordered imports are distinguishable and unrelated imports never appear in a file's context.
- Run the bundled Lean package build and child protocol tests.
- `cargo clippy -p lean-fmt-worker-child --all-targets -- -D warnings`
- `git diff --check`
