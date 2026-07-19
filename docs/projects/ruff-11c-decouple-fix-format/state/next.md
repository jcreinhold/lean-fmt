# Next Proof Packet

- Stack: 
- First unresolved: 04-final
- Claim ID: RDF-FINAL
- Prompt: 04-final
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RDF-FINAL**: Accept the decoupling adversarially. `format`/`diff` never write or preview a rule fix at any tier; `fix` applies every fix at original coordinates and re-`check`s clean without reflowing; the two compose in both orders; the `ruff-11b` capability split and validator still hold; and the retired canonical-coordinate fix machinery is gone. Prove it through the product CLI and persistent tests at the owning layer, and by direct inspection of the surviving surface.
- Read `roadmap.md`, `notes/01-model.md`, `results/01-spec.md`, `results/02-layout.md`, `results/03-impl.md`, `AGENTS.md`, and the current implementation and tests before changing an interface. Write characterization tests before any adjustment where the behavior is not already frozen. Note RDF-LAYOUT already retired FMT001/FMT002 and gave the formatter ownership of ws/newline; the surviving fix tiers are import (FMT005), syntax (a `.safe` fix), and semantic (FMT014), and no source-tier fixable rule remains.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No `format`/`diff` write or preview of any rule fix; no `fix` reflow; no fix at canonical coordinates.
- The capability split, `Tier.satisfies` soundness, the validator, exact semantics, write safety, and cache identity must all still hold. `check`/`format`/`diff` never write.
- No full mathlib run in this stack. Stop rather than weakening any preserved invariant.
