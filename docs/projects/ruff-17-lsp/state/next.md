# Next Proof Packet

- Stack: ruff-17-lsp
- First unresolved: 01-protocol
- Claim ID: RLP-PROTOCOL
- Prompt: 01-protocol
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLP-PROTOCOL**: Specify capabilities, initialization options, workspace roots, text synchronization, UTF-16 conversion, diagnostic ownership, cancellation, dynamic config, error codes, and coexistence with Lean language servers.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not advertise unsupported incremental semantics.
- Keep protocol DTOs at the boundary.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
