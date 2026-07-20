# Watch generations and Git selection — frozen contract

Freeze for **RWI-SPEC**. Baseline measurements: `evidence/01-watch-baseline.md`. `RWI-IMPL` implements
against this document; where it deviates it must say so in `results/02-implementation.md` and amend
here.

Following the `*-SPEC` convention (`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC, `ruff-13` RCD-SPEC,
`ruff-14` RSF-SPEC, `ruff-15` RRF-SPEC), this prompt ships **no production Lean interface, config key,
or CLI surface**. Section numbers below are the citation targets for `RWI-IMPL` and `RWI-FINAL`.

---

## 1. Watch observes by polling, because Lean binds no filesystem-watch handle

`evidence` §1: Lean 4.33's `Std.Internal.UV` binds Signal, Timer, TCP, UDP, DNS and System. It does
**not** bind `uv_fs_event` or `uv_fs_poll`, and no `inotify`/`FSEvents`/`kqueue` appears anywhere in
`Init/` or `Std/`. The capability is absent from Lean, not from the platform.

`CLAUDE.md` permits another language for "a named capability … Lean cannot reach". Event-driven
watching is such a capability, and an external watcher (`fswatch`, `watchman`) would supply it. It is
rejected anyway:

- The benefit is unmeasured and, by §4, small. Polling costs one discovery walk — 34 ms measured
  (`evidence` §3) — against a ~600 ms generation. Event delivery could remove at most a fraction of a
  poll interval from a latency the analysis itself dominates.
- It would add a runtime dependency that is not present on a stock developer machine, for a mode that
  must degrade to "works everywhere" rather than "works where `fswatch` is installed".
- `CLAUDE.md` requires a *measured* speed gain. There is none to cite.

**Frozen: watch mode is a poll loop in pure Lean.** Should `RWI-FINAL` measure a poll cost that
matters at scale, reopen this section rather than bolting an external watcher onto the
implementation.

**Poll interval.** Default 200 ms, adjustable. It sits well above the 34 ms walk (so polling never
occupies a meaningful fraction of a core) and well below the ~600 ms generation (so it never becomes
the dominant term in observed latency). Polling faster cannot make feedback faster; the generation
does.

## 2. The change signal is `(relative path, byteSize, mtime.sec, mtime.nsec)`

Observation is a set of these tuples over exactly the files `LeanFmt.Project` already selects — the
complete non-`.lake` source selection, `ruff-13` discovery exclusions applied. Watch introduces no
second notion of which files belong to a project.

`evidence` §2 measured that Lean populates `mtime.nsec`: twelve writes inside one second produced
twelve distinct stamps, and a same-size rewrite remained distinguishable. So the tuple detects edits
a size-only or whole-second signal would miss, and no content digest is needed *for detection*.

**Detection latency is bounded; results are never wrong.** On a filesystem with coarse `mtime`
granularity, a same-second same-size edit can produce an identical tuple and be missed by that poll.
This weakens *when* a generation fires, never *what* it says: a generation re-reads every selected
source and re-digests it, and the result cache is keyed on content, so a stale tuple can delay a
generation but cannot produce a report that disagrees with the bytes on disk. Any later detected
change re-runs the complete project and picks the missed edit up. `RWI-IMPL` must not describe the
poll as guaranteeing that every edit is observed.

Directory-level creation and deletion are observed by the same walk: a file appearing or disappearing
changes the tuple *set*, which is compared as a set, not pairwise.

## 3. A generation is one complete `execute`, and its identity is the observed snapshot

A **generation** is one complete ordinary `execute` request over the whole project, plus the one
report it renders. Generations are strictly sequential: at most one runs at a time, and its report is
emitted whole before the next begins. This is the roadmap's "one complete deterministic generation at
a time".

Generation identity is the digest of the observed tuple set (§2) together with the configuration and
Lake identity of §6. Two generations with equal identity produce byte-identical reports — that is
what makes the mode testable, and `RWI-FINAL` should assert it directly. A monotone counter starting
at 1 is carried for display and framing (§7); the counter is presentation, the digest is identity.

## 4. Watch does **not** select only changed files — measured

The tempting design is to feed the changed files to `execute` and skip the rest. It is rejected on
both correctness and measurement.

**Correctness.** A run over a subset produces a subset report. The stop rule — "do not make a partial
changed-file run look like a complete-project clean result" — is exactly this hazard: a file whose
findings were introduced by an *edit to a different file* would keep its previous status, and a clean
generation would not mean a clean project.

**Measurement** (`evidence` §3). Per-run cost is dominated by fixed process cost, not by file count:

| | 1 file | 110 files (complete) |
| --- | --- | --- |
| fixed (`workspace_load` + `discovery` + `cache_epoch`) | ~438 ms | ~396 ms |
| per-file (`selection_snapshot` + `import_findings` + `cache_lookup`) | ~1 ms | ~68 ms |
| wall | 0.44 s | 0.59 s |

Selecting only changed files saves ~70 ms of a ~590 ms generation — about 12% — and buys it by giving
up the completeness guarantee. **Frozen: every generation runs the complete project through the
ordinary `execute`.** The aggregate result cache already supplies the incrementality, and it supplies
it *per file by content digest*, which is both finer and safer than anything a watch loop could infer
from `mtime`. This is what "both modes feed ordinary `execute` requests" and "no second execution
engine" mean in practice: there is no incremental path to build, because the cache is the incremental
path and it already exists.

The `--changed` Git mode of §9 *is* a subset selection, and it is honest about that (§9.6). Watch is
not.

## 5. Coalescing is bounded by construction: one pending generation, latest snapshot wins

There is no event queue. The observer holds two values: the last snapshot a generation *ran on*, and
the latest snapshot *observed*. When they differ, a generation is pending.

An event storm therefore cannot grow anything. Ten edits arriving during one generation collapse into
one differing snapshot and produce exactly one following generation, reflecting all ten. This
satisfies "queues and retained snapshots are bounded" and "no unbounded event queue" without a bound
to tune, a drop policy, or a backpressure rule — the state is O(selected files), which is the project
itself.

**Quiet-period debounce.** After a difference is first observed, wait until one poll interval passes
with the snapshot unchanged before starting the generation. This coalesces a multi-file save, a
branch checkout, or an editor's write-temp-then-rename into one generation rather than several. The
window is one poll interval (200 ms default) — small against the ~600 ms generation it protects.

**Superseded work.** A generation whose snapshot is already stale when it finishes is still emitted,
then immediately followed by the next. Its report is not wrong — it is a true report about the bytes
it read — and suppressing it would mean a user who stops typing sees nothing until they type again.
Cancelling a running generation is not required by the roadmap ("where safe"), and `execute` today
offers no cancellation point that would leave the result cache consistent; §11 records this as
deliberately out of scope.

## 6. Invalidation: what a generation must reconsider

Beyond source edits, a generation's meaning depends on inputs the poll must also watch:

| Input | Effect when changed |
| --- | --- |
| `.lean-fmt.toml`, `lean-fmt.toml` (any directory in the walk), and any file reached by `extend` | re-run `ruff-13` discovery; rule plans and per-file effective config are rebuilt |
| `lakefile.lean`, `lakefile.toml` | drop any retained workspace; full reload |
| `lake-manifest.json` | drop any retained workspace; full reload |
| `lean-toolchain` | drop any retained workspace; full reload |
| the `lean-fmt` executable itself | formatter identity `(path, byteSize, mtime)` changes; the result cache invalidates itself through existing machinery |

Config files must be observed even where discovery *excluded* the surrounding directory from source
selection — a config governs files it does not sit beside. Creation and deletion of a config file
count as changes: adding `.lean-fmt.toml` to a subdirectory changes the effective config of every
file beneath it.

**Workspace retention is permitted, not required.** Holding `Lake.Workspace` across generations would
amortize the ~300 ms `workspace_load`, plausibly taking a generation from ~590 ms to ~250 ms. It is
not frozen as mandatory because that gain is *projected, not measured*, and retention adds a
correctness obligation (the table above) whose cost is real. `RWI-IMPL` may spawn fresh per generation
or retain; if it retains, the invalidation table is mandatory and `RWI-FINAL` must measure whether
retention paid. Retention within a sequential poll loop is not concurrency and does not touch the
"no concurrent mutation of one Lean session" stop rule.

> **Resolved by `RWI-IMPL`: nothing is retained, and each generation is a fresh child process.** The
> choice this section left open was settled by measurement rather than preference. A second `execute`
> **in the same process does not reuse the result cache**: generation 1 ran warm and generation 2 took
> ~70 s — the full cold-cache price — while a *separate* process handling the identical edit took
> 0.52 s. That is a 135× difference, and it makes in-process retention not merely unprofitable but
> unusable.
>
> So a generation is a child `lean-fmt` invocation with the watch flags stripped. This keeps watch
> inside the observer layer: making the in-process path re-entrant would mean reworking cache
> lifecycle in `LeanFmt.Application`, a lower layer this stack does not own, to reach a path that
> already works correctly across processes. The ~400 ms fixed cost per generation is exactly the price
> §4 already accounted for.
>
> The child inherits stdout and stderr, so §7's framing is unchanged; it also means a generation that
> dies cannot take the session with it, which is the failure-recovery property the roadmap asks for.
> `RWI-FINAL` should measure whether the in-process cache limitation is worth reporting upstream as a
> defect in its own right.

## 7. Output framing is a per-format decision, and document formats do not concatenate

`ruff-15` shipped six `--output-format` values that do not frame alike, and the inherited state note
requires this be decided explicitly rather than defaulted into concatenation.

**Line-oriented — `text`, `concise`, `github`.** Append. Each generation's report is written in full,
preceded by a generation banner on **stderr** (not stdout), so a `grep` consumer's stream stays
uncontaminated and a human still sees the boundary. GitHub's workflow-command format tolerates this
because a runner reads commands line by line.

**Document — `json`, `sarif`, `junit`.** One complete document **per generation**, and each generation
**replaces** the previous one. A SARIF log has a single `runs` array and a JUnit file a single root
element; concatenating generations yields something no parser accepts, so appending is not an option
and neither is emitting a second root.

Replacement requires a destination that can be replaced, so in watch mode these three formats
**require `--output-file`** and are rejected on stdout:

```
--output-format sarif requires --output-file in watch mode; a stream of SARIF documents is not a SARIF log
```

This follows the `ruff-14`/`ruff-15` precedent of refusing a flag a mode cannot honor rather than
emitting well-formed misleading output. `writeReportFile` is already temp-then-rename atomic
(`Cli.lean:829`), which `ruff-15` established as safe for exactly this polling consumer: the reader
of `--output-file` sees generation N or generation N+1, never a splice.

## 8. Shutdown is clean because writes are atomic; a signal handler is optional

`Std.Async.Signal` exists in 4.33 and binds `sigint`/`sigterm`, with `Selector` composition against
`Timer.Interval` — so a "finish this generation, then exit" handler is implementable. It is **not**
required, and `RWI-IMPL` should not adopt it without cause:

- Every write in the product is atomic temp-then-rename — the report file (§7) and source publication
  alike. Default signal disposition terminates the process between or during a generation and **cannot
  leave a torn file or a half-written report**; the temporary is simply orphaned.
- `Std.Async` is used nowhere in the tree today (`evidence` §1). Introducing a libuv event loop
  alongside the existing bounded-child spawning is a real change in the process model, and buys only a
  friendlier message and a slightly tidier exit.

**Frozen:** clean shutdown is guaranteed by write atomicity, not by signal handling. If `RWI-IMPL`
installs a handler, it must additionally remove the orphaned `.lean-fmt-tmp` sibling, and must keep
the guarantee that a second signal terminates immediately.

Exit status: a watch session ended by a signal exits **0**. Watch is a long-running service and asking
it to stop is not a failure. Findings do not set the exit code in watch mode — there is no single run
to report on — which is a deliberate difference from batch `check` and must be documented on the flag.

## 9. Git changed-files selection

### 9.1 Comparison modes

| Spelling | Question | Command |
| --- | --- | --- |
| `--changed` | what differs from `HEAD` in my worktree | `git diff --name-status -z HEAD` **plus** untracked (§9.4) |
| `--changed-since REV` | what my branch changed since it left `REV` | `git diff --name-status -z REV...HEAD` (three-dot) |
| `--staged` | what I am about to commit | `git diff --cached --name-status -z HEAD` |

> **Amended by `RWI-IMPL`.** This section originally spelled the second form `--changed BASE`, with an
> optional argument. That cannot be parsed unambiguously beside a file target: `check --changed main`
> could mean "compare against `main`" or "compare the worktree, and check the file `main`", and
> resolving it by guessing is how a caller silently formats a set they did not intend. The three
> comparisons are three separate flags. `results/02-implementation.md` records the change.

Three-dot for the `BASE` form is measured, not stylistic (`evidence` §8): on a fixture where `main`
and `feature` diverged, two-dot `main..feature` reported ten paths — including `MainOnly.lean` as a
deletion the branch never made — while three-dot `main...feature` reported exactly the two files the
branch touched. Two-dot answers "how do these trees differ", which is not the question.

### 9.2 Parsing is `-z`, always

`evidence` §6: default `git diff` output C-quotes non-ASCII paths (`"\303\234n\303\257code Spaced.lean"`),
and `core.quotePath=false` fixes that case while **still** quoting an embedded double quote
(`"quo\"te.lean"`). Only `-z` emits raw bytes for both. A line-splitting adapter is therefore wrong on
Unicode filenames — which this product, with its exactness commitments, cannot ship.

The `-z` stream is NUL-terminated fields with a status-dependent field count: a rename is **three**
fields (`R###`, old path, new path), every other status is **two** (status, path). A parser that
assumes pairs desynchronizes on the first rename and mis-assigns every subsequent path.

### 9.3 Change classes

| Status | Selection |
| --- | --- |
| `M`, `A`, `C`, `T` | select the path |
| `R###` (rename) | select the **new** path; the old path no longer exists |
| `D` (delete) | **drop** — there is nothing to format, and naming it would be a path error about a file the caller did not name |
| `U` (unmerged) | **drop**, and report it (§9.6): a conflicted file is not something to format |

### 9.4 Untracked files are included

`git diff` never reports untracked files (`evidence` §7): the newly created `New.lean` appeared only
in `git ls-files --others --exclude-standard`. A `--changed` selection built from `diff` alone
silently skips **every brand-new file**, which is precisely when a formatter is most wanted. So
`--changed` and `--staged`-less forms union in `git ls-files --others --exclude-standard -z`.

`--exclude-standard` applies `.gitignore`, so ignored files stay excluded (measured: `Ignored.lean`
withheld once `.gitignore` named it). `--changed BASE` does **not** union untracked files: a
merge-base comparison is a question about committed history.

### 9.5 Filtering, and the root boundary

Git returns paths relative to the repository toplevel, which need not be `--root`. After decoding:

1. Resolve each path against the repository toplevel.
2. **Drop anything outside `--root`** — a repository can hold several projects, and formatting a
   sibling because it shares a repository would violate the root contract.
3. Apply gate 1 — the floor — **in the adapter**: drop anything that is not a `.lean` source and
   anything inside `.lake`. Configured `include`/`exclude` still belong to `Discovery` and are not
   duplicated here.

   > **Amended by `RWI-FINAL`.** This step originally read "apply the ordinary `LeanFmt.Project`
   > selection and `ruff-13` discovery exclusions unchanged … through the existing code rather than a
   > Git-specific reimplementation." That assumption is false, and shipping on it was a bug. An
   > *explicitly named* file deliberately bypasses discovery's gates 2–4 — "naming a path is saying
   > something" (`ruff-13` `notes/01-discovery.md` §11) — and the floor it cannot skip is reported as
   > a **hard error**, `selected file is not a Lean source`. Because git names these paths and the
   > user does not, an error is the wrong answer: measured on a fixture repository, an ordinary
   > untracked `README.md` (and the `.lake` tree, in a repository that does not ignore it) aborted the
   > entire `--changed` run. Regression-tested in `tests/watch/run.sh`.
4. Deduplicate and order exactly as an ordinary run orders its targets, so a `--changed` run and a
   full run agree on the relative order of the files they share.

Steps 3 and 4 are why the adapter "owns observation only": it produces a path list, and every question
of what a path *means* stays where it already lives.

### 9.6 A partial run must say it is partial

The stop rule is explicit. A `--changed` report is a report about a **selected subset**, and:

- The run announces its selection provenance — the comparison mode, the resolved base commit, and the
  count — on **stderr**, for every format, as a `lean-fmt:` notice beside the ones configuration
  already emits.

  > **Amended by `RWI-IMPL`.** This originally said the *report* carries provenance and that "the
  > document formats carry it as a field". It cannot: `RunReport` is `ruff-15`'s frozen JSON
  > compatibility surface, compared byte-for-byte against `evidence/01-json-golden-check.json` by
  > `tests/check/run.sh`. Adding a field would break a frozen cross-stack contract in order to carry
  > presentation, so provenance goes where the product's other run-level notices already go. The
  > honesty requirement is unchanged and still met — every `--changed` run says what it covered.
- Paths dropped for a *reason the caller would want to know* are reported: unmerged files (§9.3), and
  paths that Git named but that fell outside `--root` (§9.5 step 2). Silent dropping is what makes a
  partial run look complete.
- A `--changed` run that selects **zero** files is a success with an explicit "no changed Lean sources
  under <root>" notice, not a silent clean report. These are different facts and a CI log must be able
  to tell them apart.

### 9.7 Git absence and non-repositories are request errors

Both are hard errors, exit 2, following the existing convention that a path error names the caller's
own argument.

Two measured traps shape this:

- **A missing `git` binary does not throw.** `IO.Process.output` returns `exitCode = 255` rather than
  raising (`evidence` §4), so the natural `try`/`catch` implementation never fires. Detect from the
  exit code.
- **Probe with `git rev-parse --show-toplevel`, never with `git diff`.** Outside a repository
  `rev-parse` exits 128 with one clean line of stderr; `git diff --name-status HEAD` exits 129 after
  dumping its entire ~90-line option usage (`evidence` §5). The second is unusable as a diagnostic.

An unknown `BASE` is likewise a request error naming what the caller typed, distinct from "not a
repository".

## 10. Watch admits only non-writing modes

`--watch` is accepted for `check`, `diff`, and `format --check`. It is **rejected** for `format` and
`fix`.

A writing mode under watch publishes source, which changes the very `mtime`/`byteSize` tuples §2
polls, which triggers the next generation, which publishes again. The loop is self-sustaining by
construction — not a race, a certainty — and it would be a formatter that never stops running against
a user who has stopped typing. Suppressing self-writes is possible in principle and is not worth the
mechanism: `check`/`diff` is what a watch loop is for, and it is what `ruff check --watch` admits.

```
--watch is not available for fix; watch runs previews, and a writing mode retriggers itself
```

## 11. Deliberately out of scope

Named so `RWI-IMPL` does not treat them as omissions:

- **Cancelling a running generation.** §5. The roadmap says "where safe" and `execute` offers no
  cancellation point leaving the result cache consistent.
- **An event-driven watcher.** §1, contingent on §1's reopening condition.
- **Watch over the editor service.** `LeanFmt.Service` (`ruff-14`) owns unsaved buffers and is
  capacity-one FIFO; watch observes *disk*. They are different evidence sources and must not be
  merged.
- **A public job-control surface.** The `RWI-IMPL` stop rule forbids it. The poll interval is the only
  tunable, and it is a number, not a control.

## 12. What `RWI-IMPL` owes

- Private filesystem observer and private Git selection adapter — both producing path lists and
  nothing else, per §9.5.
- No new public surface below `LeanFmt.Cli` beyond the flags in §7/§9.1/§10.
- Characterization tests over: the `-z` rename field-count asymmetry with a Unicode and an
  embedded-quote path (§9.2); delete and unmerged dropping (§9.3); untracked inclusion and ignored
  exclusion (§9.4); out-of-root dropping (§9.5); the zero-selection notice (§9.6); non-repository and
  missing-binary exit codes (§9.7); document-format rejection on stdout (§7); writing-mode rejection
  (§10).
- A `tests/watch/run.sh` integration suite in the established style, added to `CLAUDE.md`'s and
  `AGENTS.md`'s build lists.
