# Next Proof Packet

- Stack: ruff-10b-syntax-fix-composition
- First unresolved: 02-impl
- Claim ID: RYC-IMPL
- Prompt: 02-impl
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RYC-IMPL**: Implement the RYC-SPEC seam so `fix` applies a syntax-tier rule's `.safe` fix by re-projecting the rendered canonical text and routing the canonical-coordinate fixes through the existing `ruff-06` applicability/conflict/transaction path. Drive it with the real FMT010/011/013 rules; remove the deferral path instead of leaving a parallel one.
- Read `results/01-spec.md`, `roadmap.md`, `AGENTS.md`, the current fix lifecycle, and the relevant compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Unknown/custom syntax is preserved and ignored unless a rule explicitly owns it; a defect inside a quotation stays silent through re-projection too.
- Deterministic ranges come from the re-projected canonical model; no edit is translated onto moved bytes.
- Stop rather than weakening exact semantics, write safety, cache identity, or the resource envelope.
