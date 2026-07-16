# Next Proof Packet

- Stack: ruff-02-layout-core
- First unresolved: 03-acceptance
- Claim ID: RLC-FINAL
- Prompt: 03-acceptance
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLC-FINAL**: Benchmark adversarial deeply nested documents and representative Lean fragments, inspect allocations/RSS, and audit all callers. Record the stable layout contract and remaining language decisions.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Reject pass-through wrappers and one-constructor abstractions.
- No full mathlib run.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
