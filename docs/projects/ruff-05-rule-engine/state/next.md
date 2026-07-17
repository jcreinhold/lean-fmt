# Next Proof Packet

- Stack: ruff-05-rule-engine
- First unresolved: 02-engine
- Claim ID: RRE-IMPL
- Prompt: 02-engine
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RRE-IMPL**: Add private source/syntax/semantic fact views, metadata, registration, deterministic execution, mixed-tier planning, and focused substitution seams. Migrate FMT001/FMT002 without behavior change.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- All source-only runs must retain the worker/artifact-free fast path when build evidence suffices.
- Unknown selectors fail clearly.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
