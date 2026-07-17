# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 04-extensions
- Claim ID: RLF-EXTENSIONS
- Prompt: 04-extensions
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-EXTENSIONS**: Define the extension registration boundary for known syntax kinds and a lossless default for custom syntax. Test syntax declared earlier in the same file, scoped notation, macro quotations, and mixed built-in/custom trees.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No accumulated or superset grammar may enter acceptance.
- A formatter extension cannot gain application lifecycle authority.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
