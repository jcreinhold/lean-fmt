# Next Proof Packet

- Stack: ruff-08-source-rules
- First unresolved: 01-catalog
- Claim ID: RSR-SPEC
- Prompt: 01-catalog
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RSR-SPEC**: Characterize Lean acceptance and meaning for BOM, CRLF/mixed endings, controls, and bidirectional marks. Assign stable codes, messages, ranges, defaults, and fix applicability; reject any candidate requiring token context.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not duplicate canonical formatter policy as default lint noise.
- Security diagnostics may be report-only.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
