# Next Proof Packet

- Stack: ruff-11b-owned-semantic-fix
- First unresolved: 02-impl
- Claim ID: ROS-IMPL
- Prompt: 02-impl
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **ROS-IMPL**: Capture the owned deprecation-occurrence fact from the whole-file info trees under demand, ship FMT014's `unsafe` rename through `ruff-06`'s fix machinery, and add the capability split so the info-tree walk is paid only when the fix is demanded — implementing the interface ROS-SPEC froze, without changing the surfaced FMT014 report or the source/syntax/semantic fast paths.
- Read `roadmap.md`, `notes/01-model.md` and `results/01-spec.md` (the frozen interface), `AGENTS.md`, and the live implementation and tests before changing an interface. Write the interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- The artifact and `SemanticResult` schema and cache identity must include the compiler/runtime version and the captured capabilities.
- No retained mutable environment; the owned occurrence fact is immutable data.
- A rename must never be applied to an occurrence the frozen predicate excludes, and the info-tree walk must never run for a demand that did not ask for the fixable capability.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
