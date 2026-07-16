# Next Proof Packet

- Stack: ruff-11-semantic-rules
- First unresolved: 01-authority
- Claim ID: RMR-SPEC
- Prompt: 01-authority
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RMR-SPEC**: Characterize the exact Lean 4.32 compiler APIs and diagnostics on fixtures. Specify projections, stable codes, range recovery, defaults, fixes, and toolchain-version behavior for at least four rules.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- If a compiler message lacks stable machine-readable identity, retain it as a compiler diagnostic rather than inventing a brittle rule.
- Do not promise cross-toolchain stability without evidence.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
