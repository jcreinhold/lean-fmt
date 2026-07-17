---
kind: result
claim_id: RSF-IMPL
status: verified
---

> **RE-IMPLEMENTED (2026-07-17, prompt-repair).** The first pass captured spacing by reading the
> notation decl's kernel value (`env.find? kind >>= (·.value?)`, an `Expr`), which the module system
> strips for imported constants — empty capture on ~99% of mathlib. The RSF-FINAL audit caught it. The
> capture now reads the descriptor through the compiled **meta** IR via `evalConst Lean.ParserDescr`
> (module-safe; the route the parser and pretty printer already use), guarded to
> `ParserDescr`/`TrailingParserDescr` exactly as `Lean/PrettyPrinter/Basic.lean` `runForNodeKind` does.
> The tier, schema `v4`, demand-gating, codec, and test scaffold from the first pass are unchanged and
> stand. The **new module-safety acceptance test** — a `module`-mode fixture whose imported `+`/`*`
> values are stripped, yet whose spacing `evalConst` recovers — is what the first pass lacked and is
> what this note records as verified. The "Capture mechanism" and "Tests" sections below describe the
> re-implemented path; the rest is unchanged from the original delivery.

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
  the command stream; `descrAtoms` walks a `ParserDescr` and collects the untrimmed strings of its
  `symbol`/`nonReservedSymbol`/`unicodeSymbol` atoms in source order, recursing through the structural
  combinators (`unary`/`binary`/`node`/`trailingNode`/`nodeWithAntiquot`, and into a `sepBy` separator
  sub-parser); `captureNotationSpacing` reads each present kind's descriptor from the **live
  final-command-state environment** (`commandState.env`, previously discarded) via `evalConst`, and
  emits one `NotationSpacing` per kind that declares atoms. `analyzeExact` gained a
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

## Capture mechanism (module-safe)

Declared spacing is recovered from each present kind's `ParserDescr`, read through the compiled
**meta** IR via `env.evalConst Lean.ParserDescr options kind`. Notation lowers to a
`meta def : ParserDescr` (`~/Code/lean4/src/Lean/Elab/Syntax.lean:445-449`); the module system
**retains** that meta IR for imported constants — which is exactly why parsing imported notations keeps
working in module-mode files — whereas it **strips** the kernel value (`ConstantInfo.value?`, an
`Expr`). The first pass read `value?` and so captured nothing on the ~99% of the corpus that is
module-mode; this reads the descriptor the parser and pretty printer themselves interpret. The type is
guarded to `ParserDescr`/`TrailingParserDescr` before eval, exactly as `Lean/PrettyPrinter/Basic.lean`
`runForNodeKind` does — so `infixl`/`infixr` trailing notations (typed `TrailingParserDescr`) are
captured, not dropped. `descrAtoms` then walks the descriptor for the untrimmed `String` of each
`symbol`/`nonReservedSymbol`/`unicodeSymbol`, in source order, recursing through the structural
combinators. This reads the pretty-printing hint the parser trims away (`Parser/Basic.lean:1114`,
documented `Init/Prelude.lean:5389`). `evalConst` runs compiled code, so `captureNotationSpacing` is
`unsafe` (its only caller, `analyzeExact`, already is with initializers enabled); no `CoreM` or live
`Environment` crosses the producer boundary — only the serialized atoms. A kind that is not a
descriptor, or whose eval fails, is omitted; `sepBy` separators and builtin non-notation kinds
degrade to conservative source bytes, never invented spacing — matching the roadmap stop-rule.

## Commands and evidence

- `LEAN_NUM_THREADS=1 lake build` — clean (36 jobs). `lake build lean-fmt-tests` — clean.
- `.lake/build/bin/lean-fmt-tests` → `lean-fmt module-artifact tests passed`.
- `tests/boundary/run.sh` → passed; plugin `import all` line is still exactly `ArtifactModel`, no
  closure or glob growth.
- `tests/modes/run.sh` → passed (format/diff/fix now route through `analyzeExact`; still correct).
- `tests/check/run.sh` → passed (exit 0). First run surfaced the arity break — the harness calls
  `__analyze-exact` with 4 args; fixed by making `captureSemantic` a trailing optional argument.
- `tests/compiler/run.sh` → passed (the `Broken` build error is the intended negative fixture).
- `tests/semantic/run.sh` → passed on the now **`module`-mode** `Notation.lean` fixture: the imported
  `«term_+_»`/`«term_*_»` (values stripped by the module system) and the local `«term_⊕corpus_»`
  all capture their untrimmed atoms through the real `__analyze-exact` production path — the
  module-safety check the first pass lacked, on production code end to end.
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
- **Module-safety acceptance** (a `run_cmd`, the test the first pass lacked) — `LeanFmtTest.lean` is
  itself `module`-mode, so every *imported* notation's `value?` is stripped there. The test asserts
  `value?` is **absent** for core `«term_+_»`/`«term_*_»`/`«term-_»`, and that `kindAtoms` (the
  production `evalConst`/`descrAtoms` path) nonetheless recovers their untrimmed `" + "`/`" * "`/`"-"`.
  This is precisely the case the `value?` path returned empty for; it now passes, and would fail on the
  old mechanism.
- **Compile-time capture acceptance** (a `run_cmd` over two locally-declared notations) — `kindAtoms`
  recovers the *untrimmed* `" ⊹leanfmt⊹ "` (breakable both sides) and tight `"⊟leanfmt⊟"`, and never
  the trimmed token. This runs against real `notation`/`prefix`-generated `ParserDescr`s. The full
  fresh-frontend `pushToken` differential — core *and* corpus, on a `module`-mode fixture — is
  RSF-FINAL's (`tests/semantic/run.sh`).

## Deviations and notes

- **Capture is scoped to `symbol`/`nonReservedSymbol`/`unicodeSymbol`** (the operator atoms
  `RLF-NOTATION` needs). A `sepBy`/`sepBy1` separator is captured only via the `symbol` inside its
  `psep` sub-parser, not the bare antiquot-separator string; kinds that are not descriptors degrade to
  source bytes. Recorded here so RSF-FINAL and `ruff-03` know the boundary rather than discovering it.
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
