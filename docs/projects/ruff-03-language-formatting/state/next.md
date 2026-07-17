# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 08-reflow-expr
- Claim ID: RLF-REFLOW
- Prompt: 08-reflow-expr
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-REFLOW**: the first layout that makes the engine *decide*. Break applications, operators, notations, bracketed binders, and `match` alternatives across lines when they exceed the target width, using `group`/`nest`/`line` (`Doc.lean:44-81`, unused by real source until now) and the declared spacing from `RLF-NOTATION`. Set the default margin to **100** (`notes/05-reflow-architecture.md` §5).
- Read `roadmap.md`, `notes/05-reflow-architecture.md`, `results/02-expressions.md` and `results/06-notation-facts.md`, `AGENTS.md`, and the relevant Lean compiler sources. Confirm first-hand the constraint that governs every break here: `argument := checkWsBefore >> checkColGt` (`Lean/Parser/Term.lean:885-892`) — **a wrapped argument must land at a column strictly greater than its function head**, or it stops being an argument and the parse changes.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No break may violate `checkColGt`/`checkColGe`/`checkColEq`; a wrapped token that changes the parse is a bug, not a style choice — verified by reparse, not argued.
- Do not touch import order, literal contents, or comment placement; a construct whose reflow would drop a comment keeps its bytes.
- Idempotence is a gate: a second format must be byte-identical to the first.
- Stop rather than weakening exact semantics, cache identity, write safety, or the resource envelope (8 GiB aggregate RSS / 256 MiB new swap; `render` stays linear-bounded).
