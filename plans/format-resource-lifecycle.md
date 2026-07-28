# Plan: fix `format` resource lifecycle — per-child fd leak + all-or-nothing batch publish

## Context

Report from kan-proofs (1432 files, `lake exe lean-fmt format`, 7 min):

```
mode=format files=1432 findings=319 changed=0 written=0 broken=0 rejected=1269 … infrastructure_failures=163
```

Three compounding defects, one root theme: **per-target resources are retained for the whole run instead of being
released per target.**

### 1. Pipe-fd leak in the parallel spawn path → EMFILE (the 163 infrastructure failures)

Measured on kan-proofs (`format --check --no-cache`, this repo's binary):

| Mode | Parent fds | Parent PIPEs |
| --- | --- | --- |
| `--workers 1` (serial `runChild`) | flat 5723 | flat 4 |
| default (12 workers, `spawnChild` registry path) | grows linearly | **2 → 1498 over ~700 children ≈ 2 fds leaked per child** |

Baseline is already high: the parent keeps **~5723 olean fds open** (the module system mmaps
`.olean`/`.olean.private`/`.olean.server`/`.ir`/`.ir.sig` per imported module and never closes them), and every spawned
child **inherits all of them** plus opens ~4300 of its own → ~10008 fds per child, steady. On a macOS session with a
typical soft `RLIMIT_NOFILE` (e.g. 10240), ~1300 leaked pipe pairs on top of that baseline is exactly where `open()`
starts failing — which is why the user's run died at target ~1316 with
`resource exhausted (error code: 24, too many open files)` on every remaining target's `{index}.setup.json`.

Lean exposes no explicit close: "the file handle is closed when the last reference to it is dropped".
`ExactRun.spawnChild` (Application.lean ~333–370) pipes child stdout/stderr and drains them with `readToEnd` on
`Task.Priority.dedicated` threads; in the parallel path something retains the pipe handles past each child's reap, so
fds accumulate per child. The serial `runChild` (~298–315) does not leak.

### 2. All-or-nothing batch publish → 1269 spurious rejections

A writing `format` never publishes per file. `prepareFormatFile` defers ("Publication is deferred until every file has
an admitted candidate", Application.lean ~1260) into `pendingFormats` (~1286, ~1729); at the end `batchReady` requires
**zero** failures/broken/ rejected/infrastructure-failures across all 1432 files, else every healthy file gets
`"format batch was not published because another target failed"` (~1742–1765).

Triggers in the report: `GlobalMinimalModel.lean` has genuine elaboration errors (correctly refused by the validator),
two files hit `uncaught backtrack exception`, two hit `node count changed` (real formatter bugs, out of scope here),
then the EMFILE wave. One broken file poisoned 1269 good ones. It also retains every file's source+output in memory for
the entire run.

Per-file atomic publish **already exists**: `publishAtomic` (~860: stale-source check → temp file → rename, per-file
rollback) is what `fix` and `organize` use.

### 3. Per-target temp files live until run end

`{index}.setup.json` and `{index}.lean` are written per envelope (`ExactRun.envelope` ~410) and only removed by
`withExactRun`'s `finally` (~653). Not the fd problem, but same lifecycle smell; cleanup becomes natural once envelope
output moves to files.

## Approach

Two changes, one principle: **a target's resources die with the target.**

### A. Remove child pipes entirely (fix the leak class, not the symptom)

Rather than hunting the exact retained reference in the dedicated-task machinery, stop creating two pipes per child. The
"child" is our own binary (`run.application`), so:

- Child entry: `runAnalyzeChild` (`__analyze-exact` dispatch, Application.lean:2399) gains an **optional** trailing
  out-path argument (absent = today's stdout protocol, so direct test callers are untouched). With the path present it
  writes the envelope bytes to `{index}.out` itself; on failure it writes diagnostic text to `{index}.err`.
- Parent spawns with `stdout := .null, stderr := .null`, waits, then reads/deletes the files. No pipes, no dedicated
  drain threads, no `LiveChild.stdoutTask/stderrTask`, no pipe-block hazard the code comments keep referencing.
- Per-target temp files (`setup.json`, `.lean`, `.out`, `.err`) are deleted immediately after the envelope is decoded,
  not in the run-end `finally`.
- Registry/`LiveChild` shrinks to `child + pgid` (kill/reap bookkeeping only).

### B. Publish each formatted file immediately (per-file atomicity)

- In the writing-`format` worker path, replace the `PendingFormat` accumulation with an immediate `publishAtomic` per
  admitted file — the identical guarded write `fixFile` performs (stale check, temp+rename, per-file rollback). Status
  flow mirrors `fix`: `formatted` + `written := true` on success, `rejected` with the publish diagnostic on
  stale/publish failure — scoped to that file only.
- Delete `pendingFormats`, the `batchReady` gate, `publishBatchAtomic`, and `StagedPublication` (dead surface after the
  switch).
- `format --check` and non-writing modes are untouched (they never reach this code).

## Files to modify

- `LeanFmt/Application.lean` —
  - spawn: `ExactRun.spawnChild` (~333) and `runChild` (~298) — `.null` stdio, no drain tasks; `LiveChild` (~149)
    shrinks to `child + pgid`; the spawn args at ~432 gain the out-path argument.
  - `ExactRun.envelope` (~410) — per-target `{index}.out`/`{index}.err` read-then-delete, plus
    `{index}.setup.json`/`{index}.lean` deletion after decode.
  - child entry: `runAnalyzeChild`, dispatched at ~2399 on `"__analyze-exact"` — accept an optional trailing out-path;
    **no argument = current stdout behavior**, so the direct test callers (`tests/Suites/Lossless.lean`,
    `Semantic.lean`, `Performance.lean`, `Check.lean`, `tests/Test/{Analyze,Oracle}.lean`) keep working unchanged.
  - publish: delete `PendingFormat` (~1286), the `batchReady` gate and `pendingFormats` loop (~1729–1765),
    `publishBatchAtomic` (~893), `StagedPublication` (~888); the writing worker publishes via `publishAtomic`.
- `tests/Suites/Scale.lean` or `tests/Suites/ApplicationFormatter.lean` — regression gates (below).

## Reuse

- `publishAtomic` (Application.lean ~860) — per-file guarded publish, already used by `fixFile` (~1207) and `organize`.
- `publishAtomic`'s stale-source check replaces the batch-level "source changed after analysis" sweep with the same
  check, per file.
- `IO.FS.createTempDir`/`withExactRun` bracket stays as the backstop cleanup; per-target deletion just makes it nearly
  empty at run end.
- Existing suite patterns: `tests/Suites/Scale.lean` (infra-failure assertions, :73),
  `tests/Suites/ApplicationFormatter.lean` (:161).

## Steps

- [ ] Child CLI: accept out/err file arguments; write envelope to file, diagnostics to err file
- [ ] Parent `envelope`/`spawnChild`/`runChild`: spawn with `.null` stdio, drop pipe drain
      tasks, read+delete per-target temp files after decode; shrink `LiveChild`
- [ ] Writing `format`: publish per file via `publishAtomic`; delete `PendingFormat`,
      `batchReady`, `publishBatchAtomic`, `StagedPublication`
- [ ] Update stale comments referencing the pipe-block lesson / deferred publication
- [ ] Regression: fd gate — N (≥ 100) synthetic targets at `--workers 4`, assert parent fd
      count stays within a small constant of its start (count via `/dev/fd` or `lsof`)
- [ ] Regression: fixture with one elaboration-broken file among K formattable files →
      `format` writes K−1, reports exactly one `broken`/`rejected`, no
      "batch was not published" diagnostics anywhere
- [ ] `lake build && lake test && lake lint`

## Verification

- `lake build && lake test` in lean-fmt.
- Re-run the measurement on kan-proofs at default workers: parent PIPE count must stay ≈ bounded (≈ 0 after the pipe
  removal) across the whole run; previously +2/child.
- Full `lean-fmt format` on kan-proofs (user side): no `infrastructure_failures` from EMFILE; `GlobalMinimalModel.lean`
  (genuinely broken) is the *only* unpublished file; `rejected` ≈ small, `written` ≈ 1200+.
- Report stays byte-identical at any `--workers N` (existing invariant; the CLI advertises it).
