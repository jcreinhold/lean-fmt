# Next Proof Packet

- Stack: ruff-07-suppressions
- First unresolved: 01-spec
- Claim ID: RSP-SPEC
- Prompt: 01-spec
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RSP-SPEC**: Write a grammar with inline, next-item, and file forms; define selectors, placement, formatting preservation, precedence, and malformed/unknown behavior using adversarial Lean comments.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Avoid Python `noqa` syntax if it conflicts with Lean comment conventions.
- A directive inside a string or quotation is not a comment directive.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
