# Next Proof Packet

- Stack: ruff-11-semantic-rules
- First unresolved: 03-acceptance
- Claim ID: RMR-FINAL
- Prompt: 03-acceptance
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RMR-FINAL**: Run exact fresh-worker differentials, toolchain mismatch tests, stale artifacts, fix validation, mixed-tier selection, and frozen-sample time/RSS measurements.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No semantic rule may cause silent file omission on elaboration failure.
- No full mathlib run.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
