# Intermittent test failures

**Audience: lean-fmt maintainers.** This is about lean-fmt's own CI, not a consuming project's.
For running lean-fmt in your CI, see `docs/ci.md`.

## Do not retry an unfiled failure

Re-running a failed job is legitimate only for a signature already in the ledger below. A retry on
an unfiled signature trades a bug report for a coin flip, because the evidence lives on a runner
that no longer exists.

Every failure digest is built to be one cycle from a cause: heartbeats name the suite, indented
followers carry the assertion's evidence, and the cache suite's forensics name the component that
moved. File the signature with its run ID and digest first. Retry second, if the ledger says it is
safe to.

## The ledger

Worst first. A signature leaves this table by being root-caused and fixed, never by going quiet on
its own.

| Signature | First seen | Runs since | Status |
| --- | --- | --- | --- |
| `scale` fails at exactly 33 s; the digest was lost when the runner died | CI run 30663155905 | 6+ green runs | **open** — the raised caps exist so the next recurrence carries the 48-line follower digest |
| Part 3/3 stalls after `layout` passes: `syntax` and `check` start, then roughly 18 minutes of silence until the 20-minute step timeout | CI runs 30702577635, 30704463051, 30724311657 | 3, identical each time | **partly fixed** — both suites wedged for over 1000 s behind unbounded child waits: `runProc` defaulted to no timeout and neither suite passed one, so a wedged `lean-fmt` child hung its suite forever. `runProc` and `expectExit` now kill children after 10 minutes and name the command. The next wedge is a named suite failure rather than a step timeout. Why the child wedges is still unknown |
| `scale` fails `child-pool-starvation` on the release workflow's `macos-14` leg: `process did not finish within 600000ms and was killed: lake -d <tmp>/pool build Probe` | Release runs 31074344598, 31105098131, 31242415568 | 3, identical each time | **fixed** — the killed command was the case's *fixture setup*, not the arm under test, and it deadlocked for the very reason the case exists. `lean` sizes its task pool from `--threads`, defaulting to the machine's core count with no floor; the fixture's two-level `TacticM.parFirst` nest wedges at 1, 2 and 3 threads and finishes in about a second at 4. Measured directly on both 4.33.0-rc1 and rc2, so the toolchain bump the timeline pointed at was a red herring. `macos-14` is the only leg in the matrix with fewer than four cores and the only one that failed; `LEAN_NUM_THREADS` is not this knob, which is why CI's `LEAN_NUM_THREADS=2` never reproduced it and why peak RSS was normal on every failing run. The fixture's lakefile now pins `moreLeanArgs := #["--threads=4"]`, the same floor `Application.childThreads` applies for the same measured reason, and the setup build carries a two-minute bound. Why the leg passed on 2026-08-05 and never since is unexplained — most likely the runner image's core count, which the logs did not record; the release workflow now prints it |
| `watch` fails `mtime-granularity`: `same-size rewrites stayed indistinguishable for two seconds; the adapter assumes sub-second granularity` | Release runs 30671070537, 31105098131, 31242415568 | 2 of the last 3 release runs; `ubuntu-22.04-arm` and both macOS legs pass | **fixed** — a probe of the runner's filesystem, not of lean-fmt, and it demanded more than the design claims. It wrote two same-size files back to back and required different stamps; file timestamps come from a clock the kernel advances on a tick, so a pair inside one tick collides by construction. The backoff added in 30671070537 delayed the *pairs*, never the two writes within one, so it re-rolled where the pair landed in the tick instead of separating the writes — which is why it never helped. `LeanFmt/Watch.lean` already said coarse granularity bounds latency and never correctness. The case now widens the gap between the two writes until the stamps differ, prints what it took, and fails only if a same-size rewrite is still invisible half a second later |
| `incremental` runs out of memory on constrained machines | CI run 30665759922 | resolved | **fixed** — the peak was never the session. Per-case RSS samples showed session edits flat while the suite's own in-process one-shot oracles stacked import environments, giving a 2.5–11 GB coin flip at any thread count. The oracle now runs in child processes, whose exit releases memory deterministically, and the fixture imports a targeted closure instead of all of `Lean`. Peak is a stable 2.5 GB, and the suite gates it against a `--peak-only` baseline child at a 1.5× thread ratio |

## Check the environment before blaming a test

Each suite part streams memory and disk headroom (TELEM lines) every 15 seconds. The last sample
before a kill usually names the resource. Only `ci.yml` emits them, and only on Linux — `free -m`
has no macOS equivalent — so a failure on any other workflow arrives with no headroom record at all.

The fixes that pattern produced are load-bearing; removing any of them brings the whole class back:

- `lake test -- --jobs 2` and `LEAN_NUM_THREADS=2` on CI. `--jobs` is the test runner's own flag,
  passed through `--`; `lake` has no such option, and a run that omits it takes the runner's default
  of four concurrent suites
- per-step timeouts
- the search-path scrub in the test spawn layer
