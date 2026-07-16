# Next Proof Packet

- Stack: execution-core-v2
- First unresolved: 10-scale
- Claim ID: ECV2-SCALE
- Prompt: 10-scale
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Replace module-only batch execution with complete source-target execution, separate product semantics from compiler projection, and measure the cheapest sound evidence path for each rule requirement. Optimize ordinary-built cold, formatter-integrated cache-cold, and result-cache-warm execution in that order, advancing only plausible candidates to full mathlib acceptance.

## Reuse

- `roadmap.md`, `state/current.md`, `notes/03-semantics-and-workloads.md`, `notes/04-ordinary-built-cold.md`, `notes/05-module-system-correction.md`, and `notes/10-scale-design.md`.
- `LeanFmt/Application.lean`, `LeanFmt/ArtifactModel.lean`, `LeanFmt/Analysis.lean`, `LeanFmt/Cache.lean`, `LeanFmt/Rules.lean`, and the target Lean/Lake APIs that own module traces, `ModuleSetup`, and `setupServerModule`.
- Existing raw measurements before starting a new profile. Reuse evidence when its binary, workload, toolchain, build state, cache state, and configuration identities still match.

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Stop for replanning instead of weakening exactness, omitting standalone files, treating an `.olean` as syntax it does not contain, hiding prerequisite compilation, accepting an untraced sidecar, or raising the memory envelope. Ordinary Lean API/name drift, a missing small filesystem/setup helper, and a failed first measurement or implementation attempt are not blockers.
