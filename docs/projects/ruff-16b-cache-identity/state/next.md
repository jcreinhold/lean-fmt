# Next Proof Packet

- Stack: ruff-16b-cache-identity
- First unresolved: 01-contract
- Claim ID: RCI-SPEC
- Prompt: 01-contract
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RCI-SPEC**: Correct the `ruff-16` record, establish the whole-project-invalidation reproduction as evidence, and freeze what an entry's import closure is, where it is computed, what happens when it cannot be determined, and the differential test that separates a correct fix from a naive one.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No production Lean interface, config key, or CLI surface ships from this prompt, per the `*-SPEC` convention followed by `RWI-SPEC`, `RRF-SPEC`, `RSF-SPEC`, `RCD-SPEC`, `RRL-SPEC`, and `RMR-SPEC`.
- Do not freeze an identity whose stale-hit behavior under an unknown closure is left unstated.
- Do not correct the `ruff-16` record by deletion; an amended wrong finding is evidence about how the measurement misled, and the roadmap's evidence rule exists because of it.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
