# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 03-tactics
- Claim ID: RLF-TACTICS
- Prompt: 03-tactics
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-TACTICS**: Implement deterministic blocks for tactic scripts, bullets, case alternatives, `do`, `where`, `let`, and nested layout. Add deep nesting and comment-placement fixtures.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not conflate visual indentation with Lean offside semantics.
- Fallback must remain parse-preserving.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
