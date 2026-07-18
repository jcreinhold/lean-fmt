# Next Proof Packet

- Stack: ruff-11-semantic-rules
- First unresolved: 02-implementation
- Claim ID: RMR-IMPL
- Prompt: 02-implementation
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RMR-IMPL**: Produce immutable facts in exact analysis/compiler artifacts, execute the approved rules, classify fixes, and preserve source-only/syntax-only fast paths when no semantic rule is selected.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Semantic artifact schema and cache identity must include relevant compiler/runtime versions.
- No retained mutable environments.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
