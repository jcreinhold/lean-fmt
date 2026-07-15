# Mathlib built-state correction

The fixed selection contains 8,795 non-`.lake` Lean sources. Before prerequisite work on
2026-07-15, 8,275 had a corresponding root-package `.olean` and 520 did not:

| Missing source-output prefix | Count |
| --- | ---: |
| `Archive` plus `Archive.lean` | 86 |
| `Counterexamples` plus `Counterexamples.lean` | 30 |
| `MathlibTest` | 387 |
| `Cache` | 1 |
| `DownstreamTest` | 1 |
| `docs` plus `docs.lean` | 3 |
| `lakefile.lean` | 1 |
| `scripts` | 11 |

The presence of a source output is only a conservative proxy. The actual ordinary-built invariant
is that every module imported by each selected source's exact `ModuleSetup` and header is current.
Standalone scripts need not have their own `.olean`; `Archive` sources that import other `Archive`
modules do require that library's artifacts.

An attempted full setup-free import run encountered seven unresolved `Archive` or
`Counterexamples` prefixes in its first 673 sources and was stopped. It exited 143 after 476,841 ms,
with 6,621,696 KiB peak aggregate RSS, normal pressure, and negative measured swap delta. The run is
retained as failed preflight evidence and is not a performance result.

Prerequisite target builds must run with `LEAN_NUM_THREADS=1` inside the profiler's 8 GiB/256 MiB
envelope. Their wall time is reported separately. A full cold-check timing begins only after exact
setup/import preflight succeeds for all selected files.

After building `Archive`, `Counterexamples`, `MathlibTest`, and `docs`, 8,781 selected sources had a
corresponding root-package `.olean`. The remaining 14 were standalone cache/downstream tests,
lakefiles, or scripts that do not require their own output. The first full no-build setup audit then
identified two actual missing dependencies: `Cli.Basic` and `ImportGraph.Imports.FromSource`.
Building those modules took 4,149 ms wall, peaked at 1,046,832 KiB RSS, stayed at pressure level 1,
and added no swap.

The corrected batched `Lake.setupServerModule` audit succeeded for all 8,795 sources with
`noBuild := true`: 394,199 ms wall, 1,434,896 KiB peak RSS, pressure level 1 throughout, and
−8,192 KiB swap delta. This establishes the frozen ordinary-built premise. It is prerequisite
validation and is not included in formatter-cache-cold execution time.
