/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.Discovery

open System

namespace LeanFmt.Internal.Watch

/-! # Bounded filesystem observation

The private observer behind `watch`. It owns polling, debouncing, and the two retained snapshots
that make coalescing bounded — and nothing else. It never runs an analysis, never renders, and never
decides what a generation *does*: the caller supplies that as an action, so execution stays in
`LeanFmt.Application` and rendering in `LeanFmt.Cli`.

**Why polling.** `Std.Internal.UV` binds Signal, Timer, TCP, UDP, DNS and System, and not
`uv_fs_event`/`uv_fs_poll`; no `inotify`/`FSEvents`/`kqueue` appears anywhere in `Init/` or `Std/`
(`evidence/01-watch-baseline.md` §1). The binding is missing, not the platform capability, so no
amount of `Std.Async` reaches it. We considered an external watcher and rejected it: `CLAUDE.md`
requires a *measured* benefit, and the walk costs a small fraction of a generation (§1).

**Why this is bounded without a queue.** There is no event queue to overflow. The observer holds two
values: the snapshot a generation last ran on, and the latest snapshot observed. A burst of events
collapses into one differing snapshot and produces one following generation, so the retained state is
O(selected files) — the project itself — with no bound to tune, no drop policy, and no backpressure
rule (§5).
-/

/-! ## The change signal

`(relative path, byteSize, mtime.sec, mtime.nsec)` over the files `LeanFmt.Project` selects, plus the
control files of §6.

Nanoseconds carry real values: repeated writes inside one wall-clock second produce distinct stamps,
and a same-size rewrite stays distinguishable (`evidence` §2), so detection needs no content digest.

**This bounds latency, never correctness.** On a filesystem with coarse `mtime` granularity a
same-second same-size edit can produce an identical tuple and be missed by that poll. A generation
re-reads and re-digests every source it reports on, and the result cache is keyed on content, so a
stale tuple can delay a generation but cannot produce a report that disagrees with the bytes on disk.
Any later detected change re-runs the complete project and picks the missed edit up. Nothing here
guarantees that every edit is observed, and no caller may claim it does. -/

private structure Stamp where
  path : String
  /-- Absent when the file does not exist. Absence is itself observable, so that *creating* a config
  file — which changes no existing file's tuple — still starts a generation (§6). -/
  present : Bool
  byteSize : UInt64
  seconds : Int
  nanoseconds : UInt32
  deriving BEq

/-- One observation of the tree. Compared as a whole: a file appearing or disappearing changes the
set, which is why creation and deletion need no separate mechanism (§2). -/
structure Snapshot where private mk ::
  private stamps : Array Stamp
  deriving BEq

/-- How many paths this observation covers. Reported so a caller can show what it is watching without
being handed the stamps themselves. -/
def Snapshot.size (snapshot : Snapshot) : Nat :=
  snapshot.stamps.size

private def stampOf (root : FilePath) (relative : String) : IO Stamp := do
  try
    let metadata ← (root / FilePath.mk relative).metadata
    return {
        path := relative
        present := true
        byteSize := metadata.byteSize
        seconds := metadata.modified.sec
        nanoseconds := metadata.modified.nsec }
  catch _ =>
    return { path := relative, present := false, byteSize := 0, seconds := 0, nanoseconds := 0 }

/-! ## What is observed besides sources

A generation's meaning depends on inputs that are not themselves Lean sources (§6). Editing a config
file changes which rules run; editing a lakefile changes the project. Both must start a generation
even though neither is a source. -/

/-- Recognized configuration filenames, in precedence order. -/
private def configNames : Array String :=
  #[".lean-fmt.toml", "lean-fmt.toml"]

/-- Root-relative control files whose change invalidates a retained workspace (§6). -/
private def lakeControlNames : Array String :=
  #["lakefile.lean", "lakefile.toml", "lake-manifest.json", "lean-toolchain"]

/-- Every ancestor directory of `path`, root-relative, nearest-last, including the root itself.

A configuration governs files beneath it, so a config *created* in any ancestor of a selected source
changes that source's effective configuration. Observing the recognized names in exactly these
directories makes such a creation detectable while keeping the observed set finite — a config in a
directory with no sources beneath it governs nothing, and is correctly ignored. -/
private def ancestors (path : String) : Array String :=
  Id.run do
    let components := (path.splitOn "/").dropLast
    let mut directories : Array String := #[""]
    let mut current := ""
    for component in components do
      current := if current.isEmpty then component else current ++ "/" ++ component
      directories := directories.push current
    return directories

/-- The complete set of root-relative paths one observation covers.

Recomputed from a fresh `Discovery.run` on every poll rather than cached: the selected set is itself
a function of the tree, so a new file, a new config, or a changed `exclude` has to be able to change
what we watch. The walk costs a small fraction of a generation (§1), which is what makes recomputing
it affordable. -/
private def observedPaths (root : FilePath) (configPath? : Option FilePath) : IO (Array String) :=
  do
  let discovery ← Discovery.run root configPath?
  let sources := discovery.selectedSources
  let mut paths := sources
  let mut directories : Array String := #[]
  for source in sources do
    for directory in ancestors source do
      unless directories.contains directory do
        directories := directories.push directory
  for directory in directories do
    for name in configNames do
      let candidate := if directory.isEmpty then name else directory ++ "/" ++ name
      unless paths.contains candidate do
        paths := paths.push candidate
  for name in lakeControlNames do
    unless paths.contains name do
      paths := paths.push name
  -- An explicit `--config` need not sit inside the root, and it governs the whole run.
  if let some explicit := configPath? then
    let text := explicit.toString
    unless paths.contains text do
      paths := paths.push text
  return paths

/-- Observe the tree once. -/
def observe (root : FilePath) (configPath? : Option FilePath) : IO Snapshot := do
  let paths ← observedPaths root configPath?
  let stamps ← paths.mapM (stampOf root)
  return { stamps }

/-! ## The loop -/

structure Options where
  root : FilePath
  configPath? : Option FilePath := none
  /-- Poll interval. The default sits above the discovery walk, so polling never occupies much of a
  core, and well below a generation, so it never dominates observed latency. Polling faster cannot
  make feedback faster; only a faster generation can (§1). -/
  pollMillis : Nat := 200

/-- Run `generation` once immediately, then once after each settled change, forever.

`generation` receives a 1-based counter, which is presentation only: identity is the observed snapshot
(§3). It is run to completion before the next observation is compared, so generations are strictly
sequential and one complete report is emitted at a time — the roadmap's completion contract.

**Coalescing.** After a difference is first seen, the loop waits until one poll interval passes with
the snapshot unchanged before running. That collapses a multi-file save, a branch checkout, or an
editor's write-temp-then-rename into one generation rather than several (§5).

**Superseded work is still emitted.** A generation whose snapshot went stale while it ran is reported,
then immediately followed by the next. Its report is not wrong — it is a true report about the bytes
it read — and suppressing it would leave a user who has stopped typing staring at nothing. Cancelling
a running generation is deliberately out of scope: `execute` offers no cancellation point that would
leave the result cache consistent (§5, §11). -/
partial def run (options : Options) (generation : Nat → IO Unit) : IO Unit := do
  let initial ← observe options.root options.configPath?
  generation 1
  loop initial 2
where
   loop (lastRun : Snapshot) (counter : Nat) : IO Unit := do
    IO.sleep options.pollMillis.toUInt32
    let observed ← observe options.root options.configPath?
    if observed == lastRun then
      loop lastRun counter
    else
      -- Quiet-period debounce: wait for the tree to settle so a multi-file change is one generation.
      let settled ← settle observed
      generation counter
      loop settled (counter + 1)
   settle (candidate : Snapshot) : IO Snapshot := do
    IO.sleep options.pollMillis.toUInt32
    let observed ← observe options.root options.configPath?
    if observed == candidate then
      return observed
    else
      settle observed

end LeanFmt.Internal.Watch
