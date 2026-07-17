---
kind: result
claim_id: RSF-FINAL
status: verified
---

# RSF-FINAL — the semantic notation-spacing fact, accepted

The semantic notation-spacing fact matches Lean's own emitted spacing, the `v4` schema keeps cache
identity exact, demand-gating leaves the syntax-only path untouched when nothing semantic is needed,
and the marginal cost is within noise of the syntax-only baseline. This is the foundation's acceptance
for `ruff-03` reflow and `ruff-11` rules.

## Audit history — a defect was found and fixed, then the audit re-run

The first pass of this audit **falsified an RSF-IMPL implementation choice** and stopped rather than
certifying it. RSF-IMPL had captured spacing by reading each notation's kernel value
(`env.find? kind >>= (·.value?)`, an `Expr`); the fresh-frontend differential against the frozen
mathlib sample showed that value is **stripped by the module system** for imported constants, so the
capture returned *nothing* on the ~99% of the corpus that is module-mode (60/62 sample files;
8194/8264 of `Mathlib/`). RSF-SPEC never chose `value?` — it named the registered formatter and (in
`notes/01-semantic-facts.md` §5) "a data-only atom store, if one exists" — so prompt-repair reopened
RSF-IMPL, not RSF-SPEC. The fix: read the descriptor through the compiled **meta** IR via
`evalConst Lean.ParserDescr` (retained in module mode; the route the parser and pretty printer already
use), guarded to `ParserDescr`/`TrailingParserDescr` as `Lean/PrettyPrinter/Basic.lean`
`runForNodeKind` does. RSF-IMPL was re-implemented and re-verified (`results/02-impl.md`,
`state/current.md` Repair). This note records the audit **re-run against the fixed capture**; the
harnesses below are the same ones that exposed the defect, now green on module-mode inputs.
Evidence of the original defect is preserved in `evidence/02-module-mode-blocker.txt`.

## Fresh-frontend differential — the fact is the compiler's, not ours

`tests/semantic/run.sh` runs the real production capture path (`__analyze-exact`, the on-demand
`analyzeExact` producer) on `tests/semantic/Notation.lean`, now a **`module`-mode** fixture, and
compares against Lean's own `ppTerm` emission produced by a **separate process** (`Emit.lean`) that
never touches the capture code.

- **Core, imported, module-stripped:** `«term_+_» → [" + "]`, `«term_*_» → [" * "]`. These are
  imported operators whose `value?` the module system strips in this fixture; `evalConst` recovers
  their untrimmed spacing regardless. The captured atoms predict Lean's emission byte for byte:
  `"1" + " + " + "2" + " * " + "3" == "1 + 2 * 3"` (the independently-emitted string).
- **Corpus-declared:** `«term_⊕corpus_» → [" ⊕corpus "]`; `"1" + " ⊕corpus " + "2" == "1 ⊕corpus 2"`.
- **Non-vacuous (mutation guard):** a deliberately wrong atom (`" - "` for core, `" WRONG "` for
  corpus) does **not** reproduce the emission — the differential rejects it, so it proves something.

The in-module `LeanFmtTest.lean` `run_cmd`s add: (a) a **module-safety** assertion that core
`«term_+_»`/`«term_*_»`/`«term-_»` have `value? = none` in that module-mode file yet capture
`" + "`/`" * "`/`"-"` — the exact case the `value?` path returned empty for; and (b) the
`ppTerm`-vs-captured differential for three locally-declared operators (breakable-gap infix, tight
infix, symbolic prefix), each with its own non-vacuity check.

## Cache separation and demand-gating

- **`v4` digest is stable:** two identical `captureSemantic=1` runs produce byte-identical artifacts
  (`tests/semantic/run.sh` asserts `on == on2`).
- **`v3` is a clean miss, additive field:** `testSemanticArtifact` (`LeanFmtTest.lean`) round-trips the
  `v4` fact, round-trips `semantic = none`, treats a stale `v3` schema as a miss, and decodes a
  *fieldless* `v3` payload total-ly to `none` then misses on the schema guard (no decode crash).
- **Demand-gating both directions, end to end** (`tests/semantic/run.sh`): `captureSemantic=0` →
  `semantic = null` with a `source` projection **byte-identical** to the capturing run (only the schema
  tag advances to `v4`); `captureSemantic=1` → `semantic` present. A `format` run demands `.semantic`,
  so it rejects the plugin's `semantic = none` artifact and re-analyzes — made observable by disabling
  the analyzer and seeing `format` fail (exit 2, `infrastructure-failure`) while `check`, needing only
  source tier, serves the cheap artifact (exit 0).

## Cost envelope — now the real cost, within budget

Two profiled passes over the frozen 62-file module-mode mathlib sample, identical pre-generated setups
reused across both, only the trailing notation-spacing walk differing
(`experiments/run-semantic-cost.sh`; raw in `evidence/03-cost-envelope.txt`,
`experiments/results/semantic-cost-*`).

- **Machine** `Darwin arm64 T6041` · **toolchain** `leanprover/lean4:v4.32.0` · **lean-fmt** `34d6378`
  · **mathlib** `783ccda` · **workload** `mathlib-v4.32.0-sample.txt` (62 files).
- **Baseline** (`captureSemantic=0`): wall 135230 ms, peak RSS 2201376 KiB (~2.10 GiB), swap Δ −8192
  KiB, pressure 1, `hard_stop=none`.
- **Semantic** (`captureSemantic=1`): wall 129913 ms, peak RSS 2203184 KiB (~2.10 GiB), swap Δ −16384
  KiB, pressure 1, `hard_stop=none`.
- **Marginal cost:** Δ peak RSS +1808 KiB (~1.8 MiB); Δ wall −5317 ms (semantic ran *faster* — the two
  passes are separate profiled runs, so the delta is within run-to-run noise, not a speedup). Both
  well within the 8 GiB / 256 MiB-swap ceiling.
- **The measurement is no longer vacuous.** The semantic pass captured **2999** notations across the
  sample; the baseline captured **0** (demand-gating honest). The prior run measured only 68 (two
  non-module files) because the `value?` capture was blind to module-mode files — this run, on the
  fixed `evalConst` capture, exercises the real weight: the descriptor walk is cheap relative to the
  elaboration that dominates each `analyze-exact`.

## Checks

- `LEAN_NUM_THREADS=1 lake build` — clean (36 jobs); `lean-fmt-tests` — clean;
  `.lake/build/bin/lean-fmt-tests` → `lean-fmt module-artifact tests passed`.
- `tests/semantic/run.sh` → differential + non-vacuity + demand-gating + cache stability, all passed
  on the module-mode fixture.
- `tests/boundary/run.sh`, `tests/modes/run.sh`, `tests/check/run.sh`, `tests/compiler/run.sh` → all
  passed; plugin `import all` line is still exactly `ArtifactModel`, no closure or glob growth.
- `experiments/run-semantic-cost.sh` → within envelope; semantic pass captured facts, baseline did not.
- Stack structural checker (`check_stack.py --structural`) → `OK: 3 prompt(s), 0 warning(s)`;
  `write_next.py --check` → matches. `git diff --check` → clean.

## Status

RSF-FINAL: **verified.** The semantic notation-spacing fact is grounded against Lean's own emission on
core and corpus notations in a module-mode file, cache identity and demand-gating are proven both
directions end to end, and the cost is within budget with a non-vacuous measurement. The stack
(RSF-SPEC, RSF-IMPL, RSF-FINAL) is complete. `ruff-03` reflow and `ruff-11` rules can build on the
`Tier.semantic` / `ModuleArtifact.v4` foundation this certifies.
