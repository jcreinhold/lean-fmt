# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 11-operator-break
- Claim ID: RLF-OPERATOR-BREAK
- Prompt: 11-operator-break
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-OPERATOR-BREAK**: extend the margin-driven β-break `RLF-REFLOW` built for `Term.app` to the constructs `RLF-REFLOW` named but deferred — **operators/notations, bracketed binders, and `match` alternatives** (`notes/07` §2 records the deferral; `RLF-ACCEPT`'s `results/10` coverage table cites it as conservative-with-a-reason). The mechanism exists (`group`/`nest`/`line`, `Doc.lean:44-81`); this prompt widens the `reflows` predicate (`Printer.lean:995`, currently `kind == "Lean.Parser.Term.app"`) and emits a break policy for each new kind, every break parse-preserving.
- Read `roadmap.md`, `notes/05-reflow-architecture.md`, `notes/07-offside-layout.md` §2 (the deferral this discharges), `results/06-notation-facts.md` and `results/08-reflow-expr.md`, `AGENTS.md`, and the relevant Lean compiler sources. Confirm first-hand the governing constraints: the argument column rule `argument := checkWsBefore >> checkColGt` (`Lean/Parser/Term.lean:885-892`), the notation-spacing fact `RLF-NOTATION` reads, and that a broken binder/operator continuation must land at a column that keeps its parse (verified by reparse, not argued).

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No break may violate `checkColGt`/`checkColGe`/`checkColEq`; a wrapped token that changes the parse is a bug, verified by reparse (token + tree), not argued.
- A construct whose break would drop or move a comment keeps its bytes — conservative fallback, never a guessed layout.
- Idempotence is a gate: a second format is byte-identical to the first at every margin.
- Stop rather than weakening exact semantics, write safety, or the resource envelope (8 GiB aggregate RSS / 256 MiB new swap; `render` stays linear-bounded).
