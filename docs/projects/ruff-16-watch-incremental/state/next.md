# Next Proof Packet

- Stack: ruff-16-watch-incremental
- First unresolved: 01-contract
- Claim ID: RWI-SPEC
- Prompt: 01-contract
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RWI-SPEC**: Define event coalescing, generation identity, configuration/Lake change invalidation, output framing, signal handling, Git comparison modes, rename behavior, and failure recovery.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not make a partial changed-file run look like a complete-project clean result.
- Git absence is a clear request error.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
