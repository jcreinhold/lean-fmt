# Next Proof Packet

- Stack: ruff-12-rule-lifecycle
- First unresolved: 01-schema
- Claim ID: RRL-SPEC
- Prompt: 01-schema
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RRL-SPEC**: Specify metadata fields, stable/preview/deprecated transitions, selector prefix/category rules, configuration precedence, `explain`, and generated-doc layout. Map current codes without breaking FMT001/FMT002.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not expose execution strategy in metadata.
- A category prefix must be unambiguous.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
