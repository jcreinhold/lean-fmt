# Next Proof Packet

- Stack: ruff-12-rule-lifecycle
- First unresolved: 02-generation
- Claim ID: RRL-IMPL
- Prompt: 02-generation
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RRL-IMPL**: Add lifecycle-aware selection, fixability configuration, `explain`, config introspection, generated rule pages/index, and executable examples sourced from the registry.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Generated output must be deterministic and checked for drift.
- Unknown/deprecated selectors fail or warn exactly as specified.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
