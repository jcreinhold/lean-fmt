# Next Proof Packet

- Stack: ruff-11b-owned-semantic-fix
- First unresolved: 03-final
- Claim ID: ROS-FINAL
- Prompt: 03-final
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **ROS-FINAL**: Accept the owned, fixable FMT014 and the capability split on semantics (the rename applies and re-elaborates clean, non-qualifying occurrences stay report-only), on fix safety (unsafe gating, validator, pass-order independence), on cache separation (capability demand-gating, monolithic-era miss), and on cost (the info-tree walk is paid only under the fixable demand, measured).
- Read `roadmap.md`, `notes/01-model.md`, `results/01-spec.md`, `results/02-impl.md`, `AGENTS.md`, the current implementation and tests, and the relevant Lean sources before changing an interface. Write characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No fixable semantic rule may cause silent file omission on elaboration failure, and no rename may be applied to an occurrence the frozen predicate excludes.
- The info-tree walk must not run for a demand that did not ask for the fixable capability.
- No full mathlib run in this stack.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
