# Next Proof Packet

- Stack: ruff-08-source-rules
- First unresolved: 03-acceptance
- Claim ID: RSR-FINAL
- Prompt: 03-acceptance
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RSR-FINAL**: Run property/fuzz-style boundary tests and microbenchmarks on large files, verify worker-free execution, and record the final catalog.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Remove rules whose false-positive policy is not defensible.
- No full mathlib run.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
