---
claim_id: RLF-ACCEPT
status: planned
depends_on: [RLF-BLOCKS]
---

# Close the reflowing formatter: idempotence, parse-preservation, performance

## Task

Deliver **RLF-ACCEPT**: the phase-2 acceptance. Prove the reflowing formatter is idempotent,
parse-preserving, comment-preserving, and within budget across the whole language and the frozen
mathlib sample, and record every construct still on the conservative path with the grammar line that
keeps it there. Supersede `RLF-FINAL`'s "whole-language coverage" claim, which closed the *conservative*
coverage only.

Read `roadmap.md`, `notes/05-reflow-architecture.md`, all phase-2 result notes, `AGENTS.md`, and the
relevant Lean compiler sources. This is an audit prompt: it adds tests and evidence, and changes
production code only to fix a defect it finds.

## Target

- Run the idempotence loop (`format (format x) = format x`) and the exact fresh-frontend differential
  (reparse output, compare token + comment streams, and elaboration where the construct is not
  offside-load-bearing) over the repository corpus, the frozen mathlib sample, generated over-margin
  fixtures, and malformed cases. Any divergence is a blocker to fix or to record as a refusal, per
  `notes/05-reflow-architecture.md` §4.
- Record a **coverage table** of every construct now reflowed versus conservative, each with its
  grammar citation — the reflow analogue of phase 1's kind inventory. Zero *silently* unowned reflow
  behaviour: a construct is either reflowed with a citation or conservative with a citation.
- Record the **performance envelope** for the reflowing formatter: workload, machine, toolchain,
  commit, wall time, peak aggregate RSS, pressure, swap delta, against the flat-run phase-1 baseline —
  reflow's `group` measurement must not have broken `render`'s linear bound (`ruff-02`) nor the
  roadmap's 8 GiB / 256 MiB-swap envelope.
- Add or update persistent regression tests and a mutation check that the idempotence and
  parse-preservation gates are non-vacuous (a deliberately parse-changing reflow must fail them).
- Write `results/10-reflow-final.md` with commands, raw measurements, decisions changed, and remaining
  uncertainty. Update `state/current.md` after reading checks; regenerate `state/next.md`. Update the
  roadmap `main_results` to `RLF-ACCEPT` if not already, and narrow `RLF-FINAL`'s standing in state to
  "conservative-coverage acceptance".

## Plan

1. Assemble the corpus + frozen sample + generated over-margin + malformed inputs.
2. Run idempotence and fresh-frontend differential; triage every divergence as fix-or-refuse.
3. Build the reflow coverage table with citations; prove it partitions accepted syntax.
4. Measure and record the performance envelope against the phase-1 baseline.
5. Mutation-test the gates for non-vacuity; inspect callers/docs for claims stronger than evidence.

## Stop

- Completion requires zero silently unowned reflow behaviour and zero idempotence or
  parse-preservation divergence left unrecorded.
- This prompt is authorized to run the frozen representative sample; **complete mathlib is still
  forbidden** — it is not `RCP-ACCEPT`.
- Stop rather than weakening exact semantics, cache identity, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the full formatter suites (`tests/printer/run.sh`,
  `tests/modes/run.sh`, and the touched-module unit suites).
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Use the frozen sample and synthetic saved reports for scale; complete mathlib is forbidden.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-03-language-formatting`.
- Run `git diff --check` and read all output before marking RLF-ACCEPT verified.
