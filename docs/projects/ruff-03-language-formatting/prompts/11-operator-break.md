---
claim_id: RLF-OPERATOR-BREAK
status: planned
depends_on: [RLF-REFLOW]
---

# Break operators, binders, and match alternatives over the margin

## Task

Deliver **RLF-OPERATOR-BREAK**: extend the margin-driven β-break `RLF-REFLOW` built for `Term.app` to the
constructs `RLF-REFLOW` named but deferred — **operators/notations, bracketed binders, and `match`
alternatives** (`notes/07` §2 records the deferral; `RLF-ACCEPT`'s `results/10` coverage table cites it
as conservative-with-a-reason). The mechanism exists (`group`/`nest`/`line`, `Doc.lean:44-81`); this
prompt widens the `reflows` predicate (`Printer.lean:995`, currently `kind == "Lean.Parser.Term.app"`)
and emits a break policy for each new kind, every break parse-preserving.

Read `roadmap.md`, `notes/05-reflow-architecture.md`, `notes/07-offside-layout.md` §2 (the deferral this
discharges), `results/06-notation-facts.md` and `results/08-reflow-expr.md`, `AGENTS.md`, and the
relevant Lean compiler sources. Confirm first-hand the governing constraints: the argument column rule
`argument := checkWsBefore >> checkColGt` (`Lean/Parser/Term.lean:885-892`), the notation-spacing fact
`RLF-NOTATION` reads, and that a broken binder/operator continuation must land at a column that keeps its
parse (verified by reparse, not argued).

## Target

- Break an over-margin **operator/notation** application at the declared notation spacing (`RLF-NOTATION`),
  choosing the break points from precedence, so `a + b + c` that exceeds the margin wraps at operator
  boundaries with continuations at a `checkColGt`/`colGe`-safe column. Bracketed **binders** `(x y : T)`
  and **`matchAlt`** `| p => e` break at their declared gaps when over-margin, flat otherwise.
- **Design the operator-break policy twice** — e.g. break at the lowest-precedence operator only
  (tree-shaped) versus uniform break of every operand (flat) — and compare on diff stability,
  idempotence, and reparse safety. Record the choice in `notes/09-operator-break.md`.
- A construct that fits the margin stays byte-flat (canonical spacing), so the layout is a no-op on the
  already-canonical corpus, as every prior layout is; the proof it changes a byte is the over-margin
  fixtures.
- Add golden fixtures that **exceed** the margin for each new kind (operator chain, multi-binder
  signature, wide match arm) with deliberately over-width input, asserting the formatter *changed* lines;
  include a comment inside a broken construct (must survive) and a nested break.
- Write `results/11-operator-break.md` with commands, measurements, a **performance line** (workload,
  machine, toolchain, commit, wall time, peak aggregate RSS), decisions changed, and remaining
  uncertainty. Update `state/current.md` after reading checks; regenerate `state/next.md`.

## Plan

1. Enumerate the new kinds' parser positions: which break interiors are `withoutPosition` (free) and
   which sit under a live `checkColGt`/`colGe`; state the invariant each break must preserve.
2. Design the operator-break policy (twice where ambiguous); choose and record.
3. Widen `reflows` and emit `group`/`nest`/`line` per kind, consuming `RLF-NOTATION` spacing; never break
   a construct holding a comment the break would move.
4. Prove idempotence (`format (format x) = format x`) and parse-preservation by fresh-frontend reparse —
   token stream *and* tree (`compare_tokens.py`) — on over-margin fixtures at margins 0/1/40/80/100/1000.
5. Inspect callers/docs; confirm no construct silently changes a parse and the coverage table gains rows.

## Stop

- No break may violate `checkColGt`/`checkColGe`/`checkColEq`; a wrapped token that changes the parse is a
  bug, verified by reparse (token + tree), not argued.
- A construct whose break would drop or move a comment keeps its bytes — conservative fallback, never a
  guessed layout.
- Idempotence is a gate: a second format is byte-identical to the first at every margin.
- Stop rather than weakening exact semantics, write safety, or the resource envelope (8 GiB aggregate
  RSS / 256 MiB new swap; `render` stays linear-bounded).

## Check

- Run `LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests` and the focused suites named by touched
  modules, including `tests/printer/run.sh` and `tests/modes/run.sh`.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden (this is not
  the acceptance prompt).
- From the KanProofs tool environment, run the generic stack structural checker and `write_next.py
  --check` for `docs/projects/ruff-03-language-formatting`.
- Run `git diff --check` and read all output before marking RLF-OPERATOR-BREAK verified.
