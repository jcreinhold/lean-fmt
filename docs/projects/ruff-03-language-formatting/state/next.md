# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 10-reflow-final
- Claim ID: RLF-ACCEPT
- Prompt: 10-reflow-final
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-ACCEPT**: the phase-2 acceptance. Prove the reflowing formatter is idempotent, parse-preserving, comment-preserving, and within budget across the whole language and the frozen mathlib sample, and record every construct still on the conservative path with the grammar line that keeps it there. Supersede `RLF-FINAL`'s "whole-language coverage" claim, which closed the *conservative* coverage only.
- Read `roadmap.md`, `notes/05-reflow-architecture.md`, all phase-2 result notes, `AGENTS.md`, and the relevant Lean compiler sources. This is an audit prompt: it adds tests and evidence, and changes production code only to fix a defect it finds.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Completion requires zero silently unowned reflow behaviour and zero idempotence or parse-preservation divergence left unrecorded.
- This prompt is authorized to run the frozen representative sample; **complete mathlib is still forbidden** — it is not `RCP-ACCEPT`.
- Stop rather than weakening exact semantics, cache identity, write safety, or the resource envelope.
