# Next Proof Packet

- Stack: ruff-14-stream-range
- First unresolved: 02-implementation
- Claim ID: RSF-IMPL
- Prompt: 02-implementation
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RSF-IMPL**: Reuse snapshot analysis and the layout source map to add stdin/stdout and range formatting, exact validation, actual-range reporting, and deterministic errors.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No second formatter or parser path.
- Unsaved input receives the same resource envelope as service requests.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
