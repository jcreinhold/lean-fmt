# Next Proof Packet

- Stack: ruff-08-source-rules
- First unresolved: 02-implementation
- Claim ID: RSR-IMPL
- Prompt: 02-implementation
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RSR-IMPL**: Add the approved linear byte/string scans, registry metadata, configuration selectors, suppressions, JSON applicability, and generated rule examples.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No parser or project capability in source-rule implementations.
- Avoid repeated UTF-8 decoding.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
