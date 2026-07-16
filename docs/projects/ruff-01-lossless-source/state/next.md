# Next Proof Packet

- Stack: ruff-01-lossless-source
- First unresolved: 02-implementation
- Claim ID: RLS-IMPL
- Prompt: 02-implementation
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLS-IMPL**: Add private modules for the immutable projection and codec. Produce it from both exact analysis and the compiler plugin/facet, validate all ranges and hashes on consumption, and migrate canonical semantic inputs without widening the public API.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Keep the compiler plugin dependency cone below application/cache/service modules.
- Add corrupt, stale, wrong-module, wrong-source, local-syntax, comment, quotation, and Unicode tests.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
