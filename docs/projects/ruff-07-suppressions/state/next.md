# Next Proof Packet

- Stack: ruff-07-suppressions
- First unresolved: 02-implementation
- Claim ID: RSP-IMPL
- Prompt: 02-implementation
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RSP-IMPL**: Parse directives from lossless trivia, apply them after canonical findings, expose suppressed counts in diagnostics, and implement the unused-suppression rule and safe removal fix.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Suppression state never changes required semantic capability or cache identity.
- Infrastructure diagnostics remain unsuppressible.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
