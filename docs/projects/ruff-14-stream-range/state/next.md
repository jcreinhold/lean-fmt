# Next Proof Packet

- Stack: ruff-14-stream-range
- First unresolved: 01-contract
- Claim ID: RSF-SPEC
- Prompt: 01-contract
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RSF-SPEC**: Specify CLI forms, filename requirements, position encoding, enclosing-node selection, comment ownership at boundaries, diagnostics, exit codes, and cache/write policy.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Reject stdin requests that cannot establish exact project identity when selected features require it.
- Never slice arbitrary bytes and parse them as an exact module.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
