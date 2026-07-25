# Parallel frontend workers (`--workers N`) — design record and measurement

Post-stack feature (requested after prompt 27 closed the stack). Cold batch runs are 95.4% frontend
child (26); this divides the serial child's wall by admitting N children under the same aggregate
envelope. Design and invariant discussion: `plans/parallel-jobs.md`.

## Semantics

- Each child is told `budget = (maxBytes − parentRSS_at_spawn) / N` (26's `childMemoryBudget` gains
  the divisor); a dedicated reaper task samples parent + every process group in one `ps` scan per
  50 ms, enforces per-group share (RSS counts mmap'd oleans the child's own `setMaxMemory` does
  not) and the aggregate as backstop (kills the largest group). Kill attribution is per file with
  the share it was held to; the batch continues.
- Results are assembled by target index, never completion order.
- `--workers 1` (default) is the pre-feature code path verbatim: `runBounded`/`monitorChild`, no
  reaper, `cache.active_children=1` per admission (§1d gate untouched).

## Measurement (arm64 macOS, 24 GiB, pressure 1, hard_stop=none throughout)

Self-project cold `format --check --json --no-cache --max-memory 8`, frozen 40-file manifest
(`experiments/workloads/lean-fmt-self.txt`), runs in order 1→2→4 (page cache warms; the 1-worker
wall matches 26's 100.8 s shape):

| workers | wall (s) | speedup | peak RSS (MiB) | report vs serial |
|---|---|---|---|---|
| 1 | 108.9 | 1.0× | 3,323 | — |
| 2 | 58.6 | 1.86× | 5,669 | **byte-identical** |
| 4 | 25.8 | 4.2× | 7,322 | 29 files refused by share |

The 4-worker row is the contract working, not a defect: own-source analyses need ~2 GiB RSS and
the quarter shares are ~1.88 GiB, so 29 children were killed by name
(`resource envelope exhausted during exact frontend child (1975776 KiB > 1924580 KiB)` — actual
demand against actual share) and the batch continued. The other 11 files' statuses are identical
to serial. 2 workers (shares ~3.5 GiB) fits this project whole.

## Defects found by this work's own gates, fixed before commit

- **ECHILD double-reap**: `spawnBounded`'s `finally` called `tryWait` on a child `pollChild` had
  already reaped; Lean's `tryWait` does not cache. Every parallel child failed with "no child
  processes". Two gates passed *vacuously* while this was live: the byte-identical gate's fixtures
  were module-evidence-served (no children spawned), and §1f read only admission counts. The
  byte-identical gate now forces real children (`LEAN_FMT_DISABLE_ARTIFACT=1
  LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1`) and its comment records why.
- **Flag collision**: `tests/boundary` pins `--jobs` as a retired legacy-fleet spelling, so the
  flag is `--workers`.

## Gates added (shell suites; port when the Lean-native framework lands)

- `tests/check/run.sh`: budget share (`--workers 2` ⇒ `0 < budget ≤ envelope/2`, argv recorder);
  serial-vs-2-workers byte-identical stdout with forced frontend children.
- `tests/performance/gates.sh` `gate_parallel_children` + §1f (sleeping fake analyzer: admission
  count == files, observed max == workers, none above) + `negative.sh` cases.
- The envelope share/attribution semantics above are covered by measurement, not yet by a
  deterministic suite gate — the port should add one (a tiny `LEAN_FMT_TEST_MAX_BYTES` run at
  `--workers 2` asserts both files fail with the envelope message, exit 2).

## Adjacent finding (not this feature)

The frontend pipeline is quadratic in command count on many-command files: 2.5k/5k/10k/20k trivial
defs measure 10/32/110/435 s while plain `lean` elaboration of the same files is linear
(1.7/7.2 s). Worth a dedicated investigation; real files rarely exceed ~2k commands.
