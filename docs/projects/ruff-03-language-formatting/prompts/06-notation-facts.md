---
claim_id: RLF-NOTATION
status: planned
depends_on: [RLF-FINAL]
---

# Capture declared notation and atom spacing as an analysis-layer fact

## Task

Deliver **RLF-NOTATION**: give the printer the one thing phase 1 proved it lacks — each notation and
atom's *declared* inter-token spacing — as a fact captured while the frontend `Environment` is live,
so operators and notations can take canonical spacing without the printer ever holding an
`Environment`. This is the hybrid decided in `notes/05-reflow-architecture.md` §2: environment-derived
*data*, consumed by the lossless `Doc` engine.

Read `roadmap.md`, `notes/05-reflow-architecture.md`, its prerequisite stack results, `AGENTS.md`, the
current implementation and tests, and the relevant Lean compiler/Lake sources before changing an
interface. Confirm the phase-1 citations first-hand: `PrettyPrinter/Formatter.lean:357-417`
(`pushToken`/`parseToken` needs `getEnv`), `Init/Notation.lean:284` and `Init/Prelude.lean:5390`
(`infixl:65 " + "` declares its spaces), `LosslessSource.lean:64-86` (the projection drops it).

## Target

- **Reopen the owning lower layer.** The fact must be captured where the `Environment` exists — the
  analysis producer (`ruff-01` `LosslessSource.ofSource` / the compiler-plugin linter) and, if a tier
  is the right home, `ruff-05`'s fact-tier system. Reopen that stack's state and results as part of
  this prompt (explicit pathspecs); do not smuggle a frontend dependency into `LeanFmt.Printer`, which
  the architecture keeps `Environment`-free.
- **Design the fact twice** before adding it (`notes/05-reflow-architecture.md` §2 is the capability
  design; this is the *representation*): compare (a) per-notation-node declared-spacing recorded inline
  in the projection versus (b) a side table keyed by syntax-kind/token resolved at print time. Compare
  on projection size, cache identity (`RLC-SPEC` §5 — the fact enters the digest), staleness across
  toolchain bumps, and whether a corpus-declared notation is expressible. Record the comparison and the
  choice.
- Keep the fact *additive and lossless*: the projection still records source bytes; the declared
  spacing is extra, never a replacement. A node with no declared atom (e.g. `app`) carries no fact and
  keeps its phase-1 treatment.
- Add focused fixtures and persistent regression tests at the owning layer: a core notation
  (`_ + _`), a corpus-declared notation, and a notation whose atoms declare asymmetric spacing.
- Write `results/06-notation-facts.md` with exact commands, raw outputs or evidence locators,
  measurements, decisions changed during execution, and remaining uncertainty. Update the reopened
  prerequisite stack's state too.
- Update `state/current.md` only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Characterize what the projection carries today for a notation node and prove the declared string is
   absent (re-run or extend the phase-1 census; cite `evidence/`).
2. Locate the exact analysis point where the `Environment`/token table is live and the fact can be
   read with Lean's own lookup (not a reimplementation of `parseToken`).
3. Design the fact representation twice; choose; record cache-identity impact.
4. Implement the smallest additive fact and the printer-side consumer that maps it to canonical gaps;
   remove no lossless guarantee.
5. Exercise core, corpus-declared, asymmetric-spacing, and no-atom nodes; confirm a stale/missing fact
   degrades to the phase-1 conservative bytes rather than to wrong Lean.

## Stop

- The printer must not gain an `Environment` dependency or a frontend import; the fact crosses the
  boundary, not the table.
- Spacing may change only to the *declared* string; never invent spacing for an atom that declares
  none (that stays `app`'s parser-required minimum or conservative bytes).
- A missing/stale fact must fall back to source bytes, never to a guessed layout.
- Stop rather than weakening exact semantics, cache identity, write safety, or the resource envelope.
- Stop and reopen — do not patch around — if a prerequisite stack's live code contradicts its results.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules,
  including the reopened prerequisite's suites and `tests/printer/run.sh`.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually; confirm
  `LeanFmt.Printer` gained no forbidden import.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden unless this
  prompt is `RCP-ACCEPT` and all prerequisite gates pass.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-03-language-formatting` **and** the reopened
  prerequisite stack.
- Run `git diff --check` and read all output before marking RLF-NOTATION verified.
