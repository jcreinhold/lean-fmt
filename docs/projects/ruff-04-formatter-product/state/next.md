# Next Proof Packet

- Stack: ruff-04-formatter-product
- First unresolved: 02-integration
- Claim ID: RFP-IMPL
- Prompt: 02-integration
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RFP-IMPL**: Connect canonical formatting to reports, diffs, cache identity, exact validation, conflict planning, stale checks, and permission-preserving publication. Ensure formatter-only checks avoid semantic capabilities not required by the source.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- A partially formatted project is never published as a successful atomic operation where project atomicity was requested.
- Rejected validation never writes.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
