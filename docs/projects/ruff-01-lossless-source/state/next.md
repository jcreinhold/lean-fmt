# Next Proof Packet

- Stack: ruff-01-lossless-source
- First unresolved: 03-acceptance
- Claim ID: RLS-FINAL
- Prompt: 03-acceptance
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLS-FINAL**: Run the round-trip/differential corpus, frozen sample, artifact invalidation matrix, module boundary guard, and size/time/RSS profile. Remove redundant DTOs and document the selected interface.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Require byte-identical reconstruction for every successful case.
- Do not run full mathlib; stop on the existing resource gates.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
