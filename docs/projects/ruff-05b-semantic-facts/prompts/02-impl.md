---
claim_id: RSF-IMPL
status: planned
depends_on: [RSF-SPEC]
---

# Implement the semantic tier, schema bump, and notation-spacing capture

## Task

Deliver **RSF-IMPL**: build what `RSF-SPEC` specified — `Tier.semantic` in the engine, `ModuleArtifact`
schema `v4` carrying the semantic fact, and the declared notation/atom spacing captured at the plugin
producer where `getEnv` is live — as immutable serializable data, preserving the source/syntax fast
paths under demand-gating.

Read `roadmap.md`, `notes/01-semantic-facts.md` (the chosen design), the prerequisite stack results,
`AGENTS.md`, and the relevant Lean compiler sources. Do not re-open the representation decision; build
the one `RSF-SPEC` chose.

## Target

- Add `Tier.semantic` to the engine (`LeanFmt/Rules.lean` / the tier type) and fold it through
  `RulePlan.requiredTier` and mixed-tier planning. Keep selection a projection over facts; touch no
  worker/artifact/cache/scheduling authority.
- Extend `ModuleArtifact` from `v3` to `v4` with the semantic fact (`LeanFmt/ArtifactModel.lean`),
  additive to the lossless `source` projection. The wire format stays compact per the projection's
  fixed-shape-array convention; the decoder is total and rejects a wrong shape as an ordinary miss.
- Capture declared spacing at `LeanFmt/CompilerPlugin.lean` where `environment ← getEnv` is live, using
  Lean's own token-table lookup — not a reimplementation of `pushToken`. Extract it into serializable
  data *there*; no live `Environment` crosses into `ModuleArtifact` construction or downstream.
- **Do not grow the plugin's import closure** (`tests/boundary/run.sh` pins it): the plugin is linked
  into every target build. If the lookup needs a module not already in closure, stop and record it.
- Implement demand-gating: semantic capture runs when a semantic consumer needs it; a syntax-only run
  with no semantic rule and no format keeps its fast path. Record the gating seam.
- Add persistent regression tests: the fact round-trips through the `v4` codec, a `v3` artifact is a
  clean miss (not a crash), and the captured spacing for the fixtures equals Lean's declared strings.
- Write `results/02-impl.md`; update `state/current.md` after reading checks; regenerate `state/next.md`.

## Plan

1. Add the tier case and fold it through selection/planning; keep the existing tests green.
2. Bump the schema to `v4`; write the additive codec and its total decoder; version the digest.
3. Capture the fact at the plugin from the live environment; serialize; confirm no import growth.
4. Wire demand-gating; prove the fast path survives when nothing semantic is needed.
5. Test round-trip, version miss, and spacing correctness on the fixtures.

## Stop

- No live `Environment`, `CoreM`, or elaborator handle crosses the producer boundary.
- The plugin's import closure and Lake glob must not grow; stop and record if the lookup demands it.
- A missing/undecodable semantic fact is an ordinary miss that degrades to conservative bytes, never a
  crash or invented spacing.
- Stop rather than weakening exact semantics, cache identity, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules,
  including the artifact/module suites and the engine tier tests.
- Run `tests/boundary/run.sh` and inspect the plugin boundary manually; confirm no import-closure or
  glob growth.
- Use focused fixtures and the frozen sample for scale; complete mathlib is forbidden.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-05b-semantic-facts`.
- Run `git diff --check` and read all output before marking RSF-IMPL verified.
