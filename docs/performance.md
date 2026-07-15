# Performance and resource acceptance

The execution core is under measurement-led reconstruction. The previous architecture's fleet and
project-wide import-union claims are retired: a mathlib-scale attempt reached roughly 60 GiB RSS,
and a broader grammar is not semantically equivalent to a file's exact imports merely because it
parses successfully.

## Current operating model

- Start with one Lean worker process and `LEAN_NUM_THREADS=1`.
- Treat `--max-memory` as an aggregate parent-plus-child envelope, not a worker-count heuristic.
- Preserve each file's exact ordered header/import context, search-path precedence, toolchain, and
  options. Reuse is valid only for an identical semantic context.
- Stop the run cleanly if the complete process tree reaches the envelope. Do not retry a file above
  the envelope.
- Add no concurrency control to the public CLI. Exactly two isolated sessions may become a private
  optimization only if release measurements show at least a 20% end-to-end improvement within the
  same aggregate envelope.

## Acceptance workload

The target workload is a release-mode, cache-disabled check of the recorded mathlib checkout using
its exact Lean toolchain and prebuilt oleans. On the current machine, each of three trials must:

- finish in under ten minutes;
- keep sampled aggregate parent-plus-child RSS at or below 8 GiB;
- keep macOS memory pressure normal and new swap at or below 256 MiB; and
- report every selected file without a child abort or silent omission.

A subsequent all-hit run must finish in under 30 seconds without starting a Lean-linked worker.
These remain targets, not measured claims, until raw evidence is recorded under
[`docs/projects/execution-core-v2/evidence`](projects/execution-core-v2/evidence/README.md).

## Measurement discipline

Every performance record names the workload, build profile, cache state, machine, toolchain,
repository commits, wall time, peak aggregate RSS, memory pressure, swap delta, and worker restarts.
The persistent profiler will separate discovery, startup, header processing, imports, parsing,
selective command processing, Rust rules, validation, protocol time, and rendering. An optimization
without meaningful end-to-end improvement is removed unless it independently simplifies the design.
