# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 05-corpus
- Claim ID: RLF-FINAL
- Prompt: 05-corpus
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-FINAL**: Run the generated syntax-kind inventory, repository corpus, frozen mathlib sample, malformed cases, idempotence loop, and exact fresh-frontend differential. Record unsupported constructs explicitly and eliminate them or block.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Completion requires zero silently unowned accepted syntax kinds in the frozen corpus.
- Do not run full mathlib.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
