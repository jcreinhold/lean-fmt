# Next Proof Packet

- Stack: ruff-12b-rule-graduation
- First unresolved: 04-final
- Claim ID: RGR-FINAL
- Prompt: 04-final
- Module: none expected — this is an audit prompt. `LeanFmt/Rules.lean` and `docs/` only if the audit
  finds drift.
- Target file: `results/04-final.md`

## Target Declarations

None. `RGR-FINAL` adds no declaration. If it needs one, the audit found a defect and the defect is the
finding.

## Read Before Editing

This file, `prompts/04-final.md`, `results/03-graduate.md` (what shipped), `results/02-evidence.md`
(the measurements to reproduce against), and `results/01-criteria.md` §5–§6 (cost policy and corpus
pins).

## Proof Task

Deliver **RGR-FINAL**: accept the catalog, or find what drifted between measuring it and shipping it.

1. **Write the standalone catalog table.** Every rule: code, category, tier, lifecycle, default,
   fixable, and — for the nine preview rules — the graduation condition. `ruff-20` audits against this
   table, so it must be readable **without** the three prior result notes. Generate it from
   `lean-fmt rules` and `lean-fmt explain`, not by transcribing `state/current.md`.
2. **Re-run the frozen sample with the shipped default set** and confirm the finding counts match what
   `RGR-EVIDENCE` recorded. The corpus pins are `results/01-criteria.md` §6 (`783ccda4…`/v4.32.0,
   digest `1936bdb6…`). A mismatch is not a nuisance to reconcile — finding it is this prompt's job.
   Note that the shipped default set is *unchanged* from the one `RGR-EVIDENCE` measured, so the
   expected delta is zero and a nonzero one means something moved silently.
3. **Confirm the cost policy on both build states** — `ordinary-built` and
   `formatter-integrated-built` — under `ruff-19`'s variance policy: median of ≥3, never the first
   run, spread beside the median, machine conditions recorded. `experiments/run-cp2-cold-cost.sh`
   already implements that discipline and can be reused.
4. **Confirm `ruff-19`'s gates as shipped.** `RGR-IMPL` did not re-derive any gate, so there is no
   re-derived gate to negative-test; run `tests/performance/run.sh` (whose §0 is `negative.sh`) and
   confirm both.
5. **Audit every quoted rule count in the repository.** `docs/adding-a-rule.md`'s tier guidance,
   README-style prose, `docs/ci.md`, suite fixtures — anywhere a number like "ten preview rules" or
   "fifteen live rules" appears. FMT013 leaving preview changes those counts. A quoted count that
   drifts is the small false claim that makes a reader distrust the large true ones.
6. **Confirm every remaining preview rule has a stated path**, from `explain` output rather than from
   the invariant. The invariant proves the field is nonempty; only reading the nine strings proves
   they say something a reader could act on.

## Reuse

- `experiments/run-cp2-cold-cost.sh` — the two-arm cold-cost harness with the discard-first-run
  discipline already applied.
- `experiments/run-cp1-warm-serve.sh` — the five-arm warm-serve probe, including the anti-vacuity
  check (`cmp` prime-vs-warm report, nonzero line count) that made CP-1 evidence rather than silence.
- `tests/performance/run.sh` §0 is the negative test; it does not need to be invoked separately.
- `lake exe lean-fmt docs --check` gates generated-doc drift; `lake exe lean-fmt rules` and
  `explain <code>` are the catalog's authority.

## Lean Work

Expect none. This prompt reads the built binary and the repository's prose. If it edits Lean, it is
because the audit found the catalog and the code disagreeing, and that disagreement is the result.

## Stop Rules

- Do not accept a catalog whose shipped behaviour differs from `RGR-EVIDENCE` without explaining the
  difference. Reconciling by adjusting the expectation is the failure mode this rule exists to catch.
- **No full mathlib run.** That licence is `ruff-20-acceptance`'s alone. A conclusion that needs the
  complete corpus is a deferral to `ruff-20`, and it should say so rather than guess.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- `LEAN_NUM_THREADS=1 lake build`, `lake lint`, `lake exe lean-fmt-tests`, and **every** suite in
  `tests/*/run.sh` (boundary, cache, catalog, check, ci, compiler, discovery, downstream, imports,
  layout, lossless, modes, performance, printer, reporting, scale, semantic, stream, suppression,
  syntax, watch).
- `tests/performance/run.sh` and `tests/performance/negative.sh`.
- `tests/ci/run.sh` reads **committed** state — commit before running it or it tests the previous
  commit and passes while the change is broken.
- `tests/watch/run.sh` §9.6 fails whenever a `.lean` file is staged; run it with a clean index.
- `lake exe lean-fmt docs --check`.
- `git diff --check`, read in full.
- Structural checkers: expect the same 5 pre-existing `implementation_route` failures every lean-fmt
  stack reports; confirm no new stack-shaped failure.
