# Next Proof Packet

- Stack: ruff-02-layout-core
- First unresolved: 01-design
- Claim ID: RLC-SPEC
- Prompt: 01-design
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLC-SPEC**: Compare at least a Wadler/Leijen-style algebra and a token-stream constraint model. Specify document constructors, group/line semantics, indentation, source marks, comment ownership, rendering complexity, and failure behavior in `notes/01-layout-design.md`.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Select the interface by caller knowledge and whole-language fitness, not implementation familiarity.
- Do not expose renderer stacks, queues, or backtracking controls.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
