# Prompt 11 service-contract repair

Date: 2026-07-16

## Classification

The original prompt was under-scoped. It requested NDJSON, bounded FIFO, stale versions, health,
shutdown, malformed recovery, and a shared semantic primitive, but did not define wire messages,
version transitions, queue capacity/backpressure, unsaved-source authority, input limits, stable
errors, failure continuation, or a differential/resource test matrix. Its `busy` check implied an
unspecified concurrent reader despite the requirement that one exact analysis not be concurrently
mutated.

## Repair

The repaired prompt defines the `lean-fmt.service.v1` requests and responses, a strictly increasing
per-path version rule, a capacity-one read/process/flush loop, fixed line/source bounds, exact child
isolation, non-writing/non-caching service behavior, and focused integration/resource gates. It first
extracts one bracketed exact snapshot-analysis capability used by both batch fallback and editor
analysis. Ordinary module evidence, compiler artifacts, and persistent cache hits are explicitly
invalid for replacement editor bytes.

The design removes the ambiguous `busy` state. Pipelined requests are tested for FIFO output and
receive stream backpressure; no concurrent reader or queue exists in the application.

## Readiness evidence

- `Application.exactFallback` already owns exact `ModuleSetup`, target-toolchain child spawning,
  `LEAN_NUM_THREADS=1`, process-group RSS sampling, allocator limit, and canonical projection, but its
  temporary paths and indices are currently threaded through batch helpers. A bracketed capability is
  a local extraction, not a missing compiler facility.
- `Project.Snapshot` already retains the exact workspace and every selected immutable source target;
  service startup can reuse it and select existing project paths without reevaluating Lake per line.
- `SemanticAnalysis` is strategy-independent and the batch `check` report projection is already
  deterministic.
- Lean's stdin/stdout streams support sequential line framing and explicit flush; no additional
  language or concurrency facility is required.

No production source or completion status changed during this repair.
