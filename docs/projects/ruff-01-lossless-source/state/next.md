# Next Proof Packet

- Stack: ruff-01-lossless-source
- First unresolved: 01-authority
- Claim ID: RLS-SPEC
- Prompt: 01-authority
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLS-SPEC**: Inspect Lean parser `SourceInfo`, token/trivia behavior, parser extensions, quotations, and current artifact code. Write `notes/01-source-authority.md` specifying which compiler-owned data is authoritative, a versioned wire schema, invariants, and rejected alternatives. Build adversarial fixtures before implementation.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No claim may rely on `Syntax.getRange?` alone or infer comments from gaps without proving round-trip behavior.
- Record exact toolchain experiments and a byte-for-byte oracle.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
