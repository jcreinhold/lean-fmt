---
claim_id: RSF-IMPL
status: planned
depends_on: [RSF-SPEC]
---

# Implement the semantic tier, schema bump, and notation-spacing capture

## Task

Deliver **RSF-IMPL**: build what `RSF-SPEC` specified — `Tier.semantic` in the engine, `ModuleArtifact`
schema `v4` carrying the semantic fact, and the declared notation/atom spacing captured at the
**on-demand `analyzeExact` producer** where `getEnv` is live — as immutable serializable data,
preserving the source/syntax fast paths under demand-gating.

> **RSF-SPEC settled two points this prompt's earlier draft got wrong** (`notes/01-semantic-facts.md`
> §1, `results/01-spec.md`); build to these, not to the older wording:
> - **Source of the gap: the registered formatter, not the token table.** The parser trims the symbol
>   (`Parser/Basic.lean:1114`), so the token table holds `"+"`; only the notation's formatter carries
>   the untrimmed `" + "` pp-hint (`PrettyPrinter/Formatter.lean:442-446`). Capture reads the formatter
>   (the parser's inverse), never the token table.
> - **Location: `analyzeExact`, not the always-on plugin.** Both producers have a live `Environment`
>   (`Analysis.lean:77`; `CompilerPlugin.lean:27`), but capturing at the always-on plugin would run a
>   formatter probe in every integrated build — the exact always-on tax demand-gating forbids. The
>   plugin keeps emitting `semantic = none`; `analyzeExact` captures `some` only under demand.

Read `roadmap.md`, `notes/01-semantic-facts.md` (the chosen design), the prerequisite stack results,
`AGENTS.md`, and the relevant Lean compiler sources. Do not re-open the representation decision; build
the one `RSF-SPEC` chose.

## Target

- Add `Tier.semantic` to the engine (`LeanFmt/Rules.lean` / the tier type) and fold it through
  `RulePlan.requiredTier` and mixed-tier planning. Keep selection a projection over facts; touch no
  worker/artifact/cache/scheduling authority.
- Extend `ModuleArtifact` from `v3` to `v4` with the semantic fact as an **optional** field
  (`semantic : Option SemanticProjection := none`, `LeanFmt/ArtifactModel.lean`), additive to the
  lossless `source` projection. The wire format stays compact per the projection's fixed-shape-array
  convention; the decoder is total and rejects a wrong shape (including a `v3` payload) as an ordinary
  miss. The semantic table follows Design B — one entry per distinct present `SyntaxNodeKind`, atom
  gaps ordered by position; keyed by kind, not by bare token.
- Capture declared spacing in `analyzeExact` (`LeanFmt/Analysis.lean`) where the final command state /
  `Environment` is live (line 77), reading the notation's **registered formatter** (the parser's
  inverse) rather than reimplementing `pushToken` or reading the token table. Extract it into
  serializable data *there*; no live `Environment` crosses into `ModuleArtifact` construction or
  downstream. An atom whose declaration the lookup cannot resolve degrades to conservative source
  bytes, never invented spacing.
- **The always-on plugin keeps emitting `semantic = none`.** Do not add capture to
  `LeanFmt/CompilerPlugin.lean`, and **do not grow its import closure or Lake glob**
  (`tests/boundary/run.sh` pins both): the plugin is linked into every target build. If capture is
  wrongly placed there, every integrated build pays the probe — stop and keep it in `analyzeExact`.
- Implement demand-gating: `analyzeExact` computes `semantic = some` iff the run's required tier
  reaches `semantic` (a `format` run always does; a source/syntax-only report does not and may be
  served by the cheap cached plugin artifact). Record the gating seam. A `format` run rejects a
  `semantic = none` cache and re-analyzes.
- Add persistent regression tests: the fact round-trips through the `v4` codec, a `v3` artifact is a
  clean miss (not a crash), and the captured spacing for the fixtures equals Lean's declared strings.
- Write `results/02-impl.md`; update `state/current.md` after reading checks; regenerate `state/next.md`.

## Plan

1. Add the tier case and fold it through selection/planning; keep the existing tests green.
2. Bump the schema to `v4`; write the additive optional-field codec and its total decoder; version the
   digest.
3. Capture the fact in `analyzeExact` from the live environment via the registered formatter;
   serialize; confirm the plugin is untouched and its closure/glob did not grow.
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
