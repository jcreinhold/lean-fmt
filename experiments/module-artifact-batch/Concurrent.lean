module

private structure Request where
  moduleName : String
  moduleFile : System.FilePath
  output : System.FilePath

private structure Completed where
  index : Nat
  started : Nat
  finished : Nat
  output : IO.Process.Output

private def parseRequest (line : String) : Except String Request :=
  match line.splitOn "\t" with
  | [moduleName, moduleFile, output] => .ok { moduleName, moduleFile, output }
  | _ => .error s!"invalid concurrency manifest row: {line}"

/- Run one ordinary process-isolated extraction. The surrounding Lean task is intentionally the
same scheduler primitive used by `Lake.Job.async`; this probe measures whether the process starts
are bounded by the parent runtime's `LEAN_NUM_THREADS`. Each child is independently fixed at one
Lean thread. -/
private def runOne (extractor : System.FilePath) (index : Nat)
    (request : Request) : IO Completed := do
  let started ← IO.monoMsNow
  let output ← IO.Process.output {
    cmd := extractor.toString
    args := #[request.moduleName, request.moduleFile.toString, request.output.toString]
    env := #[⟨"LEAN_NUM_THREADS", some "1"⟩]
  }
  let finished ← IO.monoMsNow
  return { index, started, finished, output }

private def report (completed : Completed) : IO Unit := do
  IO.println s!"concurrent_item_{completed.index}_started_ms={completed.started}"
  IO.println s!"concurrent_item_{completed.index}_finished_ms={completed.finished}"
  if completed.output.exitCode != 0 then
    throw <| IO.userError s!"concurrent extraction {completed.index} failed: {completed.output.stderr}"

private def maximumOverlap (completed : List Completed) : Nat :=
  completed.foldl (init := 0) fun maximum item =>
    let active := completed.countP fun other =>
      other.started ≤ item.started && item.started < other.finished
    Nat.max maximum active

public def main (args : List String) : IO UInt32 := do
  let [manifest, extractor] := args
    | IO.eprintln "usage: artifact-concurrency-probe MANIFEST EXTRACTOR"
      return 2
  let rows := (← IO.FS.readFile manifest).splitOn "\n" |>.filter (!·.isEmpty)
  IO.println s!"concurrent_configured_threads={(← IO.getEnv "LEAN_NUM_THREADS").getD "unset"}"
  let requests ← rows.mapM fun row =>
    match parseRequest row with
    | .ok request => pure request
    | .error message => throw <| IO.userError message
  let started ← IO.monoMsNow
  let tasks ← requests.zipIdx.mapM fun (request, index) =>
    IO.asTask <| runOne extractor index request
  let completed ← tasks.mapM fun task => do
    match ← IO.wait task with
    | .ok completed => pure completed
    | .error error => throw error
  completed.forM report
  let finished ← IO.monoMsNow
  IO.println s!"concurrent_max_overlap={maximumOverlap completed}"
  IO.println s!"phase.concurrent_total_ms={finished - started}"
  return 0
