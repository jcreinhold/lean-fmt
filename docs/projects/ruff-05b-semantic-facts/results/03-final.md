---
kind: result
claim_id: RSF-FINAL
status: planned
---

# RSF-FINAL — audit found a capture defect (module-mode); mechanism repaired, re-audit pending

The RSF-FINAL audit built the differential, demand-gating, cost, and mutation harnesses and ran them.
Four of the five deliverables pass on non-module fixtures. The fifth — the fresh-frontend differential
against the **frozen mathlib sample** — surfaced a real defect: the notation-spacing capture recovered
**nothing** for imported notations in **module-mode** files, which are ~99% of the intended corpus, so
the fact did not deliver its stated purpose (declared operator spacing for `ruff-03` reflow) on real
mathlib. RSF-FINAL is therefore **not verified**.

This is exactly what the audit exists to catch. It falsified an RSF-IMPL implementation choice (reading
the kernel `value?`), which prompt-repair has reopened; RSF-SPEC's claim and representation stand (it
never chose `value?`). The **Resolution** section below shows the defect is a wrong-mechanism problem,
not a fundamental limit — the module-safe capture is identified and proven, and RSF-IMPL is being
re-implemented on it. This note will be rewritten as the acceptance record once the re-audit runs.

## The defect

- **The corpus is module-mode.** 60 of the 62 frozen-sample files, and **8194 / 8264** `.lean` files
  under `Mathlib/` (v4.32.0), begin with the `module` keyword.
- **In module-mode the capture is empty.** `captureNotationSpacing` reads
  `env.find? kind >>= (·.value?)` and walks the `ParserDescr` (`Analysis.lean:78-87`). Under the
  module system an imported constant's *value* is stripped, so every imported notation resolves to
  `none` and is dropped. `__analyze-exact … 1` on `Mathlib/Algebra/Algebra/Rat.lean` — whose parse
  contains `«term_=_»`, `«term_→+*_»`, `«termℚ≥0»`, `«term_<|_»` — yields `semantic.notations: []`.
- **`import all` does not restore it, and neither does the declaring olean.** `module + import all
  Lean`, `import all Init`, even `import all Init.Prelude` (the module that declares `«term_+_»`) all
  leave the value hidden; `readModuleData Init/Prelude.olean` does not list `«term_+_»` among its
  constants at all. The `ParserDescr` value is meta-stripped, not merely import-gated.
- **Non-module files are the only ones that capture.** `Archive/Arithcc.lean` (no `module` keyword)
  captured 55 notations precisely because a non-module env keeps imported values (`import Lean` →
  `«term_+_»` value visible → `" + "`). This is why the in-module `LeanFmtTest.lean` test and the
  `tests/semantic/Notation.lean` fixture (both effectively non-module for the imported-value lookup, or
  using *locally*-declared notations) pass while the real corpus does not.

Evidence: `evidence/02-module-mode-blocker.txt`.

## Why RSF-SPEC / RSF-IMPL are source-false here

- **RSF-SPEC** chose "recover the declared spacing as pure data via `env.find? kind >>= value?`
  walking `ParserDescr.symbol`" (`notes/01-semantic-facts.md`, `results/01-spec.md` F1). That data path
  is incompatible with the module system for imported notations.
- **RSF-IMPL** stated "`analyzeExact` reads the live frontend environment where **every value is
  present**" (`results/02-impl.md`). False for module-mode files — the majority case. RSF-IMPL's tests
  used only non-module fixtures and locally-declared notations, so the gap was invisible until this
  audit ran the frozen sample.
- Notably, the RSF-IMPL **prompt** instructed reading the *registered formatter* ("the parser's
  inverse"), not the `ParserDescr` value; RSF-IMPL deviated to the value path, and that deviation is
  what breaks. The pretty printer (`ppTerm`) **does** work in module-mode — `LeanFmtTest.lean` is
  itself module-mode and its `ppTerm(1 + 2 * 3) = "1 + 2 * 3"` differential passes — so the spacing is
  present through the formatter/`pushToken` machinery, just not as retrievable constant data.

## What the audit did build and confirm (reusable, on non-module fixtures)

- **Fresh-frontend differential + mutation** (`LeanFmtTest.lean` `run_cmd`, `tests/semantic/`): for
  core `+`/`*`/`-` and a corpus-declared `⊕corpus` notation, the captured atom predicts Lean's own
  `ppTerm` emission byte for byte, and a deliberately wrong atom fails it (non-vacuity). The
  `tests/semantic/run.sh` harness runs the real `__analyze-exact` path and recovers core atoms that the
  module system hides in-module.
- **Demand-gating both directions, end to end** (`tests/semantic/run.sh`): `captureSemantic=0` →
  `semantic = null` with a source projection byte-identical to the capturing run; `=1` → present;
  `format` rejects the plugin's `semantic = none` artifact (exit 2 at the disabled analyzer) while
  `check` serves source-tier from it (exit 0).
- **Cache stability**: two `=1` runs produce byte-identical `v4` artifacts.
- **Cost envelope** (`experiments/run-semantic-cost.sh`, `experiments/results/semantic-cost-*`): on the
  frozen 62-module sample, machine `Darwin arm64 T6041`, toolchain `leanprover/lean4:v4.32.0`,
  lean-fmt `2a8cccb`, mathlib `783ccda`. Baseline `captureSemantic=0`: wall 131184 ms, peak RSS
  2200944 KiB (~2.10 GiB), swap Δ 0, pressure 1. Semantic `captureSemantic=1`: wall 130690 ms, peak
  RSS 2200112 KiB, swap Δ 0, pressure 1. Well within the 8 GiB / 256 MiB-swap ceiling; the paired delta
  is within noise (−494 ms, −832 KiB). **Caveat:** this cost is honest but currently measures a
  near-no-op — the semantic pass captured facts for only the 2 non-module files (68 notations total),
  so the envelope's real weight cannot be judged until a module-mode-capable mechanism exists.

## Resolution — the defect is a wrong mechanism, not a fundamental limit

Follow-up (empirical, plus a compiler-source sweep of `~/Code/lean4/src`) established that the spacing
**is** recoverable in module mode; RSF-IMPL simply read the wrong artifact.

- **The formatter path works in module mode.** Parsing `a + b * c` in a `module`-mode env and running
  `ppTerm` on the node emits `"a + b * c"` — the untrimmed `" + "`/`" * "` — while `value?` on the same
  kind is `none`. `LeanFmtTest.lean` (itself module-mode) confirms `ppTerm(1 + 2 * 3) = "1 + 2 * 3"`.
- **The clean data path is `evalConst Lean.ParserDescr kind`.** The compiler sweep traced that the
  pretty printer reaches the descriptor via `evalConst ParserDescr` (compiled **meta** IR), not via
  `ConstantInfo.value?` (kernel `Expr`) — two different artifacts. Notation lowers to a
  `meta def : ParserDescr` (`~/Code/lean4/src/Lean/Elab/Syntax.lean:445-449`); the meta IR is retained
  in module mode (`Lean/Environment.lean:2537-2540`, meta-gated `lean_eval_const`), which is exactly
  why parsing imported notations keeps working. `value?` is stripped; `evalConst` is not.
- **Proven empirically in a module-mode env**: `evalConst ParserDescr` recovers `«term_+_» → " + "`,
  `«term_*_» → " * "`, `«term-_» → "-"`, `«term_=_» → " = "`, `«term_∣_» → " ∣ "`, all with
  `value? = none`. So the fix is a mechanism swap (`value?` → `evalConst ParserDescr`, and a
  `ParserDescr`-constructor walk in place of the `Expr` walk), not a formatter-run rig or a static
  table.

This resolves `notes/01-semantic-facts.md` §5's deferred capture-API uncertainty (it named "a data-only
atom store, if one exists" as the preferred mechanism — this is it). It does **not** reopen RSF-SPEC's
representation (Design B) or the producer seam.

## Status

- RSF-FINAL: **not verified — pending re-audit** after the RSF-IMPL repair lands. The audit's harnesses
  (differential + mutation, demand-gating end-to-end, cache stability, cost envelope) are built and
  correct — they are what exposed the defect — but the differential and cost must be re-run against the
  module-safe capture (the current cost run measured a near-no-op: only the 2 non-module sample files
  captured anything).
- Repair executed: `prompts/02-impl.md` reopened to `planned` with the `evalConst` mechanism;
  `results/02-impl.md` marked superseded; `notes/01-semantic-facts.md` §5 resolved;
  `state/current.md`/`state/next.md` re-pointed to `02-impl`. RSF-SPEC stays verified.
- Nothing here is marked verified. Evidence: `evidence/02-module-mode-blocker.txt`.
