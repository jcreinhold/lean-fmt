# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 07-offside-layout
- Claim ID: RLF-OFFSIDE
- Prompt: 07-offside-layout
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-OFFSIDE**: the layout capability records and tactic/`do`/`where`/`let` blocks need — emit a multi-line block at a *canonical base column* while preserving every internal `colEq`/`colGt`/`colGe` relationship, so re-indentation never changes the parse. Per `notes/05-reflow-architecture.md` §3 this is **not** column-alignment (`Doc.align`/`pushAlign` inherits a column; a ruff-class formatter chooses one); the capability is a *parse-preserving re-indent to a chosen base*.
- Read `roadmap.md`, `notes/05-reflow-architecture.md`, `results/03-tactics.md` (the re-indent design phase 1 killed and why), its prerequisite stack results, `AGENTS.md`, and the relevant Lean compiler/Lake sources. Confirm first-hand: `Doc.lean:44-81` (constructor set), `:62-68` (`verbatim` never re-indented), `:71-73` (the written no-align decision), `Lean/Parser/Extra.lean:199-208` (`manyIndent`/`sepByIndent` offside separators), `withoutPosition` at `Lean/Parser/Basic.lean:1565-1571`.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- The capability must be parse-preserving by the reparse check, not by argument; a base that breaks an internal `colGt`/`colEq` is a bug.
- `verbatim` interior is never re-indented; comments never move.
- Do not adopt column-alignment (`align`/`pushAlign`); the base is chosen, not inherited.
- If `ruff-02` is reopened, its `render` linear-bound guarantee must survive; stop rather than trading it for the constructor.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
