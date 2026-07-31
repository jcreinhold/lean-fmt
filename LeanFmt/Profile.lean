/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import Std.Sync.Mutex

/-!
# The profile channel

`LEAN_FMT_PROFILE_PHASES=1` turns on a stderr diagnostic channel carrying `phase.<name>_ms=<n>` and
`cache.<name>=<n>` records. `tests/Suites/Performance.lean` is the schema in force: which names exist,
what each brackets, and the completeness gate they answer to.

This is a diagnostic channel, not a reporting surface: off by default, writes to stderr, never
enters `RunReport`, and no exit code depends on it. Nothing gated on it may allocate into, order, or
short-circuit production work — it reads clocks that already tick and counters that already exist.

## Why this is its own module

It began inside `LeanFmt.Application`, where the first phases were. It then needed to bracket
`LeanFmt.Project.exactSetup`, which `Application` imports — a phase cannot be emitted from below the
module that owns the emitter. The channel is infrastructure for every layer, so it is a leaf every
layer may import.

Deliberately **not** in `LeanFmt.Basic`. `lakefile.lean` globs `Basic` into `LeanFmtCompilerPlugin`,
which links into every compilation of every module of an integrating project; a diagnostic living
there makes editing a timer invalidate every integrated module's Lake trace. Nothing globs this
module, and nothing in the plugin's import closure reaches it, so it stays out of that closure the
way `LeanFmt.Rules` had to.

**A phase name may be emitted many times in one run.** Per-file phases report per file; the consumer
sums by name. Emitting one total instead would need
an accumulator threaded through the analysis path — profiling state in the type of every operation
that has nothing to do with profiling.
-/

namespace LeanFmt.Internal.Profile

/-- Serializes emission. With `--workers N` several workers bracket phases concurrently, and two
unsynchronized `IO.eprintln` calls may interleave bytes inside a line, and the gates parse lines. The
lock is taken only when the channel is on; production runs pay nothing. -/
initialize emitLock : Std.BaseMutex ←
  Std.BaseMutex.new

/-- Write one record line, whole. `LEAN_FMT_PROFILE_OUT` redirects the line to a file (appended)
instead of stderr: the batch's exact-frontend children run with null stderr — their envelopes and
diagnostics travel on per-target files — and the parent points this variable at the target's
diagnostics file so the child's records still reach the channel. Read per emission, like
`enabled`. -/
private def emit (line : String) : IO Unit := do
  emitLock.lock
  try
    match ← IO.getEnv "LEAN_FMT_PROFILE_OUT" with
    | some path =>
      let handle ← IO.FS.Handle.mk path IO.FS.Mode.append
      handle.putStr (line ++ "\n")
    | none =>
      IO.eprintln line
  finally
    emitLock.unlock

/-- Whether the channel is on.

Read per emission rather than cached in a global. The cost is one `getenv` against a phase measured
*because* it is expensive, and a cached flag would need mutable module state that outlives every
operation here. -/
def enabled : IO Bool :=
  return (← IO.getEnv "LEAN_FMT_PROFILE_PHASES") == some "1"

/-- Report `nanos` under `name`, in milliseconds. -/
def recordDuration (name : String) (nanos : Nat) : IO Unit := do
  if ← enabled then
    emit s!"phase.{name}_ms={nanos / 1000000}"

/-- Report the interval between two `IO.monoNanosNow` readings under `name`. -/
def recordPhase (name : String) (started finished : Nat) : IO Unit :=
  recordDuration name (finished - started)

/-- Report a count under `name`.

Wall time alone cannot distinguish "the cache worked" from "the OS page cache was warm".
Every claim about invalidation is reported as a count. -/
def recordCount (name : String) (value : Nat) : IO Unit := do
  if ← enabled then
    emit s!"cache.{name}={value}"

/-- Run `action` and report how long it took under `name`.

The duration is reported even when `action` throws: a phase reporting only on success would hide
exactly the failure whose cost is worth knowing, and the exact frontend child can fail after spending
its whole budget. -/
def withPhase (name : String) (action : IO α) : IO α := do
  let started ← IO.monoNanosNow
  try
    action
  finally
    recordDuration name ((← IO.monoNanosNow) - started)

end LeanFmt.Internal.Profile
