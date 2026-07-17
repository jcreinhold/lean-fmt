---
kind: roadmap
topic: "Semantic fact tier and Environment-derived projections"
main_results: [RSF-FINAL]
prereq_stacks: [ruff-01-lossless-source, ruff-05-rule-engine]
blueprint_tracked: false
---

# Semantic fact tier and Environment-derived projections

## Goal

Introduce the **semantic fact tier**: the machinery to capture immutable, `Environment`-derived facts
into the exact analysis artifact, add `Tier.semantic` to the rule engine, and ship the first such
fact — each notation and atom's *declared* inter-token spacing — so the formatter can canonically
space operators and future semantic rules can consume elaboration evidence. This stack exists because
two consumers need the same missing infrastructure: `ruff-03`'s reflowing formatter (which needs
declared spacing to canonicalize `a+b` into `a + b` and to break operators at the margin) and
`ruff-11`'s compiler-backed lint rules. `ruff-05` deliberately shipped `Tier` with `source` and
`syntax` only — "a tier nothing can produce is a tier nothing tests" (`ruff-05` state) — and pointed at
the semantic tier as future work. This is that work, carved as its own foundation so neither consumer
owns infrastructure the other also depends on.

## Why this is a foundation and not part of a consumer

The semantic-fact machinery is shared by the formatter and the lint rules; burying it in either one
complects two independent concerns (`deep-module-design` §8). The declared-spacing fact also forces an
architecture decision neither consumer should own alone: capture needs the `Environment`, which is
live only at the compiler-plugin producer (`LeanFmt/CompilerPlugin.lean:27`, `getEnv`), so a semantic
fact is produced *there* and crosses into downstream code only as immutable data — never as a live
`Environment`, matching `ruff-11`'s standing contract.

## Completion contract

- `Tier.semantic` exists in the engine; `RulePlan.requiredTier` folds it; mixed-tier planning includes
  it. Selection remains a projection over facts and never selects worker/artifact/cache/scheduling.
- Semantic facts are **immutable projections in the artifact** (schema bump `v3` → `v4`), never a
  mutable `Environment`, `CoreM` action, or elaborator lifecycle handed downstream.
- The declared notation/atom spacing fact is captured where the `Environment` is live from the
  notation's **registered formatter** — the parser's pretty-printing inverse, which alone carries the
  untrimmed atom string; the parser trims it, so the token table cannot (RSF-SPEC F1,
  `notes/01-semantic-facts.md` §1). It is serializable, is additive (the lossless `source` projection
  is unchanged), and matches Lean's own `pushToken` spacing for core *and* corpus-declared notations,
  verified by fresh-frontend differential.
- **Demand-gating is honest.** Semantic capture runs only when a consumer needs it. A project that
  neither runs a semantic rule nor formats keeps the syntax-only fast path. Formatting demands the
  notation fact, so `format` requires the semantic artifact — this cost is recorded, not hidden.
- The semantic fact enters the artifact digest; the schema-version bump is explicit and cache identity
  is exact across it.

## Work order

1. **RSF-SPEC — Characterize the semantic fact boundary and design the tier twice.** Inventory what the
   `Environment` exposes at the plugin producer (token table, notation declarations, the
   `pushToken`/`parseToken` spacing path, `PrettyPrinter/Formatter.lean:357-417`). Characterize the
   declared notation/atom spacing fact precisely on fixtures (core `_ + _`, a corpus-declared notation,
   an asymmetric-spacing atom). Design the fact representation twice — per-node spacing recorded inline
   versus a module-level table keyed by syntax-kind/token — and compare on artifact size, cache
   identity, staleness across toolchain bumps, and open-set expressibility. Specify the `Tier.semantic`
   shape, the schema bump, and the demand-gating cost model.
2. **RSF-IMPL — Implement `Tier.semantic`, the schema bump, and notation-spacing capture.** Add
   `Tier.semantic` to the engine and fold it through `requiredTier`/planning. Extend `ModuleArtifact`
   to `v4` carrying the semantic fact. Capture declared spacing at the plugin where `getEnv` is live,
   using Lean's own lookup rather than a reimplementation. Keep the fact immutable and serializable;
   preserve source/syntax fast paths under demand-gating; change no existing finding or format output
   except by enabling the fact.
3. **RSF-FINAL — Verify the fact, cache separation, and cost.** Fresh-frontend differential (captured
   spacing equals Lean's `pushToken` for core and corpus-declared notations), schema and cache-identity
   tests, stale-artifact and toolchain-mismatch behavior, demand-gating (no semantic capture when
   nothing needs it), and time/RSS on the frozen sample against the syntax-only baseline.

## Evidence and verification

Every prompt writes `results/01-spec.md`-style result notes with commands, raw measurements, changed
design decisions, and remaining uncertainty. Use focused fixtures, the frozen representative mathlib
sample, and named stress files. Do not run complete mathlib in this stack.

Run the affected Lean build/tests, `tests/boundary/run.sh`, this stack's structural checker,
generated-next check, and `git diff --check`. Performance records name workload, profile, cache/build
state, machine/toolchain/commit, wall time, peak aggregate RSS, pressure, and swap delta.

## Blueprint

This is genuine formatter repository maintenance and introduces no mathematical theorem claim.
Therefore this roadmap sets `blueprint_tracked: false`.

## Stop rules

- No live `Environment` crosses the producer boundary; only immutable serializable facts do.
- Preserve exact ordered imports, validation identity, private application boundaries, and atomic
  writes. The plugin producer's import closure must not grow (it is linked into every target build).
- Spacing is captured from the notation's registered formatter (the parser's pretty-printing inverse),
  never guessed; a fact absent for a node degrades to the conservative source bytes, never to invented
  spacing.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Prefer pure Lean; another language requires a named unavailable Lean capability and measured benefit.
- Do not restore workers, public strategy controls, accumulated/superset parsing, or per-file Lake runs.
