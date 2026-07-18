# Next Proof Packet

- Stack: ruff-10-syntax-rules
- First unresolved: 02-implementation
- Claim ID: RYR-IMPL
- Prompt: 02-implementation
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RYR-IMPL**: Add the approved rules, metadata, fixes, suppressions, docs inputs, and exact category dispatch without giving rules parser or application lifecycle authority.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Unknown/custom syntax is preserved and ignored unless the rule explicitly owns it.
- Deterministic ranges come from the lossless model.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
