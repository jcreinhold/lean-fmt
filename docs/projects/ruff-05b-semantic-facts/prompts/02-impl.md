---
claim_id: RSF-IMPL
status: verified
depends_on: [RSF-SPEC]
---

# Implement the semantic tier, schema bump, and notation-spacing capture

> **REOPENED by prompt-repair (2026-07-17).** The first pass of RSF-IMPL captured spacing by reading
> the notation decl's **kernel value** (`env.find? kind >>= (·.value?)`, an `Expr`). That path is
> module-system-incompatible: in a `module`-mode file the imported constant's *value* is stripped
> (even `import all` does not restore it), so the capture returns **nothing** for imported notations.
> The frozen mathlib sample is ~99% module-mode (60/62 sample files; 8194/8264 of `Mathlib/`), so the
> fact was empty for essentially the entire target corpus — the RSF-FINAL audit caught this
> (`results/03-final.md`, `evidence/02-module-mode-blocker.txt`). RSF-SPEC never chose `value?`; it
> named the **registered formatter** as authoritative and, in `notes/01-semantic-facts.md` §5, "a
> data-only atom store, if one exists" as the preferred mechanism to find first. That store exists and
> is module-safe: **`evalConst Lean.ParserDescr kind`** reads the descriptor through the compiled
> **meta** IR (retained in module mode — notation lowers to a `meta def : ParserDescr`,
> `~/Code/lean4/src/Lean/Elab/Syntax.lean:445-449`), the same route the parser and pretty printer use
> (`Lean/PrettyPrinter/Basic.lean:20-30`, `Lean/MonadEnv.lean:181-185`). This reopening re-implements
> the capture on that path. Everything else RSF-IMPL delivered (the tier, schema `v4`, demand-gating,
> the artifact codec, the test scaffold) is correct and stands; only the capture mechanism changes.

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
  `Environment` is live, reading each present kind's **`ParserDescr` via `evalConst Lean.ParserDescr
  kind`** — the descriptor the registered formatter itself interprets (the parser's inverse), obtained
  through the compiled meta IR so it is **module-safe**. Walk the `ParserDescr` for its untrimmed
  `.symbol` / `.nonReservedSymbol` / `.unicodeSymbol` atoms in source order. Do **not** read
  `ConstantInfo.value?` (the kernel `Expr`) — it is stripped for imported notations under the module
  system and yields empty capture on ~99% of the corpus. Extract into serializable data *there*; no
  live `Environment` crosses into `ModuleArtifact` construction or downstream. A kind whose descriptor
  `evalConst` cannot resolve (not a `ParserDescr`, or eval fails) degrades to conservative source
  bytes, never invented spacing.
  - `evalConst` runs compiled code, so the capture seam is `unsafe`/effectful (it already is —
    `analyzeExact` is `unsafe` with initializers enabled); thread it through the monad rather than
    forcing a pure lookup. Confirm module-safety on a `module`-mode fixture, not only a non-module one.
- **The always-on plugin keeps emitting `semantic = none`.** Do not add capture to
  `LeanFmt/CompilerPlugin.lean`, and **do not grow its import closure or Lake glob**
  (`tests/boundary/run.sh` pins both): the plugin is linked into every target build. If capture is
  wrongly placed there, every integrated build pays the probe — stop and keep it in `analyzeExact`.
- Implement demand-gating: `analyzeExact` computes `semantic = some` iff the run's required tier
  reaches `semantic` (a `format` run always does; a source/syntax-only report does not and may be
  served by the cheap cached plugin artifact). Record the gating seam. A `format` run rejects a
  `semantic = none` cache and re-analyzes.
- Add persistent regression tests: the fact round-trips through the `v4` codec, a `v3` artifact is a
  clean miss (not a crash), and the captured spacing for the fixtures equals Lean's declared strings —
  **including at least one `module`-mode fixture with an imported notation**, the case the first pass
  missed. The capture on a module-mode file must be non-empty for imported operators.
- Write `results/02-impl.md`; update `state/current.md` after reading checks; regenerate `state/next.md`.

## Plan

1. Add the tier case and fold it through selection/planning; keep the existing tests green.
2. Bump the schema to `v4`; write the additive optional-field codec and its total decoder; version the
   digest.
3. Capture the fact in `analyzeExact` via `evalConst Lean.ParserDescr kind` on each present kind,
   walking the descriptor for its untrimmed atoms; serialize; confirm the plugin is untouched and its
   closure/glob did not grow. Prove it on a module-mode fixture, not only a non-module one.
4. Wire demand-gating; prove the fast path survives when nothing semantic is needed.
5. Test round-trip, version miss, and spacing correctness on the fixtures, module-mode included.

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
- **Run the capture on a `module`-mode file** (a small local fixture or one frozen-sample module) and
  confirm `semantic.notations` is non-empty for its imported operators — the module-safety check whose
  absence let the `value?` defect ship. Read the captured atoms, do not assume them.
- Use focused fixtures and the frozen sample for scale; complete mathlib is forbidden.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-05b-semantic-facts`.
- Run `git diff --check` and read all output before marking RSF-IMPL verified.
