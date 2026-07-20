# RWI-FINAL — event storms, repository states, and retention

Claim: **RWI-FINAL** — test rapid edits, config/lakefile changes, rename/delete, branch/index/worktree
states, signals, analysis failures, stale generations, memory retention, and deterministic final
output.

Evidence: `evidence/03-acceptance-stress.md`. This prompt found and fixed one shipped bug and amended
the freeze once more (`notes/01-watch-generations.md` §9.5).

## Commands

```sh
LEAN_NUM_THREADS=1 lake build
lake exe lean-fmt-tests
tests/watch/run.sh
tests/boundary/run.sh
tests/check/run.sh
tests/reporting/run.sh
tests/stream/run.sh
tests/discovery/run.sh
tests/modes/run.sh
tests/suppression/run.sh
tests/lossless/run.sh
tests/syntax/run.sh
git diff --check
uv run --with pyyaml .claude/skills/lean-plan/scripts/check_stack.py <workspace> --structural  # from kan-proofs
uv run --with pyyaml .claude/skills/lean-plan/scripts/write_next.py <workspace> --check        # from kan-proofs
```

Stress commands and their raw output are in `evidence/03-acceptance-stress.md`.

## Results read

| Check | Result |
| --- | --- |
| `lake build` | `Build completed successfully (48 jobs)` |
| `lean-fmt-tests` | `lean-fmt module-artifact tests passed` |
| `tests/watch/run.sh` | `lean-fmt watch/git selection characterization passed` |
| `tests/boundary/run.sh` | `lean-fmt native module and dependency boundary passed` |
| `tests/check/run.sh` | `lean-fmt check integration tests passed` |
| `tests/reporting/run.sh` | `lean-fmt reporting format tests passed` |
| `tests/stream/run.sh` | `failures=0` |
| `tests/discovery/run.sh` | `lean-fmt configuration discovery acceptance tests passed` |
| `tests/modes/run.sh` | `lean-fmt product mode integration tests passed` |
| `tests/suppression/run.sh` | `lean-fmt suppression acceptance tests passed` |
| `tests/lossless/run.sh` | `lean-fmt lossless projection corpus passed` |
| `tests/syntax/run.sh` | `lean-fmt syntax-tier rule integration tests passed` |
| `git diff --check` | no output |
| structural checker | `OK: 3 prompt(s), 0 warning(s), no errors.` |
| `write_next.py --check` | `OK: state/next.md matches first_unresolved='none'` |

Environment: `leanprover/lean4:v4.33.0-rc1`, Darwin arm64, APFS, `git version 2.50.1`. No full-mathlib
run was made; this stack's roadmap forbids it and this prompt does not authorize it.

## Roadmap completion contract, item by item

| Contract clause | Evidence |
| --- | --- |
| coalesces filesystem events | 10 rapid edits → **one** generation (`evidence` §1) |
| invalidates project/config/cache state correctly | config creation, `lean-toolchain`, source create/delete each fire; unrelated `.txt` does not (`evidence` §2) |
| cancels superseded work where safe | not implemented, and deliberately — `execute` has no cache-consistent cancellation point (`notes` §5, §11) |
| one complete deterministic generation at a time | generations strictly sequential; identical tree → byte-identical output three generations apart (`evidence` §6) |
| explicit Git base/index/worktree contract | `--staged` 1 path vs `--changed` 2 on the same tree; `--changed-since` three-dot excludes the main-only file (`evidence` §4) |
| deleted/renamed/untracked/ignored/out-of-root predictable | rename selects the new path, old path and delete both disclosed; untracked unioned, ignored withheld (`evidence` §4, RWI-SPEC `evidence` §7) |
| both modes feed ordinary `execute` | a generation is a child `lean-fmt` invocation; `--changed` only fills `RunRequest.files` |
| queues and retained snapshots bounded | no queue exists by construction; parent RSS grew 16 KiB over 13 generations (`evidence` §7) |
| shutdown clean | `SIGTERM` → 143, no torn output, no orphaned temporary (`evidence` §1, §8) |

## The bug this prompt found and fixed

**An untracked non-Lean file aborted every `--changed` run.** On a fixture repository holding an
ordinary `README.md` and an unignored `.lake` tree:

```
lean-fmt: selected file is not a Lean source: /private/tmp/acc/proj/.lake/config/0/lakefile.olean
```

`notes` §9.5 step 3 had said the adapter should hand git's paths to `execute` and let "the ordinary
`LeanFmt.Project` selection and `ruff-13` discovery exclusions" drop the ones that are not sources —
explicitly *rather than* a Git-specific reimplementation. That is false, and RWI-IMPL shipped on it.
An explicitly named file deliberately bypasses discovery's gates 2–4 — "naming a path is saying
something" — and the floor it cannot skip is a **hard error**, not a silent drop. The distinction that
matters: those gates are calibrated for paths *the user typed*, and under `--changed` the paths come
from git.

The adapter now applies gate 1 itself — `.lean` extension, not inside `.lake` — and drops silently,
because "your `README.md` is not a Lean source" is not a fact the caller needs. Configured
`include`/`exclude` remain `Discovery`'s to answer and are not duplicated.

This is a good argument for acceptance prompts running against a *fixture repository* rather than the
project's own tree: `lean-fmt`'s repository ignores `.lake` and has no stray untracked files, so the
whole class was invisible until a fresh repository was built. `tests/watch/run.sh` now creates the
condition deliberately.

The regression test was mutation-checked rather than merely observed to pass: with the `isCandidate`
guard removed the suite fails with `an untracked non-Lean file aborted --changed`; restored, it passes.

## Measurements

**Retention is flat.** Parent RSS across 13 generations: 51 328 → 51 344 KiB, growth **16 KiB
(0.03%)**. This follows directly from RWI-IMPL's re-exec decision — the parent holds only the observed
snapshot, and each generation's analysis memory belongs to a child that exits. No run approached the
stack's stop thresholds (8 GiB aggregate RSS, abnormal pressure, 256 MiB new swap).

**Determinism holds under replacement.** Five separate runs over an unchanged tree produced identical
bytes. Across watch generations: 5 sources → add one → 6 (differs) → remove it → 5, **byte-identical to
the first**. That confirms both the deterministic-output contract and §7's document-format replacement
semantics in one measurement.

**Failure does not end a session.** A syntactically incomplete file was reported as `broken=1` in its
generation with the session alive, and `broken=0` on the generation after it was repaired.

## Decisions changed during execution

- **`notes` §9.5 step 3 amended** — the adapter applies the floor itself. Recorded above and marked in
  the freeze.
- **No signal handler was added.** §8 left it optional and argued clean shutdown follows from write
  atomicity. `SIGTERM` was measured to exit 143 with no torn output and no orphaned temporary, so the
  optional refinement stays unbuilt rather than added speculatively. The honest limit of that evidence
  is recorded below.
- **Superseded-generation cancellation stays unimplemented**, per `notes` §5/§11. A generation whose
  snapshot went stale is still emitted and immediately followed by the next; that behavior was
  observed throughout the storm testing and is what makes a user who stopped typing see a result.

## Remaining uncertainty

- **The orphaned-temporary result is a negative observation, not a proof.** No `.lean-fmt-tmp`
  survived any session run here, but a signal landing between `writeFile` and `rename` would leave
  one, and nothing collects it. §8 permits this; a future stack adding a signal handler owes the
  cleanup.
- **Scale is untested.** Every dynamic measurement is on a two- or three-module fixture, chosen so the
  loop's behavior is not swamped by analysis cost. The 34 ms discovery walk and ~400 ms fixed
  generation cost come from `RWI-SPEC` on this 110-file repository; neither was re-measured on the
  frozen mathlib sample, where both are larger. If the walk approaches generation cost there, `notes`
  §1's rejection of an event-driven watcher should be reopened.
- **The in-process cache defect from RWI-IMPL remains unfixed and unreported upstream.** `execute` does
  not reuse the result cache when called twice in one process (~70 s versus 0.52 s). Watch routes
  around it by re-execing. It affects any future caller that runs `execute` more than once per
  process, and root-causing it means going into `Cache`/`Application` — below this stack's layer. It
  should be carried into `ruff-19-performance` or raised as its own defect rather than left in a
  result note.
- **Nanosecond `mtime` remains Darwin/APFS-measured**, unchanged since `RWI-SPEC`. Linux/ext4 and
  network filesystems are unverified.
- **`--changed` was not exercised against a repository with a conflicted (`U`) file.** The drop is
  implemented and the parse is characterized, but no merge conflict was staged end to end.
