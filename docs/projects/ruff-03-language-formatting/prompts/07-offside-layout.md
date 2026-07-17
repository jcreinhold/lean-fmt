---
claim_id: RLF-OFFSIDE
status: planned
depends_on: [RLF-NOTATION]
---

# Provide a parse-preserving re-indent capability for offside blocks

## Task

Deliver **RLF-OFFSIDE**: the layout capability records and tactic/`do`/`where`/`let` blocks need — emit
a multi-line block at a *canonical base column* while preserving every internal `colEq`/`colGt`/`colGe`
relationship, so re-indentation never changes the parse. Per `notes/05-reflow-architecture.md` §3 this
is **not** column-alignment (`Doc.align`/`pushAlign` inherits a column; a ruff-class formatter chooses
one); the capability is a *parse-preserving re-indent to a chosen base*.

Read `roadmap.md`, `notes/05-reflow-architecture.md`, `results/03-tactics.md` (the re-indent design
phase 1 killed and why), its prerequisite stack results, `AGENTS.md`, and the relevant Lean
compiler/Lake sources. Confirm first-hand: `Doc.lean:44-81` (constructor set), `:62-68` (`verbatim`
never re-indented), `:71-73` (the written no-align decision), `Lean/Parser/Extra.lean:199-208`
(`manyIndent`/`sepByIndent` offside separators), `withoutPosition` at `Lean/Parser/Basic.lean:1565-1571`.

## Target

- **Design it twice, for real, and write the comparison out** (`notes/06-offside-primitive.md`):
  - **A — new `Doc` constructor** (reopen `ruff-02`): e.g. `reindent (base : Nat) (block : Doc)` that
    re-bases a block's lines to `base` preserving their *relative* indentation, sitting between
    `verbatim` (never re-indented) and `nest`+`hard` (rebuilds each line). Cost: widens the engine's
    committed surface and its `render`/`fits` proofs; benefit: the offside rule lives in the engine
    once, provable, and callers stay declarative.
  - **B — printer-side line reconstruction** over existing `nest`/`hard`/`verbatim`: the printer walks
    a block into lines, computes each line's relative indent, and re-emits. Cost: the offside logic
    lives in the printer and may duplicate per-construct; benefit: `Doc` stays frozen and `ruff-02` is
    not reopened.
  - Compare on: engine surface widened, where the invariant is provable, change-amplification when a
    new offside construct is added, caller cost, and faithfulness to Lean's offside semantics. Choose,
    and if A wins, reopen `ruff-02` (state + results) with explicit pathspecs.
- Deliver the capability with the invariant *checked*, not asserted: a property test that for a
  representative offside block, re-indenting to several bases and reparsing yields the same token
  stream (parse-preservation, `notes/05-reflow-architecture.md` §4.1).
- Do **not** yet re-lay-out real records or tactics — that is prompt `09`. This prompt delivers and
  proves the *capability* in isolation, with fixtures, so `09` consumes a proven primitive.
- Write `results/07-offside-layout.md`; update `state/current.md` after reading checks; regenerate
  `state/next.md`. If `ruff-02` was reopened, update its state too.

## Plan

1. Reproduce phase 1's re-indent counterexample (`evidence/04-coleq-break.txt`) and state exactly which
   internal relationships a correct re-indent must preserve.
2. Write designs A and B; compare per the axes above; choose.
3. Implement the chosen capability; if a `Doc` constructor, extend `render`/`fits` and their bounds and
   re-run `ruff-02`'s engine tests.
4. Prove parse-preservation by fresh-frontend reparse over an offside fixture at multiple bases.
5. Confirm `verbatim` interiors (comments, string literals) are untouched by the new path.

## Stop

- The capability must be parse-preserving by the reparse check, not by argument; a base that breaks an
  internal `colGt`/`colEq` is a bug.
- `verbatim` interior is never re-indented; comments never move.
- Do not adopt column-alignment (`align`/`pushAlign`); the base is chosen, not inherited.
- If `ruff-02` is reopened, its `render` linear-bound guarantee must survive; stop rather than trading
  it for the constructor.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules;
  if `ruff-02` was reopened, run its Doc/engine suite.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden unless this
  prompt is `RCP-ACCEPT` and all prerequisite gates pass.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-03-language-formatting` (and `ruff-02` if reopened).
- Run `git diff --check` and read all output before marking RLF-OFFSIDE verified.
