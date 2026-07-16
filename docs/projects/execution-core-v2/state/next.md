# Next Proof Packet

- Stack: execution-core-v2
- First unresolved: 09-modes
- Claim ID: ECV2-MODES
- Prompt: 09-modes
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Add `format`, `diff`, `fix`, `rules`, `clean`, and compiler-integration setup/status over the same semantic result used by check. First add one private edit capability that accepts an immutable source snapshot and selected findings and returns either a fully checked patch or one typed rejection. The application operation, not the CLI dispatcher, owns patch preparation, exact validation, stale-source checking, atomic publication, cache interaction, and deterministic aggregation.

## Reuse

- `roadmap.md`, `state/current.md`, and `notes/09-product-contract.md`
- `LeanFmt/Application.lean`, `LeanFmt/ArtifactModel.lean`, `LeanFmt/Cache.lean`, and `LeanFmt/Rules.lean`
- The archived implementation only as characterization evidence for rule/edit behavior; do not restore its public APIs, worker controls, or orchestration layers.

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Stop for replanning instead of weakening validation, treating arbitrary Lake source as safely rewritable, silently accepting unknown configuration, inventing strategy controls, or adding a second analyzer/orchestrator. Ordinary Lean API/name drift, missing small edit/diff/config helpers, and a failed first implementation attempt are not blockers.
