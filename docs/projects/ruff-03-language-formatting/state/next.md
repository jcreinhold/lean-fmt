# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 06-notation-facts
- Claim ID: RLF-NOTATION
- Prompt: 06-notation-facts
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-NOTATION**: give the printer the one thing phase 1 proved it lacks — each notation and atom's *declared* inter-token spacing — as a fact captured while the frontend `Environment` is live, so operators and notations can take canonical spacing without the printer ever holding an `Environment`. This is the hybrid decided in `notes/05-reflow-architecture.md` §2: environment-derived *data*, consumed by the lossless `Doc` engine.
- Read `roadmap.md`, `notes/05-reflow-architecture.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Confirm the phase-1 citations first-hand: `PrettyPrinter/Formatter.lean:357-417` (`pushToken`/`parseToken` needs `getEnv`), `Init/Notation.lean:284` and `Init/Prelude.lean:5390` (`infixl:65 " + "` declares its spaces), `LosslessSource.lean:64-86` (the projection drops it).

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- The printer must not gain an `Environment` dependency or a frontend import; the fact crosses the boundary, not the table.
- Spacing may change only to the *declared* string; never invent spacing for an atom that declares none (that stays `app`'s parser-required minimum or conservative bytes).
- A missing/stale fact must fall back to source bytes, never to a guessed layout.
- Stop rather than weakening exact semantics, cache identity, write safety, or the resource envelope.
- Stop and reopen — do not patch around — if a prerequisite stack's live code contradicts its results.
