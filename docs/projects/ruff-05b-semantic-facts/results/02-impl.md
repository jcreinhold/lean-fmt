---
kind: result
claim_id: RSF-IMPL
status: verified
---

# RSF-IMPL — semantic tier, schema v4, notation-spacing capture

Built what RSF-SPEC specified: `Tier.semantic` in the engine, `ModuleArtifact` schema `v4` carrying
an optional semantic fact, and the declared notation/atom spacing captured at the on-demand
`analyzeExact` producer as immutable serializable data, demand-gated so nothing outside a
canonical-rendering run pays for it.

## What changed (six source files)

- **`LeanFmt/Rules.lean`** — added `Tier.semantic` above `syntax` in the `source ≤ syntax ≤ semantic`
  lattice; extended `Tier.satisfies` (all nine cases) and `Tier.max` follows for free. Rewrote the
  deferral comment (was "ruff-11 adds semantic") to state that *this* stack adds the tier with a real
  producer (`analyzeExact`), a consumer (the **formatter**, not a rule), and a test — so it is not the
  empty tier `RuleInfo.input` rotted into. **No `Facts.semantic`/`RuleImpl.semantic` case** — the
  notation fact is consumed by the formatter, not a rule; `ruff-11` adds semantic *rules* later.
- **`LeanFmt/ArtifactModel.lean`** — added `NotationSpacing { kind, atoms }` and
  `SemanticProjection { notations }` (Design B: one entry per distinct `SyntaxNodeKind`, atoms ordered
  by position, keyed by kind never by bare token). Added `semantic : Option SemanticProjection := none`
  to `ModuleArtifact`; bumped `artifactSchema` to `lean-fmt.module-artifact.v4`; threaded an optional
  `semantic` parameter (default `none`) through `ofParsedModule` so the plugin call site stays `none`.
- **`LeanFmt/Analysis.lean`** — the capture. `collectKinds` gathers the distinct syntax node kinds in
  the command stream; `collectDeclaredAtoms` walks a `ParserDescr` decl value and collects the
  untrimmed string args of `ParserDescr.symbol`/`.nonReservedSymbol` in source order (pure data — no
  formatter is run, no `Environment` escapes); `captureNotationSpacing` reads each present kind's decl
  from the **live final-command-state environment** (`commandState.env`, line 77, previously
  discarded) and emits one `NotationSpacing` per kind that declares atoms. `analyzeExact` gained a
  `captureSemantic : Bool := false` parameter and populates `semantic` only when it is set.
- **`LeanFmt/Config.lean`** — `RulePlan.demandedTier (renderCanonical)` = `requiredTier.max (if
  renderCanonical then .semantic else .source)`. This is the one seam where the formatter's demand
  enters planning; no rule fold can reach `semantic`, so a rendering mode is its sole demander.
- **`LeanFmt/Application.lean`** — wired the demand. `execute` computes `demanded := plan.demandedTier
  renderCanonical`; when it reaches `.semantic` the plugin artifact (always `semantic = none`) is not
  fetched, so a `format`/`diff`/`fix` run re-analyzes via `analyzeExact` with `captureSemantic := true`
  — this is the recorded gating cost *and* the rejection of a fact-free artifact. Threaded
  `captureSemantic` through `analyzeSnapshot` → `envelope` → the `__analyze-exact` subprocess (a
  trailing optional 5th arg; a 4-arg invocation stays syntax-only, preserving every existing harness).
- **`LeanFmtTest.lean`** — tests below.

The compiler plugin (`CompilerPlugin.lean`) was **not touched**; its call to `ofParsedModule` passes
no `semantic`, so it keeps emitting `none`. The import closure and Lake glob are unchanged.

## Capture mechanism

Declared spacing is recovered as **pure data** from each notation's `ParserDescr` decl value:
`env.find? kind >>= (·.value?)` is a `ParserDescr` `Expr`; the walker collects the untrimmed `String`
arguments of `ParserDescr.symbol` / `.nonReservedSymbol` in encounter order. Name-carrying strings
(`andthen`, category `term`) are skipped because they are arguments of other constructors. This reads
the pretty-printing hint the parser trims away (`Parser/Basic.lean:1114`, documented
`Init/Prelude.lean:5389`) without running the formatter or touching `CoreM`. Separators (`sepBy`) and
builtin non-notation kinds contribute nothing and degrade to conservative source bytes, never invented
spacing — matching the roadmap stop-rule.

## Commands and evidence

- `LEAN_NUM_THREADS=1 lake build` — clean (36 jobs). `lake build lean-fmt-tests` — clean.
- `.lake/build/bin/lean-fmt-tests` → `lean-fmt module-artifact tests passed`.
- `tests/boundary/run.sh` → passed; plugin `import all` line is still exactly `ArtifactModel`, no
  closure or glob growth.
- `tests/modes/run.sh` → passed (format/diff/fix now route through `analyzeExact`; still correct).
- `tests/check/run.sh` → passed (exit 0). First run surfaced the arity break — the harness calls
  `__analyze-exact` with 4 args; fixed by making `captureSemantic` a trailing optional argument.
- `tests/compiler/run.sh` → passed (the `Broken` build error is the intended negative fixture).
- Stack structural checker (`check_stack.py --structural`) → `OK: 3 prompt(s), 0 warning(s)`.
- `git diff --check` → clean.

### Tests added (persistent)

- **`testEngineTiers`** — the `semantic` lattice: `satisfies`/`max` over the new case both directions.
- **`testMixedSelection`** — `demandedTier`: a shipped-rule plan demands `.source` without rendering
  and `.semantic` with it.
- **`testSemanticArtifact`** — the `v4` fact round-trips through the codec; `semantic = none`
  round-trips and stays valid; a stale `v3` schema is a clean miss; and a *fieldless* `v3` payload
  (no `semantic` key, faithful to a pre-field artifact) decodes total-ly to `none` and then misses on
  the schema guard — proving the optional field is additive, not a decode crash.
- **Compile-time capture acceptance** (a `run_cmd` over two locally-declared notations) —
  `collectDeclaredAtoms` recovers the *untrimmed* `" ⊹leanfmt⊹ "` (breakable both sides) and tight
  `"⊟leanfmt⊟"`, and never the trimmed token. This runs against real `notation`/`prefix`-generated
  `ParserDescr`s. It is in-module by necessity: under the module system an *imported* notation's decl
  body is hidden (`value?` is `none` without `import all`), while `analyzeExact` reads the live
  frontend environment where every value is present. The full fresh-frontend `pushToken` differential
  is RSF-FINAL's.

## Deviations and notes

- **Capture is scoped to `symbol`/`nonReservedSymbol`** (the operator atoms `RLF-NOTATION` needs).
  `sepBy` separators are out of scope and degrade to source bytes; recorded here so RSF-FINAL and
  `ruff-03` know the boundary rather than discovering it.
- **`format` now always runs `analyzeExact`** rather than reading the cheap plugin `.olean`, because
  the plugin artifact cannot carry the semantic fact (F3/F4). This is the roadmap's "recorded cost,
  not hidden" made real; RSF-FINAL measures its envelope. A warm `ResultCache` still serves repeat
  format runs — only the cold path pays.

## Remaining uncertainty (for RSF-FINAL)

- The fresh-frontend `pushToken` differential (captured == Lean's own emitted spacing) for core *and*
  a corpus-declared notation, and its non-vacuity (a deliberately wrong capture must fail it).
- Demand-gating proven end-to-end both directions on a real project (no-capture fast path present-on-
  format, plus the plugin-artifact rejection observed, not just unit-asserted).
- Cost envelope: time and peak aggregate RSS on the frozen sample against the syntax-only baseline.
