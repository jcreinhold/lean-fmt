---
kind: roadmap
topic: "Native Lean lean-fmt execution core"
main_results: [ECV2-CHECK, ECV2-SCALE, ECV2-FINAL]
prereq_stacks: []
blueprint_tracked: false
---

# Native Lean Execution Core Roadmap

## Goal

Build `lean-fmt` from the `lake init` foundation as a native Lean application. Pure Lean is the
presumption. Another language is admissible only for a named capability or measured end-to-end gain
not currently available in Lean.

The primary performance goal is a cache-cold `lean-fmt check` over an already ordinarily built
mathlib checkout in under ten minutes. This is a goal, not permission to weaken exactness or memory
safety: the stack records and retains every meaningful improvement even if a current Lean limitation
prevents reaching it. Formatter-integrated builds should be faster still, and a valid result-cache
hit should avoid frontend construction entirely.

## Workload vocabulary

- **Ordinary built:** for every selected source, all modules required by its exact Lake setup/header
  have current normal `.olean`/`.ilean` artifacts; no lean-fmt compiler artifact is assumed. The
  selected source need not itself have an output artifact. Prerequisite target builds are measured
  and reported separately from formatter-cache-cold execution.
- **Formatter-integrated built:** the exact compilation ran the lean-fmt plugin and produced trusted
  sidecars.
- **Formatter-cache cold:** no reusable lean-fmt result-cache entry exists. This says nothing by
  itself about ordinary or formatter-integrated build artifacts.
- **Formatter-cache warm:** every selected source has a valid semantic result entry.

Reports and performance evidence must name both build state and cache state. Prerequisite project
compilation is timed separately and is never hidden inside a “cold check” claim.

## Evidence policy

Development does not repeatedly execute the full mathlib workload. Correctness uses focused fixtures
and fresh-frontend differential cases; optimization uses the frozen representative sample plus named
worst-case files; resource work uses targeted retention and failure tests. A run stops as soon as its
measurements decisively reject the hypothesis being tested. Linear projections are planning evidence,
not full-workload measurements, and must name their sampling limitations.

A complete 8,795-file run is a late acceptance check for a release candidate whose sampled evidence
already makes the relevant target plausible. Its purpose is to find long-tail failures, omissions, and
late memory growth that samples cannot exclude. It is not repeated merely to establish a known-slow
baseline, and it is not rerun after documentation-only changes. Raw evidence records the exact binary
digest so an unchanged candidate's completed acceptance run can be reused by the final audit.

## Governing semantics

Each source is interpreted under its exact ordered header, search-path precedence, toolchain and
options, and sequential file-local syntax effects. Fresh full frontend execution is the differential
oracle. Full elaboration is an explicit validation level, not automatically the formatter workload.
Union or accumulated grammar is not exact merely because it parses successfully.

Rust does not own project discovery, caching, edits, or scheduling by default. Lean already provides
Lake APIs, process supervision, allocator limits, compiler plugins, command/module linters, syntax,
and validation. If portable OS RSS enforcement or toolchain bootstrap ultimately needs a non-Lean
shim, it must remain smaller than the capability it supplies and must not become the application
architecture.

## Design direction

Three measured evidence sources feed one private application operation:

1. current ordinary module outputs, used as successful exact-compilation evidence for rules whose
   declared input is only immutable source bytes;
2. compact module-owned results produced while the exact frontend already owns the environment; and
3. a fresh exact-context frontend fallback for stale, missing, standalone, broken, or otherwise
   unsupported evidence.

An ordinary `.olean` is validation evidence, not a serialized syntax projection. Syntax-dependent
rules require the formatter-integrated artifact or the fresh frontend. Existing `.ilean` data,
module-owned persistent `.olean` data, and the package-owned Lake facet remain compiler evidence;
custom sidecar identity is not rebuilt outside the module/build system.

All produce the same semantic result and cache identity. The CLI owns user intent and rendering;
private deep modules own workspace discovery, source snapshots, artifact/cache validation, exact
fallback, resource enforcement, deterministic collection, conflict checks, validation, and writes.
Callers never select worker count, pinning, import reuse, or artifact strategy.

Default project selection covers every root-relative `.lean` source outside `.lake`, not only Lake
library modules. One private source-target capability hides whether Lake supplies a buildable module
or standalone-file setup and guarantees exactly one deterministic result for each selected source.

## Work order

1. Preserve the failed Rust attempt and replace production with the native Lean foundation.
2. Freeze exact semantics and the four workload states.
3. Optimize the ordinarily built cold path and identify the smallest upstream Lean facility if
   exact shared import/parser state is unavailable.
4. Build the compiler-integrated module-artifact path independently, using Lean/Lake's ownership of
   module success and dependency traces rather than post-hoc promotion.
5. Design the production modules twice from those measurements.
6. Implement check, then semantic result caching, modes and conservative edits.
7. Optimize and accept all mathlib workload states under the resource envelope.
8. Add editor service only after batch acceptance, then audit from fresh evidence.

## Completion contract

- The active implementation is a native Lean package/executable named `lean-fmt`, with library
  modules under `LeanFmt`; no Rust workspace or legacy worker code remains.
- Reports are exact, deterministic, path-sorted, and complete.
- Ordinary-built cold mathlib performance is driven toward sub-ten-minute execution and reported
  honestly with its best achieved measurement and any upstream blocker.
- Formatter-integrated cache-cold mathlib completes under ten minutes; cache-warm completes under
  30 seconds without constructing a frontend environment.
- Every run described as full-mathlib acceptance covers 8,795 files and stays within aggregate RSS
  ≤8 GiB, normal macOS pressure, and ≤256 MiB new swap. Sampled and deliberately stopped diagnostic
  runs are labeled as such and never presented as acceptance.
- Check, format, and diff never write. Fix writes only conflict-free output validated under the exact
  semantic identity that produced its edits.
- Compiler artifacts and result-cache entries are atomic, soundly identified, and ordinary misses
  when absent, stale, corrupt, or untrusted.
- Editor service reuses the same semantic primitive and does not create a second orchestrator.

## Blueprint

This is genuine repository maintenance with no mathematical declarations or source-facing theorem
claims. Therefore this roadmap alone sets `blueprint_tracked: false`.

## References

- `notes/02-architecture-pause.md` and `experiments/pure-lean-core/RESULT.md`.
- *A Philosophy of Software Design*: complexity, deep modules, information hiding, different-layer
  abstraction, pulling complexity downward, combining/separating, defining errors away, designing
  twice, comments-first interfaces, modifying existing code, and performance design.
- The `deep-module-design` and `optimizing-lean-performance` skills.

## Stop rules

- Never trade exact context, selected files, validation, or the 8 GiB envelope for timing.
- Never call formatter-integrated artifacts ordinary project build artifacts.
- Do not restore the archived Rust decomposition by accretion.
- Optimizations without meaningful end-to-end improvement are removed unless they simplify design.
