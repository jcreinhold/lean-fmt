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
