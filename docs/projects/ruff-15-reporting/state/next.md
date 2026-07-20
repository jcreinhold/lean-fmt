# Next Proof Packet

- Stack: ruff-15-reporting
- First unresolved: 02-renderers
- Claim ID: RRF-IMPL
- Prompt: 02-renderers
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RRF-IMPL**: Add `--output-format`, optional output files with atomic replacement, format-specific golden tests, and rule metadata embedding without adding branches to application execution.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Text/JSON defaults remain compatible.
- Renderer allocation must be bounded for project-scale reports.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
