# Next Proof Packet

- Stack: ruff-06-fix-safety
- First unresolved: 01-model
- Claim ID: RFX-SPEC
- Prompt: 01-model
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RFX-SPEC**: Specify applicability definitions, per-rule overrides, formatter interaction, conflict provenance, file/project atomicity, and CLI behavior for showing versus applying unsafe fixes.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not label a fix safe merely because it reparses.
- Default operation never applies unsafe fixes.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
