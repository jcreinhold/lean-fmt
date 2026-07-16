# Next Proof Packet

- Stack: execution-core-v2
- First unresolved: 11-serve
- Claim ID: ECV2-SERVE
- Prompt: 11-serve
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- see the target prompt's Task section

## Reuse

- `roadmap.md`, `state/current.md`, `notes/06-design.md`, `notes/09-modes-design.md`, `notes/10-scale-design.md`, and `notes/11-service-design.md`.
- `LeanFmt/Application.lean`, `LeanFmt/Cli.lean`, `LeanFmt/Project.lean`, `LeanFmt/Semantic.lean`, and the focused check/mode integration harnesses.

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Stop for replanning instead of accepting on-disk evidence for unsaved bytes, retaining a mutable frontend environment across distinct exact headers, adding a second semantic projection or source writer, allowing unbounded input retention, exposing concurrency controls, or weakening the memory envelope. Ordinary Lean stream/JSON API drift, a missing focused fixture, and a failed first protocol test are not blockers.
