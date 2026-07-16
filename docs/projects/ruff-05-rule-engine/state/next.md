# Next Proof Packet

- Stack: ruff-05-rule-engine
- First unresolved: 01-design
- Claim ID: RRE-SPEC
- Prompt: 01-design
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RRE-SPEC**: Inventory anticipated source, syntax, import, and semantic rules. Compare function tables, namespaces, and typeclass/trait-like registration; select the shallowest contribution interface and specify fact ownership and cache boundaries.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No single-implementation abstraction or public registry DTO.
- Semantic facts cannot leak mutable compiler environments.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
