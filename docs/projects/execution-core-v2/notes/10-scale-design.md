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

## Final retained design

The production cache is an environment-scoped atomic index rather than one file per semantic result.
The file-per-entry design made a warm 8,795-source lookup take 46.868 seconds before the rest of the
run and multiplied both filesystem metadata operations and publication points. The index loads once,
per-source semantic identities remain independently validated, and a batch merge publishes once.
The final complete warm lookup phase is 3.719 seconds.

The environment epoch hashes current source contents under every ordered non-toolchain
`LEAN_SRC_PATH` root in addition to validating artifact traces and outputs. This is deliberately
coarse: downloaded Lake traces can omit source inputs, so artifact-only hashing admitted false hits
after a dependency source changed. Standalone identities remain setup-free on the hit path; the
shared epoch contains evaluated external configuration and ordered search roots, while the entry
contains its relative path and exact source digest. Exact `ModuleSetup` is deferred until a miss
actually requires frontend analysis.

The formatter-integrated path now consumes the package's registered `module.leanFmtArtifact` facet
directly. One private Lake operation requests the selected jobs with `noBuild := true`, decodes the
official `Lake.Artifact` descriptors, recomputes content hashes, and matches module and full source
snapshot. It never recreates a private facet or launches one extractor per file. The operation is
skipped entirely when all enabled rules are source-only, as FMT001 and FMT002 currently are. Focused
compiler fixtures prove trace invalidation, corruption rejection, exact source matching, failed-build
nonpublication, and explicit rebuild behavior. A full formatter-integrated mathlib run would require
a formatter-integrated prerequisite build and no current rule would consume its syntax, so it was
not a plausible independent acceptance candidate.

The ordinary-built, formatter-cache-cold release candidate completed all 8,795 sources in 109.649
seconds at 1,315,248 KiB peak aggregate RSS. The forced all-hit path completed in 16.290 seconds with
module evidence, artifact access, and the analyzer disabled. Both produced the same path-sorted output
digest. No concurrency was introduced: removing false semantic dependencies, per-file Lake work, and
per-entry cache I/O met the target with a simpler single-operation design.
