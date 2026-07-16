# Prompt 10 scale-design repair

Date: 2026-07-15

## Classification

The prompt was under-scoped and source-false in two places:

- `LeanFmt.Application.selectedModules` accepts only root library modules or explicit files that
  `findModuleBySrc?` recognizes, while ECV2-WORKLOADS freezes all 8,795 non-`.lake` Lean sources.
- FMT001/FMT002 are source-byte rules, but `AnalysisEnvelope` can represent successful analysis only
  through a `ModuleArtifact` containing compiler command shapes. That accidental representation
  coupling makes frontend work look mandatory and leaves no honest source-only fast path.

## Repair

Prompt 10 now requires a complete private source-target capability, exact standalone setup, a
canonical product result distinct from compiler projection, declared rule input requirements,
current `.olean` evidence for source-only rules, direct official facet consumption for integrated
builds, and generalized cache identity. It defines negative differential cases and a bounded
hypothesis ladder before any full mathlib run.

The prompt preserves process-exit reclamation for fresh frontend fallback, the 8 GiB/normal-pressure/
256 MiB envelope, exact edited-source validation, and the late-candidate full-run policy.

## Cheap readiness evidence

- Source inspection confirms default production selection is the union of root `leanLib` module
  arrays, not a filesystem-complete project source selection.
- Explicit source selection rejects any path without a `Lake.Module`.
- `experiments/pure-lean-core/SetupAudit.lean` already demonstrates Lake's
  `setupServerModule` capability for manifest-selected sources, including non-module sources.
- `LeanFmt.Rules.runRules` computes every current finding solely from source bytes; command shapes
  are not read by FMT001 or FMT002.
- Prior measured fresh-process and accumulated-environment results are retained as rejection evidence;
  no new full workload was run during prompt repair.

## Remaining uncertainty

The repair deliberately does not claim that a single batched Lake no-build query, direct official
facet validation, or standalone warm identity meets its timing target. Prompt 10 must measure and
differentially validate each before retaining it.
