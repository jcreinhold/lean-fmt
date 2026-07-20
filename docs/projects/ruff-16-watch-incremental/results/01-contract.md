# RWI-SPEC — watch generations and Git changed-file selection

Claim: **RWI-SPEC** — define event coalescing, generation identity, configuration/Lake change
invalidation, output framing, signal handling, Git comparison modes, rename behavior, and failure
recovery.

Freeze: `notes/01-watch-generations.md`. Baseline: `evidence/01-watch-baseline.md`.

Per the `*-SPEC` convention (`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC, `ruff-13` RCD-SPEC, `ruff-14`
RSF-SPEC, `ruff-15` RRF-SPEC), no production Lean interface, config key, or CLI surface shipped. What
shipped besides documentation is one characterization suite, `tests/watch/run.sh`.

## Commands

```sh
LEAN_NUM_THREADS=1 lake build
lake exe lean-fmt-tests
tests/boundary/run.sh
tests/watch/run.sh
git diff --check
uv run --with pyyaml .claude/skills/lean-plan/scripts/check_stack.py <workspace> --structural  # from kan-proofs
uv run --with pyyaml .claude/skills/lean-plan/scripts/write_next.py <workspace> --check        # from kan-proofs
```

Baseline measurement commands (raw output in `evidence`):

```sh
app=.lake/build/bin/lean-fmt
/usr/bin/time -p "$app" check --root . LeanFmt/Comments.lean
/usr/bin/time -p "$app" check --root .
LEAN_FMT_PROFILE_PHASES=1 "$app" check --root . 2>&1 | grep '^phase\.'
```

Platform probes were run with `lean --run` from the session scratchpad and are reproduced inline in
`evidence` §1, §2, §4; the git fixtures in `evidence` §5–§8 are reproduced by `tests/watch/run.sh`.

## Results read

| Check | Result |
| --- | --- |
| `lake build` | `Build completed successfully (44 jobs)` |
| `lean-fmt-tests` | `lean-fmt module-artifact tests passed` |
| `tests/boundary/run.sh` | `lean-fmt native module and dependency boundary passed` |
| `tests/watch/run.sh` | `lean-fmt watch/git selection characterization passed` |
| `git diff --check` | no output, exit 0 |
| structural checker | `OK: 3 prompt(s), 0 warning(s), no errors.` |
| `write_next.py --check` | `OK: state/next.md matches first_unresolved='02-implementation'` |

Environment: commit `77a1b62`, `leanprover/lean4:v4.33.0-rc1`, Darwin arm64, APFS,
`git version 2.50.1`. No memory figure is recorded — this prompt ships no production code and runs no
resource experiment; `RWI-FINAL` owns retention and RSS measurement.

## What the baseline established

1. **Lean binds no filesystem-watch handle, so watch mode polls.** `Std.Internal.UV` binds Signal,
   Timer, TCP, UDP, DNS and System, and not `uv_fs_event`/`uv_fs_poll`; no `inotify`/`FSEvents`/
   `kqueue` appears in `Init/` or `Std/`. The gap is a missing binding, not a missing platform
   capability, so no amount of `Std.Async` reaches it. An external watcher was considered and rejected
   under `CLAUDE.md`'s "measured benefit" rule — there is no measurement to cite, and by finding 3 the
   available headroom is small (`notes` §1).

2. **`mtime` nanoseconds are populated, so `(size, mtime)` is a sufficient change signal.** Twelve
   writes inside one wall-clock second produced twelve distinct `nsec` values 50–120 µs apart, and a
   same-size rewrite stayed distinguishable. No content digest is needed for *detection* (`notes` §2).

3. **Fixed per-run cost dominates; file count barely matters warm.** `workspace_load` (301–344 ms),
   `discovery` (~34 ms) and `cache_epoch` (61 ms) total ~400 ms and are independent of how many files
   were selected. Going from 1 file to the complete 110-file project adds ~70 ms warm; wall time is
   0.44 s against 0.59 s. Cold result cache for the same 110 files is 64.98 s, a 110× ratio.

4. **`git diff` never reports untracked files**, and only `-z` yields byte-exact paths: default output
   C-quotes non-ASCII, and `core.quotePath=false` fixes that case while still quoting an embedded
   double quote.

5. **Three-dot is the merge-base question.** On a diverged fixture, `main..feature` reported ten paths
   including a deletion the branch never performed; `main...feature` reported exactly the two files
   the branch touched.

6. **Two spawn-path traps.** `IO.Process.output` returns `exitCode = 255` for a missing binary rather
   than throwing, so a `try`/`catch` implementation of "Git absence is an error" never fires. And
   `git rev-parse --show-toplevel` exits 128 with one clean stderr line outside a repository, where
   `git diff --name-status HEAD` exits 129 after dumping ~90 lines of option usage.

## Decisions changed during execution

Two of these reversed the design I expected to write.

- **Watch does not select only changed files.** I began expecting an incremental changed-file path
  into `execute` and abandoned it on finding 3. The saving is ~70 ms of a ~590 ms generation (~12%),
  and it is bought by giving up the completeness guarantee the stack's stop rule exists to protect.
  The aggregate result cache already supplies incrementality, per file and keyed on content, which is
  both finer and safer than anything a watch loop could infer from `mtime`. So every generation runs
  the complete project through the ordinary `execute`, and the roadmap's "no second execution engine"
  turns out to require no work at all rather than careful restraint (`notes` §4).

- **Clean shutdown needs no signal handler.** `Std.Async.Signal` does bind `sigint`/`sigterm` and
  composes with `Timer.Interval` through `Selector`, so the handler is implementable. But every write
  in the product is already atomic temp-then-rename, so default signal disposition cannot leave a torn
  file or a half-written report — the temporary is merely orphaned. Adopting `Std.Async` would
  introduce a libuv event loop into a tree that uses none today, alongside the existing bounded-child
  spawning, to buy a friendlier message. Frozen as optional, with obligations if taken (`notes` §8).

- **Coalescing needs no queue.** Holding "snapshot last run on" and "snapshot last observed" makes an
  event storm collapse by construction: ten edits during one generation differ from the run snapshot
  exactly once and produce exactly one following generation. The roadmap's bounded-queue requirement
  is met with no bound to tune, no drop policy, and no backpressure rule (`notes` §5).

- **Watch admits only non-writing modes.** A writing mode under watch changes the `mtime` tuples the
  poll observes, retriggering itself — self-sustaining by construction, not a race. `--watch` is
  accepted for `check`, `diff` and `format --check`, rejected for `format` and `fix` (`notes` §10).

- **Document formats require `--output-file` in watch mode.** Resolving the framing question the
  `ruff-15` handoff left open, per format rather than once. `text`/`concise`/`github` append with a
  stderr generation banner; `json`/`sarif`/`junit` emit one complete document per generation,
  replacing the previous, and are rejected on stdout because concatenating them produces something no
  parser accepts. `writeReportFile` is already atomic, which `ruff-15` established as safe for exactly
  this polling consumer (`notes` §7).

- **Workspace retention is permitted, not mandated.** Retaining `Lake.Workspace` would amortize the
  ~300 ms load, plausibly taking a generation from ~590 ms to ~250 ms — but that figure is projected,
  not measured, and retention carries a real invalidation obligation. `RWI-IMPL` may choose; if it
  retains, `notes` §6's invalidation table is mandatory and `RWI-FINAL` must measure whether it paid.

## Files changed

| File | Change |
| --- | --- |
| `docs/projects/ruff-16-watch-incremental/notes/01-watch-generations.md` | new — the frozen contract |
| `docs/projects/ruff-16-watch-incremental/evidence/01-watch-baseline.md` | new — raw measurements |
| `docs/projects/ruff-16-watch-incremental/results/01-contract.md` | new — this note |
| `docs/projects/ruff-16-watch-incremental/state/current.md` | RWI-SPEC verified; first unresolved advanced |
| `docs/projects/ruff-16-watch-incremental/state/next.md` | regenerated |
| `tests/watch/run.sh` | new — characterization suite |
| `CLAUDE.md`, `AGENTS.md` | register `tests/watch/run.sh` in the build list |

## Test design note

`tests/watch/run.sh` characterizes **git and the filesystem**, not `lean-fmt`, because RWI-SPEC ships
no product surface. Every assertion is a premise the RWI-IMPL adapter will be built on, so a future
git that changes one fails loudly here instead of silently corrupting selection.

The suite was mutation-tested rather than merely observed to pass: inverting the rename-target
assertion and the two-dot-noise assertion each produced a failure with the expected diagnostic, and
restoring them returned exit 0.

Two things were deliberately left out. `mapfile -d ''` is the natural NUL-field reader but is a bash 4
builtin and macOS ships bash 3.2, so the suite uses a portable `read -r -d ''` loop. And the
missing-binary case is **not** asserted: it is a fact about Lean's spawn path returning 255, and the
nearest shell equivalent (127 from `env PATH=/nonexistent git`) is a different number from a different
mechanism — asserting it would look like corroboration while testing nothing relevant. That
measurement lives in `evidence` §4 and `RWI-IMPL` covers it against the real adapter.

## Remaining uncertainty

- **Nanosecond `mtime` is Darwin/APFS-measured, not universal.** On a coarse-granularity filesystem a
  same-second same-size edit can produce an identical tuple and be missed by that poll. `notes` §2
  frames the consequence as bounded detection *latency* and never a wrong result, because every
  generation re-reads and re-digests source. `RWI-IMPL` must not describe the poll as guaranteeing
  every edit is observed. Not independently verified on Linux/ext4 or on a network filesystem.

- **The retention gain is projected, not measured.** ~590 ms → ~250 ms assumes `workspace_load` is
  fully amortizable across generations. It may not be: some of that phase could be per-request rather
  than per-workspace. `RWI-FINAL` must measure before any claim is made.

- **The 200 ms poll default is reasoned, not tuned.** It sits above the 34 ms walk and below the
  ~600 ms generation, which is the right shape, but no experiment established that 200 ms beats 100 ms
  or 500 ms on a real editing session. `RWI-FINAL`'s event-storm work is the place to check it.

- **Poll cost at scale is unmeasured.** The 34 ms discovery walk is this 110-file repository. On the
  frozen mathlib sample the walk is larger, and if it approaches the generation cost, `notes` §1's
  rejection of an event-driven watcher should be reopened rather than worked around.

- **Rename detection was on by default in the fixture** — plain `git diff --name-status HEAD` already
  produced `R100`. Whether that holds under every `diff.renames` configuration was not tested;
  `RWI-IMPL` should pass `--find-renames` explicitly rather than depend on the default.
