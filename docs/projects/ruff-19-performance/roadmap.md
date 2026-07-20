---
kind: roadmap
topic: "Ruff-class performance and resource regression system"
main_results: [RPR-FINAL]
prereq_stacks: [ruff-01-lossless-source, ruff-04-formatter-product, ruff-10b-syntax-fix-composition, ruff-12-rule-lifecycle, ruff-17-lsp]
blueprint_tracked: false
---

# Ruff-class performance and resource regression system

## Goal

Rebaseline the richer formatter/linter, prevent phase regressions, and decide measured private concurrency without exposing jobs or weakening the aggregate memory envelope.

## Completion contract

- Persistent profiles separate discovery, config, cache epoch, artifact access, parsing, formatting (including phase-2 reflow's `group`/fit-test cost as a named sub-phase), each rule tier, validation, rendering, and LSP latency; the recorded envelope is the post-reflow baseline (~61.7 MiB, up from the ~60.6 MiB conservative-era figure — still well inside the 8 GiB gate).
- Use microfixtures, adversarial files, the frozen representative mathlib sample, and named stress files; full mathlib remains reserved for final acceptance.
- Test exactly one-worker/one-thread first, then at most two isolated sessions only if it improves end-to-end release time by at least 20% within 8 GiB, normal pressure, and 256 MiB swap.
- Optimizations without meaningful end-to-end gain are removed unless they simplify the design.
- **Revisit the module-artifact granularity `ruff-01` handed forward.** The flattened node table is
  ~45.6% of a real artifact and no shipped consumer reads it (10.26× source on the frozen sample,
  droppable to ~5.6×; `ruff-01-lossless-source/state/current.md`). On measured size, decide whether to
  drop it or narrow it to the syntax boundaries a consumer actually needs — a schema revision under the
  existing stale-miss discipline — or record why the full tree stays.
- **Own the syntax-fix re-projection cost `ruff-10b` handed forward.** `fix` re-projects rendered
  canonical text through a full frontend run (~5.78 s/module, Design A;
  `ruff-10b-syntax-fix-composition/state/current.md`). If graduating syntax rules off preview
  (`ruff-12`) makes that cost material, adopt Design B — a parse-only projection of the rendered text in
  place of full re-elaboration — or record why Design A stays.
- **Root-cause the in-process result-cache miss `ruff-16` handed forward.** A second `Application.execute`
  in one process after a one-file edit pays the full cold price (~70 s versus 0.52 s for the identical
  edit in a fresh process — a 135× penalty; `ruff-16-watch-incremental/results/02-implementation.md`
  decision 3). `ruff-16` routed around it and did not diagnose it: the cause is unknown and lives in
  `Cache`/`Application`, so it is not established which callers are affected beyond the measured one.
  Diagnose it first, then either fix it or record why the miss is correct. If it is fixed, **decide
  whether watch's per-generation re-exec comes out** — measure the in-process generation against the
  ~400 ms child-process fixed cost and remove the workaround only if in-process wins, since re-exec also
  buys the flat retention `ruff-16` measured (16 KiB over 13 generations).

## Work order

1. **RPR-SPEC — Freeze feature-complete workloads and budgets.** Record machine/toolchain/commit, fixture manifests, cache/build states, binary digest, phase schema, expected output digests, latency/RSS/pressure/swap gates, and stop rules.
2. **RPR-IMPL — Remove repeated work and measure private concurrency.** Profile representation, layout, rule tiers, validation, rendering, watch, and LSP. Optimize proven critical paths, including the three revisits the completion contract inherits — the `ruff-01` artifact-size/node-table granularity, the `ruff-10b` syntax-fix re-projection (Design A vs parse-only Design B), and the `ruff-16` in-process result-cache miss (diagnose before optimizing; it may be a correctness bug rather than a cost). Only after single-session work, test exactly two isolated sessions under the adoption rule.
3. **RPR-FINAL — Install durable performance gates.** Add fast per-commit micro/representative checks, scheduled heavier sample checks, saved raw profiles, digest reuse, variance policy, and a result note accepting or rejecting concurrency.

## Evidence and verification

Every prompt writes `results/01-baseline.md`-style result notes with commands, raw measurements,
changed design decisions, and remaining uncertainty. Use focused fixtures, the frozen representative
mathlib sample, and named stress files. Do not run complete mathlib in this stack unless this is the
final acceptance stack and its prompt explicitly authorizes it.

Run the affected Lean build/tests, `tests/boundary/run.sh`, this stack's structural checker, generated-next
check, and `git diff --check`. Performance records name workload, profile, cache/build state,
machine/toolchain/commit, wall time, peak aggregate RSS, pressure, and swap delta.

## Blueprint

This is genuine formatter repository maintenance and introduces no mathematical theorem claim.
Therefore this roadmap sets `blueprint_tracked: false`.

## Stop rules

- Preserve exact ordered imports, search-path precedence, file-local syntax effects, validation identity,
  private application boundaries, and atomic writes.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Prefer pure Lean; another language requires a named unavailable Lean capability and measured benefit.
- Do not restore workers, public strategy controls, accumulated/superset parsing, or per-file Lake runs.
