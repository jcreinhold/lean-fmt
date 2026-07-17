# Next Proof Packet

- Stack: ruff-05b-semantic-facts
- First unresolved: 01-spec
- Claim ID: RSF-SPEC
- Prompt: 01-spec
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RSF-SPEC**: characterize exactly what the frontend `Environment` exposes at the plugin producer, pin the declared notation/atom spacing fact on fixtures, and design the semantic-fact representation twice — so `RSF-IMPL` builds a fact whose shape, cache identity, and cost are settled, not discovered mid-implementation.
- Read this stack's `roadmap.md`, its prerequisite stacks' results (`ruff-01`, `ruff-05`), the `ruff-03` reflow architecture note (`docs/projects/ruff-03-language-formatting/notes/05-reflow-architecture.md`, the consumer's design), `AGENTS.md`, and the relevant Lean compiler/Lake sources. Confirm first-hand: `LeanFmt/CompilerPlugin.lean:27` (`getEnv` at the producer), `ModuleArtifact.ofParsedModule` and the `v3` schema (`LeanFmt/ArtifactModel.lean`), `LeanFmt/LosslessSource.lean` (the syntax projection the fact sits beside), `Lean/PrettyPrinter/Formatter.lean:357-417` (`pushToken`/`parseToken`, how Lean derives spacing from the token table), and `Init/Notation.lean:284` / `Init/Prelude.lean:5390` (`infixl:65 " + "`).

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- This is a specification prompt: it may add characterization fixtures and evidence but ships no tier or schema change — that is `RSF-IMPL`.
- No design may hand a live `Environment` downstream; the fact is data.
- A representation that cannot express a corpus-declared notation is rejected.
- Stop rather than specifying a fact that grows the plugin's import closure or weakens cache identity.
