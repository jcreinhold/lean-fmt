# Prompt 06 native architecture gates

Date: 2026-07-16

## Targeted extraction experiment

```sh
experiments/profile-run.sh \
  --name module-artifact-batch-retention-64 \
  --project-root ~/Code/mathlib4 \
  --build-state ordinary-built-at-entry-probe-prepares-integrated-artifacts \
  --cache-state formatter-cache-cold \
  --sources experiments/workloads/mathlib-v4.32.0-batch-8.txt -- \
  experiments/run-module-artifact-batch.sh ~/Code/mathlib4 \
    experiments/workloads/mathlib-v4.32.0-batch-8.txt 8 8 4
```

The accepted run must name mathlib revision `783ccda4ee524f13cc5636237be0a1942bc04824`, Lean
`v4.32.0`, source digest `b391810cd685d5ce7930d3c6cdab57a15d61c0126b92fee3fc2ec420e61f7270`,
the ordinary-built entry state, and the preparation phase that creates eight temporary
formatter-integrated artifacts. Raw results are ignored under `experiments/results/`.

| Gate | Result |
| --- | --- |
| Eight batch results equal independent exact extraction byte-for-byte | pass |
| Experimental exact-import specialization escapes an imported value | no; callback returns `Unit`, then `Environment.freeRegions` runs in `finally` |
| Lean exposes the specialization as a supported scoped exact-import API | no; production retains process-exit reclamation |
| 64 imports omit or duplicate a request | no; 64/64 item timings and RSS samples recorded |
| First-eight versus last-eight item time | 3,237 ms versus 3,265 ms |
| Batch retained RSS | 92,992 KiB after item 1; plateau/maximum 155,856 KiB |
| Abnormal pressure or swap growth | none; pressure level 1, swap delta 0 KiB |
| Independent total versus unique batch work | 4,437 ms versus 3,237 ms |
| Four-task phase and overlap | 1,660 ms; observed maximum overlap 4 |
| Parent `LEAN_NUM_THREADS` controls the tested task starts | same guarded run: maximum 4 at value 4, maximum 2 at value 2 |
| Two-task control phase | 2,451 ms inside probe; 2,471 ms process wall |
| Guarded aggregate peak | 1,835,728 KiB including preparation and concurrent children |
| Serial path plausibly meets full target | no; latest independent mean projects to 81.3 minutes serial |
| Full mathlib run performed | no; the targeted sequence already answers reclamation and startup questions |

The earlier raw profile labeled its entry build state `formatter-integrated-built` even though its
preparation phase created those artifacts. That metadata is rejected rather than silently reused;
the command above records the corrected entry/transition description.

The accepted record is `module-artifact-design-64-20260716T003256Z.meta`, with output digest
`7fe7e73d5aff5dba49307a51355d3918d1eda74a95b2c8e92613be390da3fb84`. Its stdout explicitly
records `concurrent_configured_threads=4`, `concurrent_max_overlap=4`, then
`concurrent_configured_threads=2`, `concurrent_max_overlap=2`; the control is part of the exact
command above rather than an undocumented terminal rerun.

## Architecture audit checklist

- Common callers know only `RunRequest`, `RunEvent`, `RunReport`, and `RunFailure`: pending Prompt 07
  implementation, interface fixed in the design note.
- No public worker count, facet, cache key, artifact path, environment, retry, or pinning type: pass.
- No single-implementor typeclass, pass-through facade, or temporal lifecycle protocol in production:
  pass.
- Every active package, test, and retained experiment source begins with `module`; Lake configuration
  scripts are configuration rather than compiled modules: pass.
- Production extractor owns exact path binding, disables unrelated extension initialization, and
  uses process exit as its supported reclamation boundary: pass.
- Batch path remains experimental rather than becoming a second application orchestrator: pass.
- Ordinary absence maps to private fallback, and fallback owns target-toolchain re-execution:
  required by the selected contract; implementation gate for Prompt 07.
- Cross-package facet discovery and fetch without target configuration mutation: implementation gate
  for Prompt 07.
- Pre- and post-design independent audits: complete; final re-audit found no P0, P1, or P2 findings.

## Repository gates

```sh
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
tests/compiler/run.sh
LEAN_NUM_THREADS=1 lake -d experiments/module-artifact-batch build artifact-batch-probe
LEAN_NUM_THREADS=1 lake -d experiments/module-artifact-batch build artifact-concurrency-probe
bash -n experiments/run-module-artifact-batch.sh
git diff --check
```
