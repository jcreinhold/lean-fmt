# Next Proof Packet

- Stack: execution-core-v2
- First unresolved: 02-oracle
- Claim ID: ECV2-ORACLE
- Prompt: 02-oracle
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Define the smallest versioned child protocol that lets the real Lean frontend describe a file's exact header, ordered imports, syntax/semantic projection, diagnostics, and validated edits. Build golden oracle fixtures before optimizing the Rust execution path.

## Reuse

- The bundled `crates/lean-fmt/lean` package and child binary entry point.
- Lean 4 frontend APIs for header parsing, import processing, command parsing, and messages in the pinned toolchain.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/04-modules-should-be-deep.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/05-information-hiding-and-leakage.md`.
- `~/.codex/plugins/cache/lean-rs-skills/lean-rs-skills/0.1.1/skills/optimizing-lean-performance/SKILL.md`.

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Stop if a proposed projection requires Rust to emulate Lean parsing or if it loses information needed for conservative edits. Do not optimize child lifetime or context reuse yet.
