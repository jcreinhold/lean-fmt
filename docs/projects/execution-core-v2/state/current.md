---
kind: state
first_unresolved: 10-scale
---

# Current state

The failed implementation is archived and the active production tree is a fresh native Lean 4.32.0
package created with `lake init`. The Rust-first and two-binary prompts have been replaced. Execution
now begins by freezing workload semantics before ordinary-built and compiler-integrated paths proceed
as independent measured prerequisites.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-reset | ECV2-RESET | verified | — |
| 02-native-reset | ECV2-NATIVE-RESET | verified | ECV2-RESET |
| 03-workloads | ECV2-WORKLOADS | verified | ECV2-NATIVE-RESET |
| 04-built-cold | ECV2-BUILT-COLD | verified | ECV2-WORKLOADS |
| 05-compiler-artifacts | ECV2-COMPILER-ARTIFACTS | verified | ECV2-WORKLOADS |
| 06-design | ECV2-DESIGN | verified | ECV2-BUILT-COLD, ECV2-COMPILER-ARTIFACTS |
| 07-check | ECV2-CHECK | verified | ECV2-DESIGN |
| 08-cache | ECV2-CACHE | verified | ECV2-CHECK |
| 09-modes | ECV2-MODES | verified | ECV2-CACHE |
| 10-scale | ECV2-SCALE | planned | ECV2-MODES |
| 11-serve | ECV2-SERVE | planned | ECV2-SCALE |
| 12-final | ECV2-FINAL | planned | ECV2-SERVE |

## Known evidence

- Setup-free imports from existing `.olean`s averaged 697.2 ms/file across load and finalization on
  the deterministic 62-file sample. A 2,031-file sorted-prefix characterization had already taken
  27.9 minutes when deliberately stopped; its sampled peak RSS was 6.48 GiB.
- One process retaining distinct exact contexts crossed 8 GiB during its sixth file.
- A fresh exact child remained below the envelope but cannot meet the goal through safe concurrency.
- A pure Lean module-linter plugin receives exact custom syntax during compilation with no detected
  overhead in the initial sample.
- The active package now uses Lean 4.32's module system throughout. Investigation rejected external
  candidate promotion: the module/Lake build owner must structurally bind plugin, setup, success,
  trace, and publication.
- The selected compiler path stores a compact formatter record in the successful `.olean` and
  exposes it as a package-owned Lake facet. It matched the independent oracle on 62/62 files with
  0.375 ms mean plugin overhead, but one-process-per-module extraction averaged 791.638 ms and is
  therefore a design input rather than the production consumption strategy.
- The first complete `check` operation now resolves the target root's exact Lean/Lake installation,
  consumes source-validated module artifacts, and falls back to a fresh exact frontend child. The
  two paths are byte-identical on findings and custom-syntax fixtures. Direct execution measured
  648,272 KiB for a one-file artifact hit versus roughly 1.3 GiB through a rejected `lake env`
  wrapper; the fallback monitor stopped a deliberately constrained child at 782,896 KiB aggregate.
- Prompt 08's original worker-free cache wording was source-false: executable `lakefile.lean`
  configuration cannot be semantically validated from a fixed static file list. The repaired prompt
  permits measured Lake workspace evaluation but forbids frontend/import environments, analyzer or
  extractor children, and per-file setup jobs on an all-hit run.
- The semantic result cache now validates ordered search roots, 8,782 mathlib root oleans, dependency
  artifacts, and managed shared libraries against Lake traces in 11.302 seconds. A genuine 62-file
  all-hit run took 11.709 seconds total with 40 ms of entry lookup, no analyzer or extractor, 1.03 GiB
  peak RSS, normal pressure, and no swap growth.
- Prompt 09's original list of modes omitted their observable output, configuration precedence,
  compiler-integration behavior, and safe-write transaction. The repaired contract makes selection
  a semantic-result projection, puts all edit sequencing behind one checked patch capability, and
  treats compiler setup as guidance because arbitrary executable `lakefile.lean` is not safely
  text-rewritable.
- Prompt 09 major step 1 is implemented: one private checked-patch capability owns deterministic
  edit ordering, byte/UTF-8 validation, conflict rejection, complete assembly, source identity, and
  exact inverse construction. Its focused unit/property suite passes; validation and atomic
  publication remain in the application transaction.
- Prompt 09 is complete. Check/format/diff/fix now share one canonical semantic result and one
  application transaction; CLI presentation is a separate private module. Strict configuration,
  deterministic previews, exact validated atomic fixes, rules, cache clean, and read-only compiler
  setup/status pass focused unit and integration gates without a full mathlib run.
- Prompt 10's original timing-only task was under-scoped. Production currently selects root Lake
  modules while the frozen workload contains every non-`.lake` source, and its compiler-artifact DTO
  makes source-only FMT001/FMT002 appear to require syntax. The repaired prompt first adds complete
  source targets and honest rule input requirements, then measures current `.olean` validation,
  direct official facets, exact fallback, and cache paths in a bounded hypothesis ladder.
- Prompt 10 major step 1 is implemented. One private project capability selects all 8,795 mathlib
  sources, recovers 8,781 current/7 stale module statuses from one typed Lake graph, and hides the
  seven standalone cases. Source-only semantic results no longer contain fake compiler projections.
  The current 62-file release path fell from a stopped 180.958-second eight-file baseline to 1.967
  seconds for 62 files at 709,936 KiB peak RSS. Focused unit, compiler, check, mode, and new complete-
  selection/cache gates pass; intentional full, exact-remainder, direct-facet, and warm acceptance
  remain.

These facts and the verified batch product surface constrain Prompt 10's optimization hypotheses;
they do not authorize weaker semantics or a broader memory envelope.

## Completed results

- [ECV2-WORKLOADS](../results/03-workloads.md) freezes exact semantics, the independent project
  build/cache axes, deterministic mathlib selection, and the resource-bounded profiling format.
- [ECV2-BUILT-COLD](../results/04-built-cold.md) rejects same-runtime reuse and the ordinary-built
  fresh-process fallback as a competitive path, while preserving it as the exact isolation model.
- [ECV2-COMPILER-ARTIFACTS](../results/05-compiler-artifacts.md) selects compiler-owned persistent
  lint data plus a package-owned Lake facet, with exact-path, invalidation, corruption, cache,
  differential, resource, and independent-audit evidence.
- [ECV2-DESIGN](../results/06-design.md) selects one private Lake-owned intent-to-report operation,
  process-isolated per-module extraction, exact target-toolchain fallback, and measured private task
  concurrency while rejecting the experimental unsafe batch lifecycle as production architecture.
- [ECV2-CHECK](../results/07-check.md) implements the private exact `check` transaction, stable
  text/JSON reports, complete failure aggregation, direct target-toolchain discovery, and bounded
  fresh-frontend fallback without source writes.
- [ECV2-CACHE](../results/08-cache.md) adds a strategy-independent semantic cache capability with
  complete Lake epoch validation, atomic entries, corruption-as-miss behavior, an early all-hit
  return, and measured full-mathlib epoch plus genuine representative warm evidence.
- [ECV2-MODES](../results/09-modes.md) adds the complete batch product surface over one canonical
  result, with strict rule projection and a conflict-, validation-, staleness-, and
  permission-safe per-file write transaction.

## Verification convention

A claim becomes verified only after its prompt checks pass and meaningful command output is recorded.
State is coordination metadata, not evidence. Missing, stale, or unreproduced checks reopen a claim.
Optimization uses the frozen sample and targeted stress files; complete mathlib runs are reserved for
plausible release candidates and are reused by digest during the final audit.
