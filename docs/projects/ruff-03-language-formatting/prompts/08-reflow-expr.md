---
claim_id: RLF-REFLOW
status: planned
depends_on: [RLF-OFFSIDE]
---

# Reflow expressions to the target width

## Task

Deliver **RLF-REFLOW**: the first layout that makes the engine *decide*. Break applications, operators,
notations, bracketed binders, and `match` alternatives across lines when they exceed the target width,
using `group`/`nest`/`line` (`Doc.lean:44-81`, unused by real source until now) and the declared
spacing from `RLF-NOTATION`. Set the default margin to **100** (`notes/05-reflow-architecture.md` §5).

Read `roadmap.md`, `notes/05-reflow-architecture.md`, `results/02-expressions.md` and
`results/06-notation-facts.md`, `AGENTS.md`, and the relevant Lean compiler sources. Confirm first-hand
the constraint that governs every break here: `argument := checkWsBefore >> checkColGt`
(`Lean/Parser/Term.lean:885-892`) — **a wrapped argument must land at a column strictly greater than
its function head**, or it stops being an argument and the parse changes.

## Target

- Emit `group`+`nest`+`line` so a construct is laid flat when it fits the margin and broken when it
  does not, with every broken continuation landing at a `checkColGt`-satisfying column. Operators break
  at the notation's declared spacing from `RLF-NOTATION`; applications break before arguments; binders
  and `matchAlt` break at their declared gaps.
- **Design the break policy twice** where a construct admits more than one canonical shape (e.g.
  all-or-nothing break of an argument list versus fill-mode): compare on diff stability, idempotence,
  and reparse safety. Record the choice.
- Set the default margin (100) as reviewed product policy; keep it configuration that enters cache
  identity; a project may override it. No caller outside tests hardcodes a different value silently.
- Add golden fixtures that *exceed* the margin (the corpus is already canonical and will not, per phase
  1) so the goldens cannot degenerate into copies of their input; assert the formatter *changed* lines.
- Write `results/08-reflow-expr.md` with commands, measurements, a **performance line** (workload,
  machine, toolchain, commit, wall time, peak aggregate RSS — the first prompt to trigger real
  `group` measurement work), decisions changed, and remaining uncertainty.
- Update `state/current.md` after reading checks; regenerate `state/next.md`.

## Plan

1. Characterize where a break is legal: enumerate the constructs whose interior is `withoutPosition`
   (breaks are free) versus those under a live `checkColGt` (breaks must respect the head column).
2. Design the break policy per construct; where ambiguous, design twice and compare.
3. Implement `group`/`nest`/`line` emission consuming `RLF-NOTATION` spacing; wire the margin.
4. Prove idempotence (`format (format x) = format x`) and parse-preservation (reparse the broken output)
   on over-margin fixtures at margins 0/1/40/80/100/1000.
5. Inspect all callers and docs for a leaked margin or claims stronger than the evidence.

## Stop

- No break may violate `checkColGt`/`checkColGe`/`checkColEq`; a wrapped token that changes the parse is
  a bug, not a style choice — verified by reparse, not argued.
- Do not touch import order, literal contents, or comment placement; a construct whose reflow would drop
  a comment keeps its bytes.
- Idempotence is a gate: a second format must be byte-identical to the first.
- Stop rather than weakening exact semantics, cache identity, write safety, or the resource envelope
  (8 GiB aggregate RSS / 256 MiB new swap; `render` stays linear-bounded).

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules,
  including `tests/printer/run.sh`.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden unless this
  prompt is `RCP-ACCEPT` and all prerequisite gates pass.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-03-language-formatting`.
- Run `git diff --check` and read all output before marking RLF-REFLOW verified.
