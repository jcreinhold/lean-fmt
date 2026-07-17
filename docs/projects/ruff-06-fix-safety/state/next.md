# Next Proof Packet

- Stack: ruff-06-fix-safety
- First unresolved: 02-transaction
- Claim ID: RFX-IMPL
- Prompt: 02-transaction
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RFX-IMPL**: Extend findings, reports, configuration, edit planning, validation, and atomic publication. Add fix-only/unfixable selection without coupling rule selection to execution strategy.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Preserve stale-source and permission checks.
- No partial write on conflict or rejected validation.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
