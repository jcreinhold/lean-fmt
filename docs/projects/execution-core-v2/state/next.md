# Next Proof Packet

- Stack: execution-core-v2
- First unresolved: 03-workloads
- Claim ID: ECV2-WORKLOADS
- Prompt: 03-workloads
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Define the exact formatter oracle and four non-interchangeable workloads before selecting an execution strategy: ordinary project built with current `.olean`s, formatter-integrated build artifacts present, formatter cache cold, and formatter cache warm.

## Reuse

- `notes/02-architecture-pause.md` and `experiments/pure-lean-core/RESULT.md`.
- Lean v4.32.0 `Environment`, `Elab.Frontend`, `Language.Lean`, module-linter, plugin, and snapshot APIs.
- Mathlib commit `783ccda4ee524f13cc5636237be0a1942bc04824` and its 8,795-file workload.

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not call a formatter-integrated build an ordinary built project. Do not count project compilation inside a formatter-cache timing without reporting it separately.
