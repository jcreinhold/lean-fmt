# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 09-reflow-blocks
- Claim ID: RLF-BLOCKS
- Prompt: 09-reflow-blocks
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-BLOCKS**: apply the `RLF-OFFSIDE` capability to the constructs phase 1 deferred on the offside grammar — `structInst` records, tactic sequences, `do`, `where`, and `let` blocks — laying each out at canonical indentation while preserving the column relationships that carry meaning. This is where "indentation is a token" (`results/03-tactics.md`) is *handled*, not deferred.
- Read `roadmap.md`, `notes/05-reflow-architecture.md`, `notes/06-offside-primitive.md`, `results/03-tactics.md` and `results/04-extensions.md` (the offside counterexamples), `AGENTS.md`, and the relevant Lean compiler sources. Confirm first-hand: `sepByIndent`'s `checkColEq >> checkLinebreakBefore` separator (`Lean/Parser/Extra.lean:202-208`), `structInst`'s spaced braces `"{ "` / `" }"` (`Lean/Parser/Term.lean:351-355`), `tacticSeq1Indented`, and the `by skip skip` offside docstring (`Term/Basic.lean:57-65`).

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Re-indentation is parse-preserving by reparse, not by argument; a base that breaks `checkColEq` between two fields or `checkColGt` between two tactics is a bug.
- Comments inside a block never move or vanish; `verbatim` interiors are untouched.
- A block that cannot be proven safe to re-lay-out keeps its bytes — conservative fallback, never a guessed layout.
- Idempotence is a gate. Stop rather than weakening exact semantics, write safety, or the resource envelope.
