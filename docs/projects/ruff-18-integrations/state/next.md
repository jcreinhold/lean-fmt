# Next Proof Packet

- Stack: ruff-18-integrations
- First unresolved: 01-contract
- Claim ID: RDI-SPEC
- Prompt: 01-contract
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RDI-SPEC**: Audit packaging constraints and write canonical command metadata, hook ordering, CI cache keys, editor launch/config mapping, version compatibility, and support policy.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not promise an editor feature the LSP does not advertise.
- No remote publishing credentials or state changes.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
