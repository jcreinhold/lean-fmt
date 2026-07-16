# Next Proof Packet

- Stack: ruff-13-config-discovery
- First unresolved: 01-semantics
- Claim ID: RCD-SPEC
- Prompt: 01-semantics
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RCD-SPEC**: Specify recognized filenames, root boundaries, closest-config selection, `extend`, path resolution, ignore precedence, explicit-path behavior, and flat-config migration with a truth table.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Executable Lake configuration remains separately evaluated; TOML config cannot stand in for project semantics.
- Cycles and unknown keys are hard errors.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
