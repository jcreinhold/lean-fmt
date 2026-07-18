# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 12-records
- Claim ID: RLF-RECORDS
- Prompt: 12-records
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-RECORDS**: build the `structInst` record vertical break that `RLF-BLOCKS` **designed but did not build** (`notes/08-blocks-layout.md` §2, design **A1** — one field per line at a fixed nest base, so `checkColEq` falls out of the layout rather than being arranged). `RLF-BLOCKS` correctly declined it under its *re-indent* lens (a record's first field rides the `{ ` line — a mid-line anchor, §1a); this prompt delivers it as the `RLF-REFLOW`-class **break** it always was, guarded against the one hazard that kept it deferred.
- Read `roadmap.md`, `notes/08-blocks-layout.md` §1a and §2, `results/02-expressions.md` §5b (the horizontal-collapse hazard), `results/08-reflow-expr.md` and `results/09-reflow-blocks.md`, `AGENTS.md`, and the relevant Lean compiler sources. Confirm first-hand: `structInst := "{ " >> … sepByIndent structInstField ", " … >> " }"` (`Lean/Parser/Term.lean:352-357`) with spaced braces and a `withPosition` **inside** the braces, so a break must land every field at the first field's column (`checkColEq`), and a horizontal *collapse* moves a position a later line is measured against (`spacingOf` docstring; `results/02` §5b).

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- The break must preserve `checkColEq` between fields, verified by reparse (token + tree), not argued; a field that lands off the shared column is a bug.
- No horizontal collapse; a record holding a comment the break would move keeps its bytes.
- Idempotence is a gate: a second format is byte-identical to the first at every margin.
- Stop rather than weakening exact semantics, write safety, or the resource envelope (8 GiB aggregate RSS / 256 MiB new swap).
