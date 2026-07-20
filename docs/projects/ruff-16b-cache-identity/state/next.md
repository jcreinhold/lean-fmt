# Next Proof Packet

- Stack: ruff-16b-cache-identity
- First unresolved: 04-acceptance
- Claim ID: RCI-FINAL
- Prompt: 04-acceptance
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RCI-FINAL**: Exercise adversarial edit and graph shapes against the new identity, verify no stale hit under any of them, settle index accumulation and collection, and decide on measurement whether watch's per-generation re-exec comes out.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Documentation Work

Edit only the records named by the prompt. Do not execute planned mathematical or Lean prompts.

## Stop Rules

- **A stale hit is a stop, not a finding to file.** Reopen the identity.
- Do not remove watch's re-exec because the original justification was wrong; remove it only if in-process wins on measurement, since re-exec independently buys the retention `ruff-16` measured.
- Do not report invalidation improvements in wall time alone; wall time cannot distinguish a cache hit from a warm page cache, which is the error this stack exists to correct.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
