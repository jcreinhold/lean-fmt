# Next Proof Packet

- Stack: ruff-05b-semantic-facts
- First unresolved: 03-final
- Claim ID: RSF-FINAL
- Prompt: 03-final
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RSF-FINAL**: prove the notation-spacing fact matches Lean's own spacing, that the schema bump keeps cache identity exact, that demand-gating leaves the syntax-only path untouched when nothing semantic is needed, and that the cost is within budget. This is the foundation's acceptance; its consumers (`ruff-03` reflow, `ruff-11` rules) build on what it certifies here.
- Read `roadmap.md`, `notes/01-semantic-facts.md`, both prior result notes, `AGENTS.md`, and the relevant Lean compiler sources. This is an audit prompt: it adds tests and evidence and changes production code only to fix a defect it finds.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Completion requires the differential to pass for core *and* a corpus-declared notation, and the demand-gating fast path to be proven, not assumed.
- No full mathlib run.
- Stop rather than weakening exact semantics, cache identity, write safety, or the resource envelope.
