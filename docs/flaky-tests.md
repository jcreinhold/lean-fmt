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
| `incremental` runs out of memory on constrained machines | CI run 30665759922 | resolved | **fixed** — the peak was never the session. Per-case RSS samples showed session edits flat while the suite's own in-process one-shot oracles stacked import environments, giving a 2.5–11 GB coin flip at any thread count. The oracle now runs in child processes, whose exit releases memory deterministically, and the fixture imports a targeted closure instead of all of `Lean`. Peak is a stable 2.5 GB, and the suite gates it against a `--peak-only` baseline child at a 1.5× thread ratio |

## Check the environment before blaming a test

Each suite part streams memory and disk headroom (TELEM lines) every 15 seconds. The last sample
before a kill usually names the resource.

The fixes that pattern produced are load-bearing; removing any of them brings the whole class back:

- `--jobs 2` and `LEAN_NUM_THREADS=2` on CI
- per-step timeouts
- the search-path scrub in the test spawn layer
