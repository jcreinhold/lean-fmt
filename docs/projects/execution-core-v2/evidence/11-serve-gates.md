# Prompt 11 editor-service gates

Date: 2026-07-16

Prompt status: verified.

## Protocol and semantic matrix

`tests/service/run.sh` starts the compiled `lean-fmt serve` command and proves:

| Contract | Evidence |
| --- | --- |
| Health | object-valued request ID preserved; schema, ready state, canonical root, and exact toolchain returned |
| Exact equality | on-disk editor source matched an independent batch run with module evidence/artifacts disabled, field-for-field on status, findings, and diagnostics |
| Unsaved semantics | replacement bytes introduced FMT001 while the disk source digest, mtime, and mode remained unchanged |
| FIFO | three pipelined health requests returned in input order |
| Versioning | duplicate version rejected with `stale-version` and latest accepted version before malformed source reached Lean |
| Recovery | malformed JSON, missing fields, unknown method, escaping path, 16 MiB source limit, and 32 MiB line limit each returned one stable error and preserved the process |
| Isolation | `/usr/bin/false` analyzer and one-byte envelope each returned `analysis-failure`; a following health request succeeded |
| Shutdown | acknowledgement emitted, a pipelined later request was not read, and EOF separately exited 0 |
| Writes | neither selected source nor `.lean-fmt-cache` changed |

Unit coverage in `lean-fmt-tests` checks valid health/analyze decoding, object ID preservation,
unknown-method rejection, and first/newer/duplicate/older version transitions.

## Focused resource profile

Profile: `service-100-requests-final-20260716T055529Z` under ignored raw
`experiments/results/`. Machine: `supermartingale.local`, Darwin 25.5.0 arm64. Toolchain:
`leanprover/lean4:v4.32.0`. Fixture manifest:
`experiments/workloads/service-fixture.txt`, two sources, digest
`e5e66b2c194e026e3cc69664dc46d7e33fabb0836215c58316aceb8c7193af57`. Binary digest:
`27f7554ed0e0667f520df6341a940ef7ab3efd4e504b89685863221e9b982b7f`.

The full harness, including builds, protocol errors, 100 sequential 64 KiB unsaved exact snapshots,
failure-recovery services, and EOF service, completed in 44.388 seconds. The in-harness recursive
PPID sampler measured 1,041,472 KiB peak aggregate service-plus-child RSS. The outer process-group
sampler reported 941,472 KiB because each supervised exact child deliberately starts a new process
group; the recursive descendant value is therefore the authoritative aggregate measurement. Parent
RSS median decreased from 800,496 KiB over the first ten exact responses to 723,776 KiB over the last
ten. System pressure stayed at level 1 with 72% free before and after, and swap delta was 0 KiB. The
profile exited 0 with no hard stop.

## Sequential repository gates

These passed after the final implementation:

```text
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
LEAN_NUM_THREADS=1 tests/compiler/run.sh
LEAN_NUM_THREADS=1 tests/check/run.sh
LEAN_NUM_THREADS=1 tests/modes/run.sh
LEAN_NUM_THREADS=1 tests/scale/run.sh
LEAN_NUM_THREADS=1 tests/service/run.sh
module first-command audit over every non-lakefile `.lean` outside `.lake`
git diff --check
```

The final unprofiled service gate independently sampled 1,042,464 KiB aggregate peak over 100
requests and again showed no retained-source trend. Compiler-suite errors for corrupt artifacts and
the deliberately broken module were expected negative cases followed by its success sentinel.

## Deep-module audit

The supplied audit script has no automated Lean backend, so the Lean-pattern audit was performed
manually after a successful full build:

- `Main` calls only `Cli.runCli`; CLI parses service startup intent but owns no protocol state or
  exact-analysis lifecycle.
- `Service` owns framing/version/FIFO policy but no setup, parser, rule, cache, validation, or write
  implementation. It retains only `HashMap String Nat` state.
- `ExactRun` has a private constructor and hides all temporary paths, child arguments, allocator/RSS
  enforcement, unique names, and cleanup. Its callback bracket prevents a close-order protocol.
- Batch and service call the same `ExactRun.analyzeSnapshot`; service adds no parser or semantic
  projection. Batch constructs the capability only after cheaper semantic evidence is exhausted.
- `Project` owns normalization, root containment, selected-source membership, and immutable source
  replacement. The wire layer cannot fabricate a target.
- No public application declaration, public protocol DTO, concurrent queue, session mutation,
  pass-through facade, one-field wrapper, strategy trait, worker/jobs/pinning option, or legacy Rust
  execution name was introduced. Explicit `public` declarations remain executable entry points.
