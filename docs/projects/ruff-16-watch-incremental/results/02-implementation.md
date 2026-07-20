# RWI-IMPL — bounded observers over `execute`

Claim: **RWI-IMPL** — add private filesystem and Git selection adapters, bounded coalescing,
generation reporting, graceful shutdown, and focused test hooks while preserving the single semantic
engine.

Implements `notes/01-watch-generations.md`, which this prompt amended in three places (all recorded
below and marked in the freeze itself).

## Commands

```sh
LEAN_NUM_THREADS=1 lake build
lake exe lean-fmt-tests
tests/boundary/run.sh
tests/watch/run.sh
tests/check/run.sh
tests/reporting/run.sh
tests/stream/run.sh
tests/discovery/run.sh
tests/modes/run.sh
git diff --check
uv run --with pyyaml .claude/skills/lean-plan/scripts/check_stack.py <workspace> --structural  # from kan-proofs
uv run --with pyyaml .claude/skills/lean-plan/scripts/write_next.py <workspace> --check        # from kan-proofs
```

## Results read

| Check | Result |
| --- | --- |
| `lake build` | `Build completed successfully (48 jobs)` |
| `lean-fmt-tests` | `lean-fmt module-artifact tests passed` |
| `tests/boundary/run.sh` | `lean-fmt native module and dependency boundary passed` |
| `tests/watch/run.sh` | `lean-fmt watch/git selection characterization passed` |
| `tests/check/run.sh` | `lean-fmt check integration tests passed` |
| `tests/reporting/run.sh` | `lean-fmt reporting format tests passed` |
| `tests/stream/run.sh` | `failures=0` |
| `tests/discovery/run.sh` | `lean-fmt configuration discovery acceptance tests passed` |
| `tests/modes/run.sh` | `lean-fmt product mode integration tests passed` |
| `git diff --check` | no output |
| structural checker | `OK: 3 prompt(s), 0 warning(s), no errors.` |
| `write_next.py --check` | `OK: state/next.md matches first_unresolved='03-acceptance'` |

`tests/check/run.sh` matters beyond its own subject: it holds `ruff-15`'s byte-for-byte JSON
compatibility golden, and its passing is the evidence that this stack did not disturb that frozen
cross-stack contract (see decision 2).

Environment: `leanprover/lean4:v4.33.0-rc1`, Darwin arm64, APFS. No memory figure is recorded here;
`RWI-FINAL` owns the resource envelope.

## What shipped

| File | Change |
| --- | --- |
| `LeanFmt/Watch.lean` | new — private poll observer: stamps, snapshots, coalescing, the loop |
| `LeanFmt/GitSelection.lean` | new — private `-z` changed-file adapter |
| `LeanFmt/Cli.lean` | `--watch`, `--poll-interval`, `--changed`, `--changed-since`, `--staged`; the rejections of §7/§9/§10; provenance notices; usage |
| `lakefile.lean` | both modules added to `lean_lib LeanFmtApplication` |
| `tests/watch/run.sh` | extended with the CLI surface |

Both new modules import only `LeanFmt.Discovery` and produce **observations**, never findings: the
observer yields snapshots and the Git adapter yields a path list. Neither runs an analysis, renders,
or decides what a path means — `.lean`-ness, `.lake` exclusion, configured `include`/`exclude`,
ordering and snapshotting all remain in `Project`/`Discovery`, reached through the ordinary `execute`.
Neither is in the compiler-plugin library, so neither is reachable from an integrated module's build.

## Behavior verified by hand

On a purpose-built two-module fixture project (`/tmp/wfix`, so generations are ~1 s and the signal is
not swamped by this repository's own analysis cost):

| Case | Result |
| --- | --- |
| startup | one generation, one report |
| single edit | exactly one generation per edit, report emitted, ×3 |
| **10 rapid edits** | **coalesced into exactly one generation** |
| create `.lean-fmt.toml` | generation fired |
| touch `lean-toolchain` | generation fired |
| create a new `.lean` source | generation fired |
| delete a source | generation fired |
| write an unrelated `notes.txt` | **no generation** |
| `SIGTERM` | exits 143, no torn output |

The config-creation case is the one the observer is specifically built for: creating a config changes
no existing file's stamp, so it is detected by observing the recognized filenames in every *ancestor
directory* of every selected source — finite, and precise, since a config in a directory with no
sources beneath it governs nothing.

## Decisions changed during execution

**1. `--changed BASE` became `--changed-since REV`.** An optional-argument flag cannot be told from a
file target: `check --changed main` is ambiguous between "compare against `main`" and "compare the
worktree, and check the file `main`". Guessing is how a caller silently formats a set they did not
intend, so the three comparisons are three flags. Freeze §9.1 amended.

**2. Selection provenance goes to stderr, not into `RunReport`.** §9.6 originally required the report
to carry it, "as a field" for the document formats. It cannot: `RunReport` derives `Lean.ToJson` and is
compared byte-for-byte against `ruff-15`'s `01-json-golden-check.json` by `tests/check/run.sh`. Adding
a field would break a frozen cross-stack compatibility contract in order to carry presentation. The
provenance is emitted as `lean-fmt:` notices beside the ones configuration already writes, so every
`--changed` run still states its comparison, its resolved base, every path it withheld and why, and
that it covered a subset. Freeze §9.6 amended; the honesty requirement is unchanged and still met.

**3. Each generation is a fresh child process — measured, and it reversed the plan.** §4 froze "every
generation runs the complete project through the ordinary `execute`", and I implemented that as a
second in-process call. It does not work: **`execute` does not reuse the result cache when called
twice in one process.**

| Workload | Wall time |
| --- | --- |
| watch generation 1 (in-process, warm cache on disk) | ~1 s |
| watch generation 2 (in-process, after one edit) | **~70 s** — the cold-cache price |
| a *separate* process, identical edit, immediately after | **0.52 s** |
| separate process, repeated | 0.51 s |

A 135× difference. The cross-process cache path demonstrably works, so a generation is now a child
`lean-fmt` invocation with the watch flags stripped from the caller's own argv. Making the in-process
path re-entrant would mean reworking cache lifecycle inside `LeanFmt.Application` — a lower layer this
stack does not own — to reach a path that is already correct. Re-execing is precisely the "no
retention" option §6 already permitted, and the ~400 ms fixed cost per generation is what §4 budgeted.

Two properties fall out for free: the child inherits stdout and stderr so §7's framing is unchanged,
and a generation that dies cannot take the session with it — the roadmap's failure-recovery
requirement.

The child argv is rebuilt from the **raw argument list** rather than re-rendered from the parsed
command, so a watched run analyzes exactly what the same command analyzes without `--watch`.
Re-rendering would mean maintaining a second spelling of every flag that could silently diverge.

**4. An empty `--changed` selection must not reach `execute`.** An empty `files` array means "the whole
project" to `execute`, so passing a zero-path selection through would format *everything* — the exact
inversion of what the caller asked. A zero selection is now an early success with an explicit notice,
which is also what §9.6 requires: "nothing changed" and "the project is clean" are different facts a CI
log must be able to tell apart. `tests/watch/run.sh` asserts it, because the failure mode is silent and
severe.

**5. A speculative `emitReport` stdout parameter was added and then removed.** While diagnosing
decision 3 I threaded an explicit stdout handle through `emitReport`, on the theory that
`Application.withoutProcessOutput`'s global stream swap was losing generation 2's report. That was the
wrong diagnosis — generation 2 was simply running cold and had not finished — and re-exec made the
parameter unnecessary. It was reverted rather than left in place: unused generality is worse than none,
and it would have documented a hazard that had not been demonstrated.

## Test design note

`tests/watch/run.sh` now covers both the platform premises (git and filesystem, from RWI-SPEC) and the
CLI surface. The CLI half tests **rejections and error paths only**, which are all resolved before any
project load — so the suite needs no Lake project and no warm cache, and stays fast. The watch loop's
own dynamics belong to `RWI-FINAL`, which owns the event-storm work.

## A defect this prompt found and did not fix

The in-process cache behavior of decision 3 is a real limitation, not merely an inconvenience for
watch: any future caller that runs `execute` more than once in a process will silently pay the cold
price. Watch routes around it; nothing fixes it. It is recorded here and in freeze §6, and
`RWI-FINAL` should decide whether it warrants a defect report of its own. I did not investigate the
root cause inside `Cache`/`Application` because it is below this stack's layer and the roadmap forbids
building a second execution path to compensate.

## Remaining uncertainty

- **The re-exec cost is measured only on a small fixture and this repository.** ~400 ms fixed per
  generation is the freeze's figure; `RWI-FINAL` should confirm it on the frozen mathlib sample, where
  both the discovery walk and the workspace load are larger.
- **The 200 ms poll default is still untuned** — carried forward from `RWI-SPEC`.
- **Signal handling remains default disposition.** SIGTERM was observed to exit 143 with no torn
  output, which is the atomicity argument of §8 holding in practice, but no handler runs and no
  orphaned `.lean-fmt-tmp` cleanup happens. §8 permits this; `RWI-FINAL` should confirm no temporary
  survives a signal during an `--output-file` write.
- **`--changed` renames were exercised only through git plumbing**, not end-to-end through the CLI
  against a rename in a real Lean project. The parse is characterized; the whole path is not.
- **Nanosecond `mtime` remains Darwin/APFS-measured**, unchanged from `RWI-SPEC`.
