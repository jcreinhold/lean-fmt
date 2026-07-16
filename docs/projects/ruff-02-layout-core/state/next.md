# Next Proof Packet

- Stack: ruff-02-layout-core
- First unresolved: 02-engine
- Claim ID: RLC-IMPL
- Prompt: 02-engine
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLC-IMPL**: Implement the selected private algebra, bounded renderer, source-map output, and centralized leading/trailing/dangling comment attachment. Add focused unit and property tests before language-specific printers.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Protect against quadratic flattening, repeated string concatenation, and unbounded alternative retention.
- Preserve every comment exactly once.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
