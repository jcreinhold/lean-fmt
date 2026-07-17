---
claim_id: RLF-BLOCKS
status: verified
depends_on: [RLF-REFLOW]
---

# Lay out records and offside blocks (tactics, do, where, let)

## Task

Deliver **RLF-BLOCKS**: apply the `RLF-OFFSIDE` capability to the constructs phase 1 deferred on the
offside grammar — `structInst` records, tactic sequences, `do`, `where`, and `let` blocks — laying each
out at canonical indentation while preserving the column relationships that carry meaning. This is where
"indentation is a token" (`results/03-tactics.md`) is *handled*, not deferred.

Read `roadmap.md`, `notes/05-reflow-architecture.md`, `notes/06-offside-primitive.md`,
`results/03-tactics.md` and `results/04-extensions.md` (the offside counterexamples), `AGENTS.md`, and
the relevant Lean compiler sources. Confirm first-hand: `sepByIndent`'s `checkColEq >>
checkLinebreakBefore` separator (`Lean/Parser/Extra.lean:202-208`), `structInst`'s spaced braces `"{ "`
/ `" }"` (`Lean/Parser/Term.lean:351-355`), `tacticSeq1Indented`, and the `by skip skip` offside
docstring (`Term/Basic.lean:57-65`).

## Target

- Lay out records so fields sit at one canonical shared column (satisfying `checkColEq`), braces take
  their declared spacing (`RLF-NOTATION`), and a record that fits the margin stays on one line —
  reproducing neither of phase 1's two break counterexamples.
- Lay out tactic/`do`/`where`/`let` blocks by re-indenting to a canonical base with `RLF-OFFSIDE`,
  preserving every internal `colEq`/`colGt`/`colGe`; bullets and `case` alternatives keep their
  offside structure. A block whose re-indentation cannot be proven parse-preserving keeps its bytes.
- **Design the record break twice** (one field per line versus fill-to-margin) and the tactic
  re-indentation base twice (parent + fixed indent versus preserve author base); compare on parse
  safety, idempotence, and diff stability; record the choices.
- Add golden fixtures that exceed the margin and that carry deliberately non-canonical indentation, so
  the goldens prove a *change*; include a comment inside a block (must survive) and a nested block.
- Write `results/09-reflow-blocks.md` with commands, measurements, a performance line, decisions
  changed, and remaining uncertainty. Update `state/current.md` after reading checks; regenerate
  `state/next.md`.

## Plan

1. Reproduce phase 1's `structInst` and tactic counterexamples; state the invariant each layout must
   preserve.
2. Design record layout and tactic re-indentation (twice where ambiguous); choose.
3. Implement using `RLF-OFFSIDE` and `RLF-NOTATION`; never re-indent `verbatim` interiors.
4. Prove idempotence and parse-preservation by fresh-frontend reparse over offside fixtures; confirm
   comments inside blocks survive unmoved.
5. Inspect callers/docs; confirm no construct silently changes a parse.

## Stop

- Re-indentation is parse-preserving by reparse, not by argument; a base that breaks `checkColEq`
  between two fields or `checkColGt` between two tactics is a bug.
- Comments inside a block never move or vanish; `verbatim` interiors are untouched.
- A block that cannot be proven safe to re-lay-out keeps its bytes — conservative fallback, never a
  guessed layout.
- Idempotence is a gate. Stop rather than weakening exact semantics, write safety, or the resource
  envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules,
  including `tests/printer/run.sh`.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden unless this
  prompt is `RCP-ACCEPT` and all prerequisite gates pass.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-03-language-formatting`.
- Run `git diff --check` and read all output before marking RLF-BLOCKS verified.
