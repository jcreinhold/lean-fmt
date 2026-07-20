# Next Proof Packet

- Stack: ruff-13-config-discovery
- First unresolved: 02-implementation
- Claim ID: RCD-IMPL
- Prompt: 02-implementation
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RCD-IMPL**: Add one private discovery capability, Git ignore matcher, inheritance loader, formatter/linter sections, provenance, config-show command, and cache invalidation over effective values.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not perform repeated filesystem walks per file.
- Rule selection remains a result projection.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
