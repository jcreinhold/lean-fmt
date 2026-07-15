# Next Proof Packet

- Stack: execution-core-v2
- First unresolved: 04-built-cold
- Claim ID: ECV2-BUILT-COLD
- Prompt: 04-built-cold
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Find the fastest exact path when project `.olean`s are current but no formatter artifact or cache exists. Sub-ten-minute mathlib is the goal; every meaningful improvement is retained even if current Lean cannot yet reach it.

## Reuse

- The import-only 62-file lower bound and `Mathlib.lean` union measurement.
- Lean `ImportState`, `importModulesCore`, `finalizeImport`, `EnvironmentHeader.moduleData`, persistent extensions, initializers, compacted regions, incremental snapshots, and compiler setup artifacts.

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Reject union/superset parsing, final-file grammar used retroactively, unsafe region release with live extensions, and concurrency whose configured or measured aggregate can exceed 8 GiB.
