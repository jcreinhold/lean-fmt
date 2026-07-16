# Next Proof Packet

- Stack: ruff-19-performance
- First unresolved: 01-baseline
- Claim ID: RPR-SPEC
- Prompt: 01-baseline
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RPR-SPEC**: Record machine/toolchain/commit, fixture manifests, cache/build states, binary digest, phase schema, expected output digests, latency/RSS/pressure/swap gates, and stop rules.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not compare debug and release profiles.
- Do not hide prerequisite project builds in formatter cold time.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
