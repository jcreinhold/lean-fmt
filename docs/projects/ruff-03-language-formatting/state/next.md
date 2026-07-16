# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 01-commands
- Claim ID: RLF-COMMANDS
- Prompt: 01-commands
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-COMMANDS**: Add category dispatch and canonical layouts for module headers, imports, namespaces/sections, attributes, binders, declarations, structures, inductives, and command comments. Establish golden and idempotence tests.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Preserve ordered import semantics; sorting is a separate opt-in fix.
- Unknown commands must round-trip conservatively.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
