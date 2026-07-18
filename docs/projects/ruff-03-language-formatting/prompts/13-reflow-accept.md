---
claim_id: RLF-REFLOW-ACCEPT
status: planned
depends_on: [RLF-OPERATOR-BREAK, RLF-RECORDS, RLF-ACCEPT]
---

# Close the full reflowing formatter

## Task

Deliver **RLF-REFLOW-ACCEPT**: the acceptance for the **complete** reflow set. `RLF-ACCEPT` (`results/10`)
accepted the subset that existed when it ran — `Term.app` β-break plus the `by`/`do` offside re-index —
and cited operator/binder/`match`/record breaking as conservative-with-a-reason. Prompts
`RLF-OPERATOR-BREAK` and `RLF-RECORDS` built that breadth; this prompt re-runs the acceptance over it and
supersedes `RLF-ACCEPT`'s subset coverage claim.

This is an **audit prompt**: it adds tests and evidence and changes production code only to fix a defect
it finds. Read `roadmap.md`, `results/10-reflow-final.md` (the acceptance this extends),
`results/11-operator-break.md` and `results/12-records.md`, `experiments/compare_tokens.py` and
`experiments/run-printer-sample.sh`, `experiments/kind-inventory.txt`, and `AGENTS.md`.

## Target

- Run the idempotence loop (`format (format x) = format x`) and the exact fresh-frontend differential
  (reparse output; compare token stream, comments, **and parse tree** via `compare_tokens.py`) over the
  repository corpus, the frozen mathlib sample, generated over-margin fixtures **for every now-breaking
  construct** (operator chains, multi-binder signatures, wide match arms, over-margin records), and
  malformed input. Any divergence is a blocker to fix or record as a refusal.
- Rebuild the **reflow coverage table** so operators/notations, bracketed binders, `matchAlt`, and
  `structInst` records move from *cited-conservative* to *actively laid out*, each with its grammar
  citation. The only remaining cited-conservative entries are genuine grammatical fallbacks (`where`/
  `let` bodies, focus `·`, own-line application heads, horizontal collapse) — **zero deferred *breaking*
  behaviour** remains. Complete mathlib is forbidden; the frozen sample only.
- Re-measure the **performance envelope** (workload, machine, toolchain, commit, wall time, peak
  aggregate RSS, pressure, swap delta) now that more commands actually break; compare to the
  `RLF-ACCEPT` 60.6 MiB baseline; confirm it holds under the 8 GiB / 256 MiB ceiling.
- Confirm the **non-vacuity** gate still rejects a deliberately parse-changing reflow (the re-association
  fixture) and add a non-vacuity case for a new breaking construct if one can change a parse.
- Write `results/13-reflow-accept.md`; update `state/current.md` (narrow `RLF-ACCEPT` standing to the
  app+offside subset it accepted; mark phase 2 complete, `first_unresolved: none`); regenerate
  `state/next.md`; set `roadmap.md` `main_results` to `[RLF-REFLOW-ACCEPT]` if not already.

## Plan

1. Run the four-way differential over the complete reflow set; triage any divergence as fix-or-refuse.
2. Rebuild the coverage table; verify zero deferred breaking behaviour remains.
3. Re-measure the performance envelope; record.
4. Confirm non-vacuity; extend it if a new construct admits a parseable mutation.
5. Inspect all result notes and state for a claim stronger than the evidence.

## Stop

- Parse-preservation (token + tree) and idempotence are gates; a divergence is a blocker, not a footnote.
- Do not mark accepted any construct whose breaking is not proven parse-preserving by reparse.
- A coverage-table entry with no citation, or a *breaking* deferral with no owning prompt, is the defect
  this prompt exists to prevent — stop rather than ship one.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests`, `tests/printer/run.sh`, `tests/modes/run.sh`,
  the touched unit suites, and `tests/boundary/run.sh`.
- Run `experiments/run-printer-sample.sh` over the frozen mathlib sample; the ownership partition against
  `experiments/kind-inventory.txt` must pass. Complete mathlib is forbidden.
- Run `experiments/check-quoted-figures.py`.
- From the KanProofs tool environment, run the generic stack structural checker and `write_next.py
  --check` for `docs/projects/ruff-03-language-formatting`.
- Run `git diff --check` and read all output before marking RLF-REFLOW-ACCEPT verified.
