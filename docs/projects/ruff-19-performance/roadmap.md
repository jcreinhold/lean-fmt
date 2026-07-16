---
kind: roadmap
topic: "Ruff-class performance and resource regression system"
main_results: [RPR-FINAL]
prereq_stacks: [ruff-04-formatter-product, ruff-12-rule-lifecycle, ruff-17-lsp]
blueprint_tracked: false
---

# Ruff-class performance and resource regression system

## Goal

Rebaseline the richer formatter/linter, prevent phase regressions, and decide measured private concurrency without exposing jobs or weakening the aggregate memory envelope.

## Completion contract

- Persistent profiles separate discovery, config, cache epoch, artifact access, parsing, formatting, each rule tier, validation, rendering, and LSP latency.
- Use microfixtures, adversarial files, the frozen representative mathlib sample, and named stress files; full mathlib remains reserved for final acceptance.
- Test exactly one-worker/one-thread first, then at most two isolated sessions only if it improves end-to-end release time by at least 20% within 8 GiB, normal pressure, and 256 MiB swap.
- Optimizations without meaningful end-to-end gain are removed unless they simplify the design.

## Work order

1. **RPR-SPEC — Freeze feature-complete workloads and budgets.** Record machine/toolchain/commit, fixture manifests, cache/build states, binary digest, phase schema, expected output digests, latency/RSS/pressure/swap gates, and stop rules.
2. **RPR-IMPL — Remove repeated work and measure private concurrency.** Profile representation, layout, rule tiers, validation, rendering, watch, and LSP. Optimize proven critical paths. Only after single-session work, test exactly two isolated sessions under the adoption rule.
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
