# ECV2-DESIGN result

Status: verified on 2026-07-16 after the guarded profile, repository gates, and an independent
post-design audit with no P0, P1, or P2 findings.

## Decision

Select one private Lake-owned intent-to-report operation. It owns per-module facet jobs, immediate
descriptor/source validation, exact fallback, bounded scheduling, deterministic aggregation, and
mode-authorized writes. The CLI never receives execution-strategy objects.

Retain independent per-module facets and process-isolated extraction as the production cache/crash
boundary. A serial batch probe showed stable repeated behavior with `loadExts := false` and
`Environment.freeRegions`, but the exact-artifact specialization is private `unsafe` code rather
than a supported scoped Lean API. It saves only repeated startup and remains far too slow serially.
Production retains process-exit reclamation; the manifest protocol stays experimental.

Lake's task primitive bounded observed extractor overlap exactly at parent `LEAN_NUM_THREADS` values
two and four while each child remained at one Lean thread. This supports private, measured task
concurrency, but aggregate process-tree monitoring remains mandatory and the value is not a product
option.

The exact frontend process remains the ordinary-built fallback and must own exact target-toolchain
re-execution. Missing compiler payload is a normal fallback input, not an artifact error. A future
typed direct persistent-extension reader or scoped exact-import wrapper in Lean can replace
transitive import extraction without changing application callers.

## Evidence

See [the architecture note](../notes/06-native-architecture.md) and
[the Prompt 06 gates](../evidence/06-design-gates.md). No full-mathlib run was needed for this design
decision.
