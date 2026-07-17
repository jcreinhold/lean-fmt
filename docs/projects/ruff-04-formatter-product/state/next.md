# Next Proof Packet

- Stack: ruff-04-formatter-product
- First unresolved: 03-acceptance
- Claim ID: RFP-FINAL
- Prompt: 03-acceptance
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RFP-FINAL**: Run command matrices, formatting goldens, idempotence, syntax/elaboration validation, cache invalidation, and frozen-sample timing. Publish the stable style policy and migration notes.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No full mathlib run.
- Any style change after this stack requires preview or an explicit compatibility decision.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
