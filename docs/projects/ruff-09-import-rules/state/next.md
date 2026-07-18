# Next Proof Packet

- Stack: ruff-09-import-rules
- First unresolved: 02-implementation
- Claim ID: RIR-IMPL
- Prompt: 02-implementation
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RIR-IMPL**: Use the shared typed Lake graph and lossless header model to implement duplicate, order/group, and validated redundant-import rules plus one private organizer operation.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No per-file Lake subprocesses.
- All edits pass exact syntax and required elaboration validation.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
