# Prompt 07 exact-check gates

Date: 2026-07-16

## Behavioral matrix

`LEAN_NUM_THREADS=1 tests/check/run.sh` passed with these cases:

| Case | Evidence |
| --- | --- |
| Clean source | exit `0`, stable JSON |
| Formatter finding | exit `1`, exact FMT001 range and edit |
| Compiler artifact versus fresh frontend | byte-identical reports |
| File-local custom syntax | byte-identical reports; projected custom command retained |
| Independent exact frontend versus compiler payload | semantic artifacts equal |
| Malformed header and unresolved import | both path-sorted file results, exit `1` |
| Analyzer abort on two files | both files retained, two aggregated failures, exit `2` |
| Resource exhaustion | clear infrastructure result, exit `2` |
| Corrupt derived sidecar | ordinary miss, recovered report equals trusted path |
| Repeated output | byte-identical |
| Wrong target toolchain | clear version mismatch, exit `2` |
| Source safety | contents and nanosecond mtimes unchanged |

The lower-layer compiler suite additionally exercises source invalidation, rule configuration,
plugin-binary invalidation, corrupt sidecar and `.olean` rejection, exact artifact-path binding,
Lake cache restoration, and failed-elaboration publication.

## Direct-process measurements

Workload: one already-built `tests/check/Clean.lean` module. Build profile: native development build.
Machine: `Darwin supermartingale.local 25.5.0`, arm64. Toolchain: Lean `v4.32.0`. Recorded base
revision: `0fa113286f226266dde4e5af33ffa39c4bcf2a37`; the Prompt 07 worktree was dirty because these
measurements precede its commit. Profiler limits were 8,388,608 KiB RSS, pressure level 1, and
262,144 KiB new swap.

| Path | Command | Wall | Sampled process-tree peak | Pressure | Swap delta | Output |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| compiler sidecar hit | `.lake/build/bin/lean-fmt check --root . --json tests/check/Clean.lean` | 567 ms | 648,272 KiB | 1 | 0 KiB | digest `4f7238…5977` |
| exact fallback | `LEAN_FMT_DISABLE_ARTIFACT=1` plus the same command | 843 ms | 651,344 KiB | 1 | 0 KiB | same digest |

The rejected `lake env` wrapper measured 826 ms and 1,302,640 KiB for the hit, and 1,111 ms and
1,303,056 KiB for fallback. This directly motivated target-root toolchain discovery inside the
application.

A targeted runtime cutoff used a 716,800 KiB test envelope:

```sh
LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_MAX_BYTES=734003200 \
  .lake/build/bin/lean-fmt check --root . --json tests/check/Clean.lean
```

It exited `2` after the internal 50 ms monitor observed 782,896 KiB aggregate parent-plus-child RSS.
The external profile recorded 856 ms wall, 653,424 KiB at its coarser 250 ms sampling interval,
normal pressure, and zero swap growth. The discrepancy is expected: the internal monitor caught the
short-lived child peak that the outer sampler missed.

## Repository gates

The following passed sequentially (the compiler and check scripts intentionally mutate fixture
artifacts and must not run concurrently):

```sh
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
LEAN_NUM_THREADS=1 tests/compiler/run.sh
LEAN_NUM_THREADS=1 tests/check/run.sh
LEAN_NUM_THREADS=1 lake exe lean-fmt -- check --help
git diff --check
```

The module-system gate also checked every non-`lakefile.lean` source and found `module` as its first
nonblank command.
