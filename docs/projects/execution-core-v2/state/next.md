# Next Proof Packet

- Stack: execution-core-v2
- First unresolved: 05-compiler-artifacts
- Claim ID: ECV2-COMPILER-ARTIFACTS
- Prompt: 05-compiler-artifacts
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Turn the module-linter probe into a pure Lean compiler plugin that runs rules over the exact syntax while Lean already owns the correct environment and emits a compact, sound sidecar.

## Reuse

- `experiments/pure-lean-core/LeanFmtProbePlugin.lean` and its recorded timings.
- Lean `Command.ModuleLinter`, plugin loading, file maps, module setup, and Lake build traces.

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not trust source mtimes, omit plugin identity from the build trace, or let an artifact claim a validation level it did not execute.
