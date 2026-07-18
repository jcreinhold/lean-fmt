# Next Proof Packet

- Stack: ruff-10b-syntax-fix-composition
- First unresolved: 03-final
- Claim ID: RYC-FINAL
- Prompt: 03-final
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RYC-FINAL**: Drive the adversarial cases `ruff-06` handed forward — a fix moving tokens under formatter re-projection — plus UTF-8 boundaries, multi-edit fixes, syntax-vs-source conflicts on overlapping canonical ranges, idempotence, and a frozen-sample composition run. Manually review every applied edit for exactness and pass-order independence.
- Read `results/01-spec.md`, `results/02-impl.md`, `roadmap.md`, `AGENTS.md`, the implemented lifecycle, and `ruff-06-fix-safety/results/03-acceptance.md` (the cases it named as owed) before changing an interface. Write characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- A composed fix that corrupts bytes, depends on pass order, or writes under a failed validation blocks completion.
- No full mathlib run.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
