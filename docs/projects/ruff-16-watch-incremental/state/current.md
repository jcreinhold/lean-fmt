---
kind: state
first_unresolved: none
---

# Current state

Its external prerequisite stacks are `ruff-13-config-discovery` and `ruff-15-reporting`; both record
`first_unresolved: none`. Live code was re-read for this freeze (`Cli.lean`, `Application.lean`,
`Project.lean`), together with the Lean 4.33 sources this stack depends on (`Init/System/IO.lean`,
`Std/Async/`, `Std/Internal/UV/`). If live code contradicts a prerequisite result, reopen the owning
prerequisite rather than patching around it.

**RWI-SPEC is verified** (`results/01-contract.md`; freeze `notes/01-watch-generations.md`; baseline
`evidence/01-watch-baseline.md`). Event coalescing, generation identity, configuration/Lake
invalidation, per-format output framing, shutdown, Git comparison modes, rename/delete/untracked
behavior, and failure recovery are frozen precisely enough for `RWI-IMPL`. Following the `*-SPEC`
convention (`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC, `ruff-13` RCD-SPEC, `ruff-14` RSF-SPEC, `ruff-15`
RRF-SPEC), no production Lean interface, config key, or CLI surface shipped. What shipped besides
documentation is one characterization suite, `tests/watch/run.sh`, registered in `CLAUDE.md` and
`AGENTS.md`.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-contract | RWI-SPEC | verified | — |
| 02-implementation | RWI-IMPL | verified | RWI-SPEC |
| 03-acceptance | RWI-FINAL | verified | RWI-IMPL |

**RWI-IMPL is verified** (`results/02-implementation.md`). `LeanFmt/Watch.lean` (private poll observer)
and `LeanFmt/GitSelection.lean` (private `-z` changed-file adapter) ship, both importing only
`LeanFmt.Discovery` and both producing observations rather than findings. `LeanFmt/Cli.lean` gained
`--watch`, `--poll-interval`, `--changed`, `--changed-since`, `--staged`, their rejections, and the
provenance notices. Verified by hand on a two-module fixture: one generation per edit, **10 rapid
edits coalesced into exactly one generation**, config creation / `lean-toolchain` / source creation /
source deletion each firing, an unrelated `.txt` correctly not firing, and `SIGTERM` exiting 143 with
no torn output.

`RWI-IMPL` amended the freeze in three places, each marked in `notes/01-watch-generations.md`:

- **`--changed BASE` became `--changed-since REV`** (§9.1). An optional-argument flag cannot be told
  from a file target; `check --changed main` is ambiguous and guessing formats the wrong set.
- **Provenance goes to stderr, not into `RunReport`** (§9.6). `RunReport` is `ruff-15`'s frozen JSON
  compatibility surface, compared byte-for-byte by `tests/check/run.sh`; a new field would break a
  cross-stack contract to carry presentation. Every `--changed` run still states its comparison,
  resolved base, withheld paths, and that it covered a subset.
> **[DISPUTED by `ruff-16b-cache-identity`.]** The in-process framing below is likely wrong.
> `execute` opens a fresh `ResultCache` per call (`Application.lean:1298`), and the compared
> numbers were different workloads (cold-after-edit versus an unchanged tree). The real defect
> appears to be that `Cache.environmentDigest?` folds every project source into the index
> filename, so any edit invalidates the whole project in any process. `RCI-SPEC` owns the
> amendment; do not act on the paragraph below before reading that stack's `state/current.md`.

- **Each generation is a fresh child process, and nothing is retained** (§4, §6) — settled by
  measurement, not preference. `execute` **does not reuse the result cache when called twice in one
  process**: generation 2 in-process took ~70 s (the cold price) where a separate process handling the
  identical edit took 0.52 s, a 135× difference. Re-exec is the "no retention" option §6 already
  permitted, and it keeps watch inside the observer layer rather than reworking cache lifecycle in
  `LeanFmt.Application`.

**A defect was found and deliberately not fixed.** The in-process cache limitation above affects any
future caller that runs `execute` more than once per process, not just watch. Watch routes around it;
nothing fixes it. Root-causing it means going into `Cache`/`Application`, below this stack's layer, and
the roadmap forbids building a second execution path to compensate. `RWI-FINAL` should decide whether
it warrants a defect report of its own.

**RWI-FINAL is verified** (`results/03-acceptance.md`; stress evidence `evidence/03-acceptance-stress.md`).
Every clause of the roadmap's completion contract has evidence: 10 rapid edits coalesce into one
generation; config creation, `lean-toolchain`, source creation and deletion each fire while an
unrelated `.txt` does not; `--staged`/`--changed`/`--changed-since` distinguish index, worktree and
merge-base on one tree; a rename selects the new path with the old path and the delete both disclosed;
a broken file reports `broken=1` without ending the session and recovers on repair; an identical tree
produces byte-identical output three generations apart; and parent RSS grew **16 KiB over 13
generations**. `SIGTERM` exits 143 with no torn output and no orphaned temporary.

**RWI-FINAL found and fixed a shipped bug.** An untracked non-Lean file — an ordinary `README.md`, or
an unignored `.lake` tree — aborted every `--changed` run with `selected file is not a Lean source`.
Freeze §9.5 step 3 had assumed handing git's paths to `execute` would let the ordinary gates drop
non-sources; it does not, because an explicitly named file bypasses gates 2–4 and the floor it cannot
skip is a hard error. Those gates are calibrated for paths *the user typed*, and under `--changed` the
paths come from git. The adapter now applies the floor itself. Freeze §9.5 amended; regression-tested
in `tests/watch/run.sh` and mutation-checked. The class was invisible against this repository — which
ignores `.lake` and carries no stray untracked files — and only appeared against a purpose-built
fixture repository.

Key frozen decisions:

- **Watch polls, in pure Lean.** Lean 4.33's `Std.Internal.UV` binds Signal, Timer, TCP, UDP, DNS and
  System but **not** `uv_fs_event`/`uv_fs_poll`; no `inotify`/`FSEvents`/`kqueue` appears in `Init/` or
  `Std/`. An external watcher was rejected under `CLAUDE.md`'s measured-benefit rule. Default poll
  interval 200 ms — above the 34 ms discovery walk, below the ~600 ms generation.
- **The change signal is `(relative path, byteSize, mtime.sec, mtime.nsec)`** over exactly the files
  `LeanFmt.Project` already selects. Nanoseconds are populated (12 same-second writes → 12 distinct
  stamps), so a same-size rewrite is detectable without a content digest. On a coarse-granularity
  filesystem this bounds detection *latency*, never correctness: every generation re-reads and
  re-digests source.
- **Each generation runs the complete project through the ordinary `execute`** — there is no
  changed-file fast path in watch mode. Measured: fixed cost (`workspace_load` 301–344 ms +
  `discovery` ~34 ms + `cache_epoch` 61 ms ≈ 400 ms) is independent of file count, and 1 file → 110
  files adds ~70 ms warm (0.44 s vs 0.59 s). Subset selection would save ~12% and forfeit the
  completeness guarantee the stop rule protects. The aggregate result cache is the incremental path.
- **Coalescing is bounded by construction**: two retained snapshots (last-run, last-observed) with a
  one-poll-interval quiet-period debounce. No queue, no drop policy, no backpressure. A superseded
  generation is still emitted, then followed by the next; cancellation is out of scope because
  `execute` offers no cache-consistent cancellation point.
- **Output framing is per format.** `text`/`concise`/`github` append with a generation banner on
  stderr. `json`/`sarif`/`junit` emit one complete document per generation, replacing the previous,
  and **require `--output-file`** — they are rejected on stdout because concatenation produces
  something no parser accepts. This resolves the question `ruff-15` handed over; concatenation was not
  defaulted into.
- **Shutdown is clean because writes are atomic**, not because a signal is handled. `Std.Async.Signal`
  binds `sigint`/`sigterm` and is implementable, but temp-then-rename already makes an abrupt exit
  untearable, and `Std.Async` is used nowhere in the tree. A handler is optional; if taken it must
  remove the orphaned `.lean-fmt-tmp` sibling and let a second signal terminate immediately. A
  signalled watch session exits 0.
- **Watch admits only non-writing modes** — `check`, `diff`, `format --check`. `format` and `fix` are
  rejected: publishing source changes the tuples the poll observes, retriggering the loop by
  construction.
- **Git selection uses `-z` always.** Default output C-quotes non-ASCII and `core.quotePath=false`
  still quotes an embedded double quote, so only `-z` is byte-exact; its rename records carry three
  NUL-terminated fields against two for every other status. `--changed-since REV` uses **three-dot**
  merge-base (measured: two-dot reported ten paths including a deletion the branch never made, against
  three-dot's two). Untracked files are unioned in from `ls-files --others --exclude-standard`,
  because `git diff` never reports them. Deletes and unmerged paths drop; renames select the new path;
  out-of-root paths drop and are reported.
- **A `--changed` run reports that it is partial** — comparison, resolved base, and every withheld
  path announced on stderr (not in `RunReport`, per the amendment above), and a zero-selection run is
  an explicit notice that never reaches `execute`: an empty file list means "the whole project" there,
  so passing one through would format everything.
- **Git absence and non-repositories are request errors, exit 2.** Probe with
  `git rev-parse --show-toplevel` (exit 128, one clean line), never `git diff` (exit 129 plus a
  ~90-line usage dump). A missing binary must be detected from `IO.Process.output`'s `exitCode = 255`
  — it does **not** throw.
- **Nothing is retained: each generation is a fresh child process** (resolved by `RWI-IMPL`, see the
  amendment above). `notes` §6's invalidation set — config files, `lakefile.*`, `lake-manifest.json`,
  `lean-toolchain` — is still what the observer watches, since a change to any of them must start a
  generation whether or not a workspace is held.

## Inherited from `ruff-15-reporting` (verified, now resolved)

- **"Output framing" was a per-format question.** `RWI-SPEC` decided it explicitly and did not default
  into concatenation: line-oriented formats append with a stderr banner, document formats emit one
  replaced document per generation and require `--output-file`. See the framing bullet above.
- **Rendering is not a per-generation cost worth designing around.** A 10,000-finding report renders in
  1–312 ms (`ruff-15/evidence/03-report-scale.md`); a realistic generation is far smaller. This stack's
  own measurements confirm the guidance — coalescing was sized against the ~600 ms analysis
  generation, not against render cost.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching
  around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Open questions carried into `RWI-IMPL`

- Nanosecond `mtime` is Darwin/APFS-measured; Linux/ext4 and network filesystems are unverified. Do
  not describe the poll as observing every edit.
- The retention gain assumes `workspace_load` is fully amortizable; some of it may be per-request.
- The 200 ms poll default is reasoned, not tuned.
- Poll cost at scale is unmeasured; if the walk approaches generation cost on the frozen sample,
  reopen `notes` §1 rather than working around it.
- Pass `--find-renames` explicitly rather than depending on the `diff.renames` default.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful
evidence, and state agrees with live code. Missing, stale, unsupported, or unread checks are failures
to verify.
