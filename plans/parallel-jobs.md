# Parallel exact frontend children (`--jobs N`)

## Context

Prompt 26 measured cold batch runs: `exact_child` is **95.4%** of wall, `child_analyze` (Lean's own
frontend inside the child) 91.3%; renderer/report are below counter resolution. Children are serial
(`cache.active_children=1`) by deliberate design: the 8 GiB `--max-memory` envelope is *aggregate*
(parent RSS + child process-group RSS), and one child per file gives clean attribution and
kill-ability. The one real speed lever left is bounded parallelism with honestly subdivided budgets.

Research findings that shape the design:

- Lean 4 idiom for blocking I/O tasks is `IO.asTask ... Task.Priority.dedicated` (dedicated threads
  outside the fixed-size pool) — used by `IO.Process.output` itself (`Init/System/IO.lean:1553`) and
  BVDecide's external prover runner (`Lean/Meta/Tactic/BVDecide/External.lean:101`).
- Lake's `Job.collectArray` discipline: fan results back in **input order**, never completion order.
- `Std.Sync` ships `BaseMutex`, `Semaphore`, `CancellationToken`.
- In-repo negative evidence: `Application.lean:392` — "the two-child one-thread prototype
  pipe-blocked"; the fix for that failure mode (dedicated pipe-drain tasks) is the pattern
  `runBounded` already uses.

## Design (two compared; A chosen)

**A — N worker tasks + one reaper, single kill authority (chosen).** Workers pull target indices
atomically and run the *existing* per-file body unchanged; every child spawn registers
`(pgid, share, reason-ref, peak-ref)`; one dedicated reaper task does one `ps` scan per 50 ms over
the parent plus all registered groups and enforces. **B — per-child monitors over a shared sampler
(rejected)**: keeps `monitorChild`'s shape but distributes kill authority across N tasks that must
coordinate on the aggregate trip — strictly more synchronization for the same invariant.

### Invariants

1. **Output is independent of `--jobs`**: results are assembled by target index (never completion
   order); report bytes, statuses, and digests are identical at any N. Gated by a byte-compare test.
2. **Envelope honesty**: each child is told `budget = (maxBytes − parentRSS_at_spawn) / N` (extends
   26's `childMemoryBudget`), so Σ budgets + parentRSS₀ ≤ maxBytes by construction. The reaper
   enforces per-group share (RSS, which includes mmap'd oleans the child's own `setMaxMemory` does
   not) and the aggregate as backstop.
3. **Attribution preserved**: a reaper-killed child fails its file with the same
   `resource envelope exhausted during exact frontend child (X KiB > Y KiB)` shape; batch continues.
4. **`--jobs 1` ≡ today, bit-for-bit**: inline worker, `runBounded`/`monitorChild`, no reaper task,
   `cache.active_children=1` per admission; §1d gate untouched.

### Semantics at N > 1

- Reaper kills a group whose RSS exceeds its share → that file fails (envelope), batch continues.
- Aggregate breach (parent grew past its spawn-time sample) → kill the largest group, attribute,
  continue. Parent alone over the envelope → kill all; subsequent files fail at the pre-spawn check
  (same degrade as serial).
- Static shares: a finished child's headroom is not reallocated (`setMaxMemory` is fixed at child
  start). Documented tradeoff: at 8 GiB, N=2 gives ~3.5 GiB shares — the twelve import-heavy
  mathlib modules that need >6 GiB will refuse. This is why `--jobs` is opt-in, default 1.
- Cancellation (`Std.CancellationToken`) plumbed as today; batch passes `none` today, LSP/stream
  stay on the serial path (`jobs = 1`).
- Profile channel (`phase.*`/`cache.*` stderr lines) is serialized with a `BaseMutex` so concurrent
  workers cannot interleave bytes inside a line the gates parse. Off by default → zero cost.
- `cache.active_children=<live>` is emitted per admission; at N=1 every line is `1` (unchanged).

## Files to modify

- `LeanFmt/Application.lean` — `LiveChild`/`ReaperState`/`reaperLoop`/`pollChild`/
  `ExactRun.spawnBounded`; `ExactRun` gains `jobs`, `reaper?`; `withExactRun` gains `jobs := 1`;
  `childMemoryBudget` gains `workers := 1`; the two batch spawn sites (`envelope`,
  `artifactEnvelope`) swap `runBounded` → `spawnBounded`; the `execute` batch loop becomes
  worker-driven with by-index outcomes; `processOneTarget` extracted verbatim from the loop body.
  `inspectCompilerArtifact` keeps `runBounded` (separate serial command).
- `LeanFmt/Cli.lean` — parse `--jobs N` (run-command loop), validation, `--help` line.
- `LeanFmt/Profile.lean` — `BaseMutex`-serialized `emit`.
- `tests/check/run.sh` — budget-share gate (`--jobs 2` ⇒ `0 < budget ≤ 4 GiB` via the argv
  recorder) + serial-vs-parallel byte-identical stdout gate (real analyzer, 3 fixtures).
- `tests/performance/gates.sh` — `gate_parallel_children` (count, observed-max == jobs, no
  admission > jobs).
- `tests/performance/run.sh` — §1f: sleeping fake analyzer at `--jobs 2`, 2 files → deterministic
  overlap.
- `tests/performance/negative.sh` — §1f negatives (a third child rejected; no-observed-concurrency
  rejected).
- `README.md` — flag line + short paragraph: output identical at any N; budgets divide; when N>1
  helps.

## Reuse

- `runBounded`/`monitorChild` (serial path, unchanged; also keeps `inspectCompilerArtifact`).
- `residentKiB`/`processGroupRssKiB` (reaper folds both into one `ps -axo pid=,pgid=,rss=` scan).
- `childMemoryBudget` (26's honest-headroom helper; gains the divisor).
- `ExactRun.nextPathIndex` pattern (atomic index pull) for the worker queue.
- `awaitRead`, `cancellationMessage`, the existing pre-spawn envelope check.
- Existing recorder/sleeper fake-analyzer test pattern (`tests/check/run.sh:172`).

## Steps

- [ ] Profile.lean mutex + emit
- [ ] Application.lean scheduler (reaper, spawnBounded, ExactRun fields, withExactRun)
- [ ] Application.lean batch driver (processOneTarget extraction, by-index outcomes, workers)
- [ ] Cli.lean `--jobs` + help; RunRequest.jobs; execute plumbing
- [ ] `lake build`, fix errors
- [ ] Gates: tests/check (share + byte-identical), tests/performance §1f + negative.sh
- [ ] Suites: check, performance, stream, modes, lsp (+ acceptance), cache, compiler, watch; then
      full 36-suite sweep; `lake lint`; `lake exe lean-fmt-tests`
- [ ] README
- [ ] Measure: self-project 40-file cold `format --check` at jobs 1/2/4 under `profile-run.sh`
      (counts + digest identical; wall; peak RSS; refusals), record evidence note
- [ ] Commit with explicit pathspecs

## Verification

- New gates pass and their negatives reject (proven by construction in negative.sh).
- §1d serial gate passes unmodified (N=1 ≡ today).
- Full suite sweep green; lint 0 findings.
- Measurement: identical counts/digests at 1/2/4; wall reduction reported honestly; refusals at
  small shares documented.
- Memory stop rules honored: all measurement runs under `profile-run.sh` guard, aggregate ≤ 8 GiB.
