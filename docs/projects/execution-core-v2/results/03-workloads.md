# ECV2-WORKLOADS result

Status: verified on 2026-07-15.

## Changes

- Froze the exact-context, analysis/validation, projection, determinism, and workload contracts in
  `notes/03-semantics-and-workloads.md`.
- Added a revision-, toolchain-, count-, and digest-checked mathlib selector plus the fixed 62-file
  manifest.
- Added a generic process-group profiler with explicit project build/cache states, 8 GiB RSS and
  256 MiB swap-growth stops, raw streams, phase extraction, and output digesting.
- Removed the pure-Lean import probe's stale dependency on the deleted Rust-era frontend source.
  The failed first reproduction is retained as raw evidence rather than treated as a measurement.

## Commands and measurements

Both successful runs used mathlib revision
`783ccda4ee524f13cc5636237be0a1942bc04824`, Lean `v4.32.0`,
`LEAN_NUM_THREADS=1`, ordinary project build artifacts, and a cold formatter cache.

```sh
LEAN_NUM_THREADS=1 lake build
(cd experiments/pure-lean-core && LEAN_NUM_THREADS=1 lake build)

experiments/profile-run.sh --name exact-full-tactic \
  --project-root ~/Code/mathlib4 --build-state ordinary-built \
  --cache-state formatter-cache-cold \
  --sources experiments/workloads/mathlib-v4.32.0-tactic.txt -- \
  experiments/run-pure-lean-workload.sh full ~/Code/mathlib4 \
  experiments/workloads/mathlib-v4.32.0-tactic.txt

experiments/profile-run.sh --name exact-import-sample \
  --project-root ~/Code/mathlib4 --build-state ordinary-built \
  --cache-state formatter-cache-cold \
  --sources experiments/workloads/mathlib-v4.32.0-sample.txt -- \
  experiments/run-pure-lean-workload.sh import ~/Code/mathlib4 \
  experiments/workloads/mathlib-v4.32.0-sample.txt
```

| Run | Files | Semantic phase | Wall | Peak RSS | Swap delta | Pressure | Output digest |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| Fresh full frontend, `Mathlib/Tactic.lean` | 1 | 6,521 ms | 9,171 ms | 3,270,208 KiB | 0 KiB | 83% free before/after | `c07b6a89…c195` |
| Fresh exact imports, uniform sample | 62 | 50,391 ms sum; 812.8 ms mean | 56,413 ms | 2,912,416 KiB | 0 KiB | 82% free before/after | `3b020e40…674` |

The successful raw records are under `experiments/results/` with timestamps
`20260715T201811Z` and `20260715T201925Z`. The second result reproduces the prior 667 ms/file import
lower bound at 812.8 ms/file under current machine state. Both measurements imply that fresh exact
per-file imports are far outside a ten-minute full-mathlib target without an unavailable amount of
safe parallelism.

## Verification

- The generated sample has 62 paths and the frozen SHA-256.
- The full selector observes exactly 8,795 non-`.lake` Lean files.
- Both successful profiles completed without a hard stop, RSS breach, pressure excursion, or swap
  growth.
- `lake build` succeeds for production and the self-contained pure-Lean experiment.
- The stack structural checker and generated-next checker pass after state advancement.

## Remaining uncertainty

This prompt defines the oracle but does not prove a selective analyzer exact; prompt 04 must perform
that differential work. The profiler samples pressure before and after and enforces RSS/swap during
the run; a portable live pressure-state API remains a possible lower-layer gap. No production module
or execution strategy was selected here.
