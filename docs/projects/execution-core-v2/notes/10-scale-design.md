# Scale design repair: let the module system prove what it already knows

## Why the original prompt was not executable

The first scale prompt named three timings but left two architectural choices hidden.

First, production selection is `Array Lake.Module`, while the frozen workload is all 8,795 Lean
sources outside `.lake`. Root library modules do not represent standalone scripts and configuration
sources. A fast result over only buildable modules would therefore be an omission, not acceptance.

Second, the only enabled rules, FMT001 and FMT002, inspect source bytes. Production nevertheless
requires an `AnalysisEnvelope` containing a compiler `ModuleArtifact` and command projection before
it can carry their findings. That makes exact frontend construction appear semantically necessary
when it is only required by the representation. Filling `commands` with an empty array would hide
the problem and falsely claim syntax evidence.

## Chosen capability split

The application continues to expose one private intent-to-report operation. Beneath it, one source
target owns project-relative identity, an immutable source snapshot, and exact Lake setup/build
evidence. Buildable and standalone sources are variations hidden inside that capability, not two CLI
orchestration paths.

The canonical semantic result contains only product facts: source identity, findings, diagnostics,
and the validation evidence that authorizes them. Compiler command shapes remain in the compiler
artifact representation until a syntax-dependent rule asks for them. Each rule declares whether it
needs source bytes or exact syntax, and one rule plan computes the strongest required input.

This lets the module system discharge the common case. If Lake proves the ordinary `.olean` current,
then that exact source and setup compiled successfully. Source-only rules can run directly without
loading its environment. This is stronger validation than the formatter's syntax-only minimum, but
it does not pretend to provide a syntax tree. A stale or missing output is an ordinary miss and falls
through to trusted formatter artifacts or the fresh exact frontend. A syntax rule can never consume
the source-only witness.

Edited output is different: the current `.olean` describes the old bytes, so `fix` retains fresh exact
validation before publication.

## Designs compared

1. **Fresh exact frontend for every source.** It is the differential oracle and safest fallback, but
   measured import/process cost projects far beyond the target and safe concurrency cannot close the
   gap.
2. **Current module evidence plus semantic rule requirements.** It reuses Lake's existing exact build
   ownership, removes frontend work for source-only rules, fails closed on stale traces, and does not
   invent syntax. This is the preferred ordinary-built path pending differential measurement.
3. **Direct formatter facet consumption.** A trusted official facet already owns syntax-derived data
   for integrated builds. Direct trace-validated reading should replace the current private facet and
   per-module extractor subprocess, pending corruption and identity tests.
4. **Accumulated imports in one process.** Earlier experiments improved throughput but did not prove
   exact isolation or long-run reclamation. It remains rejected production architecture.
5. **Many isolated frontend children.** Process exit gives reclamation and crash isolation, but each
   child retains a large import environment. At most two private children may be reconsidered after
   repeated work is removed and only under the unchanged aggregate envelope.

## Cache consequence

Cache entries identify semantic results, not the evidence used to obtain them. The cache must accept
the generalized source target rather than require a `Lake.Module`. Buildable modules use evaluated
module configuration and current traced artifacts. Standalone sources use their exact Lake setup and
the same validated aggregate environment. An all-hit run starts no Lean frontend or extractor; a
small amount of Lake setup work for the standalone remainder is acceptable only if measured and the
complete warm target still passes. Thousands of per-module setup jobs on the hit path are not.

## Evidence order

The repaired prompt first proves complete selection, then separates semantic result from compiler
projection, then measures module evidence and direct official facet access. Only a sample-projected
release candidate earns a full 8,795-source run. This preserves the evidence policy and prevents a
long run from compensating for a known design error.

## First retained measurement

The shared typed Lake graph validates the frozen 62-file sample in 3.679 seconds as an isolated
probe. Integrated into production, complete workspace loading, snapshotting, validation, source-rule
execution, projection, and JSON rendering take 1.967 seconds at 709,936 KiB peak RSS. The previous
per-file orchestration was stopped after 180.958 seconds on only eight sources and had already peaked
at 4,776,128 KiB. The optimization is retained because it both removes a false compiler DTO
dependency and improves the measured critical path by more than an order of magnitude.

Complete discovery finds 8,788 modules and seven standalone sources in the frozen 8,795-source
workload. Of the modules, 8,781 are current and seven script/tool targets are stale. A diagnostic full
run accidentally triggered by a Bash-3.2-incompatible wrapper finished in 63.647 seconds, establishing
plausibility, but its pre-fix lakefile errors and invalid invocation exclude it from acceptance.
