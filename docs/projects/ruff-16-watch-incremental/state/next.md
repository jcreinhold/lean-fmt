# Next Proof Packet

- Stack: ruff-16-watch-incremental
- First unresolved: 02-implementation
- Claim ID: RWI-IMPL
- Prompt: 02-implementation
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RWI-IMPL**: Add private filesystem and Git selection adapters, bounded coalescing, generation reporting, graceful shutdown, and focused test hooks while preserving the single semantic engine.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No unbounded event queue or concurrent mutation of one Lean session.
- Do not add public job controls.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
