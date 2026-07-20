---
kind: state
first_unresolved: 02-implementation
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
| 02-implementation | RWI-IMPL | planned | RWI-SPEC |
| 03-acceptance | RWI-FINAL | planned | RWI-IMPL |

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
  NUL-terminated fields against two for every other status. `--changed BASE` uses **three-dot**
  merge-base (measured: two-dot reported ten paths including a deletion the branch never made, against
  three-dot's two). Untracked files are unioned in from `ls-files --others --exclude-standard`,
  because `git diff` never reports them. Deletes and unmerged paths drop; renames select the new path;
  out-of-root paths drop and are reported.
- **A `--changed` run reports that it is partial** — selection provenance in the report, dropped paths
  surfaced, and a zero-selection run is an explicit notice rather than a silent clean report.
- **Git absence and non-repositories are request errors, exit 2.** Probe with
  `git rev-parse --show-toplevel` (exit 128, one clean line), never `git diff` (exit 129 plus a
  ~90-line usage dump). A missing binary must be detected from `IO.Process.output`'s `exitCode = 255`
  — it does **not** throw.
- **Workspace retention across generations is permitted, not mandated.** The ~590 ms → ~250 ms gain is
  projected, not measured. If `RWI-IMPL` retains, `notes` §6's invalidation table (config files,
  `lakefile.*`, `lake-manifest.json`, `lean-toolchain`, the executable) is mandatory and `RWI-FINAL`
  must measure whether it paid.

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
