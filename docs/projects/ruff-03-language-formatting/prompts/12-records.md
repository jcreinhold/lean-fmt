---
claim_id: RLF-RECORDS
status: planned
depends_on: [RLF-BLOCKS]
---

# Break records vertically (the structInst A1 layout)

## Task

Deliver **RLF-RECORDS**: build the `structInst` record vertical break that `RLF-BLOCKS` **designed but
did not build** (`notes/08-blocks-layout.md` §2, design **A1** — one field per line at a fixed nest base,
so `checkColEq` falls out of the layout rather than being arranged). `RLF-BLOCKS` correctly declined it
under its *re-indent* lens (a record's first field rides the `{ ` line — a mid-line anchor, §1a); this
prompt delivers it as the `RLF-REFLOW`-class **break** it always was, guarded against the one hazard that
kept it deferred.

Read `roadmap.md`, `notes/08-blocks-layout.md` §1a and §2, `results/02-expressions.md` §5b (the
horizontal-collapse hazard), `results/08-reflow-expr.md` and `results/09-reflow-blocks.md`, `AGENTS.md`,
and the relevant Lean compiler sources. Confirm first-hand: `structInst := "{ " >> … sepByIndent
structInstField ", " … >> " }"` (`Lean/Parser/Term.lean:352-357`) with spaced braces and a `withPosition`
**inside** the braces, so a break must land every field at the first field's column (`checkColEq`), and a
horizontal *collapse* moves a position a later line is measured against (`spacingOf` docstring;
`results/02` §5b).

## Target

- Break an over-margin record one field per line at a fixed nest base — `{ x := 1,`↵`  y := 2,`↵`  z := 3
  }` — so every field sits at one shared column satisfying `checkColEq`, the braces take their declared
  spacing (`RLF-NOTATION`), and the trailing separator (`allowTrailingSep := true`) keeps each field line
  self-contained. A record that **fits** the margin stays flat and byte-canonical (`{ x := 1, y := 2 }`).
- Keep the **collapse guard**: this prompt breaks a single-line-over-margin record downward; it does
  **not** collapse a multi-line record upward (the `sepByIndent`-saves-inside hazard `RLF-EXTENSIONS`
  deferred stays deferred). State this boundary in the coverage note.
- **Design the break twice** if a second canonical shape is admissible (A1 one-field-per-line versus a
  fill-to-margin A2, already argued in `notes/08` §2 — re-examine against the built engine and record
  whether the prior choice holds).
- Add golden fixtures: an over-margin record (fields break, colEq read off the output), a nested record,
  a record with a comment between fields (must survive), and a fits-the-margin record (stays flat).
- Write `results/12-records.md` with commands, measurements, a **performance line**, decisions changed,
  and remaining uncertainty. Update `state/current.md` after reading checks; regenerate `state/next.md`.

## Plan

1. Reproduce the `structInst` invariant (`checkColEq` between fields; the collapse hazard) and state what
   the A1 break must preserve.
2. Confirm or revise the A1-vs-A2 choice against the built engine; record.
3. Implement the vertical break with `group`/`nest`/`line` at the field separator, braces spaced per
   `RLF-NOTATION`; the fits case stays flat; never collapse.
4. Prove idempotence and parse-preservation by fresh-frontend reparse — token stream *and* tree
   (`compare_tokens.py`) — on over-margin record fixtures at margins 0/1/40/80/100/1000; read `colEq` off
   the broken output.
5. Inspect callers/docs; confirm the coverage table moves `structInst` from cited-conservative to
   actively-laid-out and no collapse is silently enabled.

## Stop

- The break must preserve `checkColEq` between fields, verified by reparse (token + tree), not argued; a
  field that lands off the shared column is a bug.
- No horizontal collapse; a record holding a comment the break would move keeps its bytes.
- Idempotence is a gate: a second format is byte-identical to the first at every margin.
- Stop rather than weakening exact semantics, write safety, or the resource envelope (8 GiB aggregate
  RSS / 256 MiB new swap).

## Check

- Run `LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests` and the focused suites named by touched
  modules, including `tests/printer/run.sh` and `tests/modes/run.sh`.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden (this is not
  the acceptance prompt).
- From the KanProofs tool environment, run the generic stack structural checker and `write_next.py
  --check` for `docs/projects/ruff-03-language-formatting`.
- Run `git diff --check` and read all output before marking RLF-RECORDS verified.
