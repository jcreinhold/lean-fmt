# ECV2-WORKLOADS result

Status: verified on 2026-07-15.

## Changes

- Froze the exact-context, analysis/validation, projection, determinism, and workload contracts in
  `notes/03-semantics-and-workloads.md`.
- Added a revision-, toolchain-, count-, and digest-checked mathlib selector plus the fixed 62-file
  manifest.
- Added a generic process-group profiler with explicit project build/cache states, 8 GiB RSS and
  256 MiB swap-growth stops, a live macOS pressure-level stop, raw streams, phase extraction, and
  output digesting.
- Added a distinct setup-aware oracle mode: it obtains Lake's per-file `ModuleSetup` and passes it
  to a fresh target-toolchain Lean frontend. Setup-free probes remain labeled lower bounds.
- Removed the pure-Lean import probe's stale dependency on the deleted Rust-era frontend source.
  The failed first reproduction is retained as raw evidence rather than treated as a measurement.
- Corrected “ordinary built” to mean that every artifact required by each selected file's exact
  setup/header is current. A selected source does not need its own output, and prerequisite target
  compilation is reported separately from formatter timing.

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
| Setup-free full frontend feasibility, `Mathlib/Tactic.lean` | 1 | 6,521 ms | 9,171 ms | 3,270,208 KiB | 0 KiB | 83% free before/after | `c07b6a89…c195` |
| Fresh setup-free header imports, uniform sample | 62 | 50,391 ms sum; 812.8 ms mean | 56,413 ms | 2,912,416 KiB | 0 KiB | 82% free before/after | `3b020e40…674` |

The successful raw records are under `experiments/results/` with timestamps
`20260715T201811Z` and `20260715T201925Z`. The second result reproduces the prior 667 ms/file import
lower bound at 812.8 ms/file under current machine state. Both measurements imply that even the
setup-free per-file import path is far outside a ten-minute full-mathlib target without an
unavailable amount of safe parallelism.

The initial harness correctly selected the target toolchain/search path but did not consume Lake's
per-file `ModuleSetup`; those two rows are therefore frontend feasibility/lower-bound evidence, not
the exact project differential oracle. After this distinction was found during ECV2-BUILT-COLD,
the setup-aware oracle was run from fresh processes:

| Setup-aware oracle | Wall | Peak RSS | Swap delta | Result |
| --- | ---: | ---: | ---: | --- |
| `Mathlib/Tactic.lean` | 7,064 ms | 1,989,008 KiB | 0 KiB | clean |
| `Mathlib/Data/Finset/Attr.lean` (custom Aesop syntax) | 1,650 ms | 1,026,400 KiB | 0 KiB | clean |

The correction narrows the old measurement claim without changing the semantic contract or the
import-only lower-bound conclusion. Future differential evidence must use `oracle` mode or prove an
equivalent `ModuleSetup` path.

## Verification

- The generated sample has 62 paths and the frozen SHA-256.
- The full selector observes exactly 8,795 non-`.lake` Lean files.
- Both successful profiles completed without a hard stop, RSS breach, observed pressure excursion,
  or swap growth. Subsequent profiles sample `kern.memorystatus_vm_pressure_level` during the run
  and stop above the normal level (`1`), in addition to recording the human-readable before/after
  pressure estimate.
- Setup-aware fresh oracle runs pass for a heavy import barrel and imported custom command syntax.
- `lake build` succeeds for production and the self-contained pure-Lean experiment.
- The stack structural checker and generated-next checker pass after state advancement.

## Remaining uncertainty

This prompt defines the oracle but does not prove a selective analyzer exact; prompt 04 must perform
that differential work. Live pressure enforcement currently uses the macOS memorystatus API; a
portable equivalent remains a lower-layer gap. Generating Lake setup once per file is exact but not
yet an optimized discovery path. No production module or execution strategy was selected here.
