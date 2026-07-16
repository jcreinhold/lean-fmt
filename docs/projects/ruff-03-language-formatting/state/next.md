# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 02-expressions
- Claim ID: RLF-EXPRESSIONS
- Prompt: 02-expressions
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-EXPRESSIONS**: Implement precedence-aware formatting for applications, operators, binders, matches, records, projections, patterns, strings, numerals, syntax quotations, and antiquotations using parser/category information rather than textual guessing.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Parentheses may change only with a precedence proof and exact reparse validation.
- Never normalize literal contents.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
