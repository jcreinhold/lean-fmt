/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import Std.Sync.Mutex
import Init.System.IO

/-!
# Batch progress display

A tqdm-style progress line for batch commands (`check`, `format`, `diff`, `fix`) over many
files. Cold runs spend minutes in the batch loop; this module shows how far along one is.

The display renders on **stderr only**, as a single carriage-return-rewritten line, so stdout —
including a `--json` report — is never touched. It is inert unless stderr is a TTY: `start`
makes that decision once, and every later call costs one boolean check. `NO_COLOR` does not
gate it because the line carries no color, only a unicode bar and one erase-to-EOL sequence.

The public surface is three operations — `start`, `advance`, `finish`. Rendering, throttling,
and the worker-lock stay inside; callers pass the value through and never branch on whether it
is live.
-/

namespace LeanFmt.Progress

/-- One progress display's mutable state. The fields are private to the module: callers hold
the `Progress` handle and never read them. -/
structure State where
  label : String
  total : Nat
  done : Nat := 0
  /-- Nanoseconds at `start`, for rate and ETA. -/
  started : Nat
  /-- Last redraw, for throttling. -/
  lastDraw : Nat := 0

/-- A progress display. When `live?` is false every operation is a no-op; `state` is unused. -/
structure Progress where private mk ::
  live? : Bool
  state : IO.Ref State
  lock : Std.Mutex Unit

/-- Milliseconds between redraws. Faster than this the terminal cannot keep up and the writes
cost more than the information they carry. -/
private def throttleMs : Nat :=
  80

/-- Bar width in cells. -/
private def barWidth : Nat :=
  20

/-- `mm:ss` for a nanosecond duration. -/
private def clockOf (nanos : Nat) : String :=
  let secs := nanos / 1_000_000_000
  s!"{secs / 60}:{pad2 (secs % 60)}"
where pad2 (n : Nat) : String := if n < 10 then s!"0{n}" else toString n

/-- Tenths of a unit, truncated: `tenths 82 10 = "8.2"`. -/
private def tenths (num den : Nat) : String :=
  if den == 0 then "0.0" else s!"{num / den}.{num % den * 10 / den}"

/-- The rendered line for a state at `now` nanoseconds. Pure, so the unit tier can pin the
format without a terminal. -/
def renderLine (label : String) (done total startedNanos nowNanos : Nat) (item : String) : String :=
  let elapsed := nowNanos - startedNanos
  let pct := if total == 0 then 100 else done * 100 / total
  let filled := if total == 0 then barWidth else done * barWidth / total
  let bar := String.ofList (List.replicate filled '█' ++ List.replicate (barWidth - filled) '░')
  let rate := tenths (done * 1_000_000_000) elapsed
  let eta := if done == 0 then "--:--" else clockOf ((total - done) * elapsed / done)
  let tail := if item.isEmpty then "" else " " ++ item
  s!"{label} {pct}%|{bar}| {done}/{total} [{clockOf elapsed}<{eta}, {rate}it/s]{tail}"

/-- Start a display for `total` items under `label`. Live only when stderr is a TTY and
`TERM` is not `dumb`; inert otherwise. -/
def start (label : String) (total : Nat) : IO Progress := do
  let tty ← (← IO.getStderr).isTty
  let term ← IO.getEnv "TERM"
  let live? := tty && term != some "dumb" && total > 0
  let now ← IO.monoNanosNow
  return { live?, state := ← IO.mkRef { label, total, started := now }, lock := ← Std.Mutex.new () }

/-- Record one finished item, identified by `item` (a path). Redraws at most once per
`throttleMs`, except on the final item. Safe to call from concurrent worker tasks. -/
def advance (progress : Progress) (item : String) : IO Unit := do
  unless progress.live? do
    return
  progress.lock.atomically do
      let now ← IO.monoNanosNow
      progress.state.modify fun s => { s with done := s.done + 1 }
      let s ← progress.state.get
      if s.done == s.total || now - s.lastDraw >= throttleMs * 1_000_000 then
        progress.state.modify fun s => { s with lastDraw := now }
        IO.eprint s!"\r{renderLine s.label s.done s.total s.started now item}\x1b[K"

/-- Finish the display: erase the line. The final report that follows owns stderr from here. -/
def finish (progress : Progress) : IO Unit := do
  unless progress.live? do
    return
  IO.eprint "\r\x1b[K"

end LeanFmt.Progress
