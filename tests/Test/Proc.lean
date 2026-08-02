module

public import Test.Harness

/-!
# Process spawning for suites

Every suite drives the real product binary — that is the point of a suite — so the spawn wrapper
lives here once instead of being re-derived per suite from `IO.Process.output` plus a bash
`run_expect`. `runProc` captures; `expectExit` captures and asserts, naming the label the suite
gave the invocation so a failure reads as the behavior that broke, not as a line number.

The optional timeout is a kill, not a deadline hint: a hung child would otherwise hang the whole
sweep, and the stream/LSP suites test children that are *supposed* to finish.
-/

namespace LeanFmt.Test

/-- Search-path and library-path variables every child loses unless the caller puts one back.
`lake test` exports the host repository's paths, and any child that reads them inherits the
host's build state as its own — the cache suite's epoch folded the host's traces in, and a
stale restored build on a CI leg rewrote one mid-run and turned the suite red on four
platforms' worth of evidence-hunting before the epoch log named it. The host environment is a
volatile decision, so it is hidden here, once: suites get a clean search path by default, and
the only way to see a host path is to re-inject the variable at the call site — which the
boundary suite's `spawn-scrub-opt-ins` case then requires to be on its enumerated list. -/
public def scrubbedSearchPaths : Array (String × Option String) :=
  #[("LEAN_PATH", none), ("LEAN_SRC_PATH", none), ("LD_LIBRARY_PATH", none),
    ("DYLD_LIBRARY_PATH", none)]

/-- The captured result of one child process. -/
public structure ProcResult where
  exitCode : UInt32
  stdout : String
  stderr : String

/-- Run `cmd` to completion, capturing both streams. `env` entries modify (or, with `none`, remove)
inherited variables; they apply *after* `scrubbedSearchPaths`, so passing one of those variables
back is the deliberate opt-out of the scrub. With `timeoutMs`, the child is killed when it
outlives the budget and the error says so — a timeout is a test failure with a clear cause, not
a silent 137. -/
public def runProc (cmd : String) (args : Array String := #[]) (input? : Option String := none)
    (cwd? : Option System.FilePath := none) (env : Array (String × Option String) := #[])
    (timeoutMs : Option Nat := none) : IO ProcResult := do
  let env := scrubbedSearchPaths ++ env
  match timeoutMs with
  | none =>
    let output ← IO.Process.output { cmd, args, cwd := cwd?, env } input?
    return { exitCode := output.exitCode, stdout := output.stdout, stderr := output.stderr }
  | some budget =>
    -- `stdin` is always piped so the child's type does not depend on `input?`; with no input the
    -- handle is dropped unwritten, the same EOF `.null` would give.
    let child ←
      IO.Process.spawn
          { cmd, args, cwd := cwd?, env
            stdin := .piped
            stdout := .piped
            stderr := .piped }
    let (stdin, child) ← child.takeStdin
    if let some input := input? then
      -- Written before the read tasks start, as `IO.Process.output` does it: the harness feeds
      -- children small buffers. A suite moving megabytes of stdin spawns its own writer task.
      stdin.putStr input
      stdin.flush
    let stdoutTask ← IO.asTask child.stdout.readToEnd Task.Priority.dedicated
    let stderrTask ← IO.asTask child.stderr.readToEnd Task.Priority.dedicated
    let rec pollAux : Nat → IO UInt32
      | 0 => do
        child.kill
        discard <| child.wait
        throw <|
            IO.userError
              s!"process did not finish within {budget}ms and was killed: \
          {cmd} {" ".intercalate args.toList}"
      | remaining + 1 => do
        if let some code← child.tryWait then
          return code
        IO.sleep 20
        pollAux remaining
    let exitCode ← pollAux (budget / 20 + 1)
    let stdout ← IO.ofExcept stdoutTask.get
    let stderr ← IO.ofExcept stderrTask.get
    return { exitCode, stdout, stderr }

/-- `runProc` plus the exit-code assertion every suite makes. On mismatch the error carries both
captured streams — the first thing a debugging run needs is what the child actually said. -/
public def expectExit (expected : UInt32) (label : String) (cmd : String)
    (args : Array String := #[]) (input? : Option String := none)
    (cwd? : Option System.FilePath := none) (env : Array (String × Option String) := #[])
    (timeoutMs : Option Nat := some 600000) : IO ProcResult := do
  let result ← runProc cmd args input? cwd? env timeoutMs
  ensure (result.exitCode == expected)
      s!"{label}: expected exit {expected}, \
    got {result.exitCode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
  return result

/-- Assert that a captured stream contains `needle`, printing the whole stream when it does not —
the suite's `grep -q` replaced, with the full text on failure instead of grep's silence. -/
public def ensureContains (haystack : String) (needle : String) (label : String) : IO Unit :=
  ensure (haystack.contains needle) s!"{label}: output does not contain {repr needle}\n{haystack}"

end LeanFmt.Test
