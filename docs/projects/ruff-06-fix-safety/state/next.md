# Next Proof Packet

- Stack: ruff-06-fix-safety
- First unresolved: 03-acceptance
- Claim ID: RFX-FINAL
- Prompt: 03-acceptance
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RFX-FINAL**: Test overlapping insert/delete/replace edits, UTF-8 boundaries, comment loss, promoted/demoted applicability, formatter composition, stale files, and crashes between validation and rename.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Every applied edit has rule provenance and validation evidence.
- No full mathlib run.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
