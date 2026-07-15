import Lean
import Lean.Elab.Import

/-!
Measure what happens when one Lean process constructs and drops many exact import environments.

This deliberately uses the ordinary full `Elab.processHeader` path with extensions loaded. It does
not retain an `Environment` and does not call the unsafe `Environment.freeRegions`: the experiment
is testing whether the ordinary ownership path actually reclaims the imported mappings.
-/

open Lean Lean.Elab Lean.Parser

private def rssKiB : IO Nat := do
  let pid ← IO.Process.getPID
  let output ← IO.Process.output {
    cmd := "/bin/ps"
    args := #["-o", "rss=", "-p", toString pid]
  }
  if output.exitCode != 0 then
    throw <| IO.userError s!"ps failed: {output.stderr.trimAscii}"
  match output.stdout.trimAscii.toNat? with
  | some value => pure value
  | none => throw <| IO.userError s!"invalid ps RSS output: {output.stdout}"

private def mappedKiB (env : Environment) : Nat :=
  env.header.regions.foldl (init := 0) fun total region =>
    total + region.size.toNat / 1024

private structure Observation where
  status : String
  imports : Nat
  regions : Nat
  mappedKiB : Nat
  messages : Nat

private unsafe def processHeaderOnly (path : System.FilePath) : IO Observation := do
  let source ← IO.FS.readFile path
  let input := Parser.mkInputContext source path.toString
  let (header, _, headerMessages) ← Parser.parseHeader input
  if headerMessages.hasErrors then
    return {
      status := "header_error"
      imports := 0
      regions := 0
      mappedKiB := 0
      messages := headerMessages.toArray.size
    }
  Lean.enableInitializersExecution
  let (env, messages) ← Elab.processHeader header {} headerMessages input
  let status := if messages.hasErrors then "import_error" else "ok"
  return {
    status
    imports := Elab.headerToImports header |>.size
    regions := env.header.regions.size
    mappedKiB := mappedKiB env
    messages := messages.toArray.size
  }

private def printObservation (index : Nat) (path : String) (before after : Nat)
    (elapsedMs : Nat) (observation : Observation) : IO Unit :=
  IO.println <| String.intercalate "\t" [
    toString index,
    path,
    observation.status,
    s!"imports={observation.imports}",
    s!"regions={observation.regions}",
    s!"mapped_kib={observation.mappedKiB}",
    s!"messages={observation.messages}",
    s!"rss_before_kib={before}",
    s!"rss_after_kib={after}",
    s!"elapsed_ms={elapsedMs}"
  ]
  (← IO.getStdout).flush

unsafe def main (args : List String) : IO UInt32 := do
  if args.isEmpty then
    IO.eprintln "usage: ImportProbe FILE..."
    return 2
  IO.println "index\tfile\tstatus\timports\tregions\tmapped_kib\tmessages\trss_before_kib\trss_after_kib\telapsed_ms"
  (← IO.getStdout).flush
  for path in args, index in [0:args.length] do
    let before ← rssKiB
    let started ← IO.monoMsNow
    let observation ← processHeaderOnly path
    let elapsed := (← IO.monoMsNow) - started
    let after ← rssKiB
    printObservation index path before after elapsed observation
  return 0
