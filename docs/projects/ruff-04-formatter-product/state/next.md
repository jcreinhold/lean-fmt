# Next Proof Packet

- Stack: ruff-04-formatter-product
- First unresolved: 01-policy
- Claim ID: RFP-SPEC
- Prompt: 01-policy
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RFP-SPEC**: Write the style guide, configuration schema, command truth table, exit behavior, and formatter/linter interaction. Characterize compatibility consequences for existing commands and name any migration aliases.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not let formatter policy enter semantic cache identity unless it changes output.
- Do not expose layout-engine mechanisms.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
