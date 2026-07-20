# Next Proof Packet

- Stack: ruff-16b-cache-identity
- First unresolved: 03-implementation
- Claim ID: RCI-IMPL
- Prompt: 03-implementation
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RCI-IMPL**: Implement the modelled decision in `LeanFmt.Cache`, matching `LeanFmt/Cache/Spec.lean`'s `serves`, expose from `LeanFmt.Project` only what supplying the closure requires, land the mutation-checked stale-hit differential, and measure one-file-edit invalidation at entry granularity.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Documentation Work

Edit only the records named by the prompt. Do not execute planned mathematical or Lean prompts.

## Stop Rules

- **A stale hit is a stop.** If any exercised edit shape serves a cached result disagreeing with fresh analysis, stop and reopen `RCI-SPEC`'s identity rather than narrowing the test around it.
- Do not widen the cache's public surface; `ResultCache` stays constructed only through `open?`.
- Do not weaken `open?`'s refusal to manufacture a partial epoch to make invalidation cheaper.
- Do not defer the watch re-exec decision here by removing it opportunistically; `RCI-FINAL` owns it on measurement.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
