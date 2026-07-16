# ECV2-SERVE result

Status: verified on 2026-07-16.

## Result

`lean-fmt serve` implements a private `lean-fmt.service.v1` NDJSON protocol for health, exact unsaved
analysis, and shutdown. A capacity-one read/process/flush loop provides deterministic FIFO ordering
and stream backpressure. Strictly increasing canonical per-path versions reject stale snapshots
before compiler work; stable protocol and analysis errors recover without terminating the service.

The service does not create a second parser or orchestrator. Batch fallback and editor requests share
one bracketed `Application.ExactRun`, whose private constructor owns exact setup, target-toolchain
children, one-thread policy, aggregate RSS/allocator enforcement, temporary inputs, crash isolation,
and cleanup. Each unsaved request receives a fresh child. Disk-state module evidence, compiler
artifacts, result-cache entries, and all source-writing operations are absent from the service path.

## Verification

The protocol matrix covers differential equality, unsaved findings, FIFO, stale versions, malformed
and oversized recovery, analyzer crash, resource exhaustion, shutdown, EOF, and write absence. A
focused 100-request profile completed in 44.388 seconds at 1,041,472 KiB peak aggregate RSS with
normal pressure, zero swap growth, and decreasing parent RSS. All existing compiler, batch, mode, and
scale suites pass over the extracted primitive.

See [the Prompt 11 evidence](../evidence/11-serve-gates.md) for identities, measurements, commands,
and the deep-module audit.
