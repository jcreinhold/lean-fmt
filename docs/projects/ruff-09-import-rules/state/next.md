# Next Proof Packet

- Stack: ruff-09-import-rules
- First unresolved: 01-semantics
- Claim ID: RIR-SPEC
- Prompt: 01-semantics
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RIR-SPEC**: Build fixtures for duplicated imports, transitive imports, scoped syntax, plugins, preludes, modifiers, and comments. Specify IMP rule codes, canonical grouping, safety, and cases that remain report-only.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Stop if an ordering rule cannot preserve exact syntax; keep it opt-in or display-only.
- Do not infer redundancy solely from graph reachability.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
