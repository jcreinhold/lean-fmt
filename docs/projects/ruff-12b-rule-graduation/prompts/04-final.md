---
claim_id: RGR-FINAL
status: verified
depends_on: [RGR-IMPL]
---

# Accept the graduated catalog

## Task

Deliver **RGR-FINAL**: Re-run the corpus with the shipped defaults, confirm the cost policy holds on
both build states, confirm every remaining preview rule has a stated path out of preview, and record
the catalog `ruff-20-acceptance` will accept.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- `results/04-final.md` records the catalog as shipped: every rule, its tier, its lifecycle, whether
  it is default, whether it is fixable, and — for anything still in preview — the condition that
  would graduate it. This table is what `ruff-20` audits against, so it must be readable without the
  three prior result notes.
- Re-run the frozen sample and the stress files with the **shipped default set** and confirm the
  finding counts match what `RGR-EVIDENCE` predicted for that set. A mismatch here means something
  changed between measurement and shipping, and finding that is this prompt's job.
- Confirm the default-path cost policy holds as shipped, on `ordinary-built` **and**
  `formatter-integrated-built`, with `ruff-19`'s variance policy applied: median of at least three,
  never the first run, spread reported beside the median, machine conditions recorded.
- Confirm `ruff-19`'s gates pass as shipped, or that any re-derived gate carries its derivation and
  still discriminates — `tests/performance/negative.sh` is the existing means of proving that, and a
  re-derived gate that was never negative-tested is a gate nobody has seen fail.
- Confirm the documentation surface agrees with the catalog: `lean-fmt rules`, `lean-fmt explain` for
  every live and retired code, the generated docs, `docs/adding-a-rule.md`'s tier guidance, and any
  rule count quoted in prose anywhere in the repository. A quoted count that drifts is the kind of
  small false claim that makes a reader distrust the large true ones.
- Update `state/current.md` only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Reproduce and characterize the current boundary relevant to this claim.
2. Design the interface twice when the prompt introduces a new abstraction; compare caller knowledge,
   invariants hidden, error surface, exactness, cache identity, critical path, and memory enforceability.
3. Implement the smallest deep capability satisfying the roadmap contract and remove superseded production
   paths rather than retaining parallel architectures.
4. Exercise positive, negative, malformed, stale, custom-syntax, Unicode, and resource cases appropriate to
   the feature.
5. Inspect all callers and documentation for leaked mechanism or claims stronger than evidence.

## Stop

- Do not accept a catalog whose shipped behaviour differs from `RGR-EVIDENCE`'s measurements without
  explaining the difference.
- No full mathlib run; that licence is `ruff-20-acceptance`'s alone.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build`, `lake lint`, `lake exe lean-fmt-tests`, and every suite in
  `tests/*/run.sh`.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Run `tests/performance/run.sh` and `tests/performance/negative.sh`.
- Run `lake exe lean-fmt docs --check`.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-12b-rule-graduation`.
- Run `git diff --check` and read all output before marking RGR-FINAL verified.
