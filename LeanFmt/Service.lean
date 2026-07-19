module

import all LeanFmt.Application

open System

namespace LeanFmt.Internal.Service

open LeanFmt.Internal LeanFmt.Internal.Application LeanFmt.Internal.Project

def protocolSchema : String := "lean-fmt.service.v1"

def maxLineBytes : Nat := 32 * 1024 * 1024

def maxSourceBytes : Nat := 16 * 1024 * 1024

structure ServeOptions where
  root : FilePath := "."
  maxMemoryGiB : Nat := 8
  configPath? : Option FilePath := none
  select : Array String := #[]
  ignore : Array String := #[]
  /-- Preview mode for the service session (`ruff-12`), unlocking preview rules exactly as `--preview`
  does for a batch run. -/
  preview : Bool := false

inductive Request where
  | health (id : Lean.Json)
  | analyze (id : Lean.Json) (path : String) (version : Nat) (source : String)
  | shutdown (id : Lean.Json)

private def required (json : Lean.Json) (field : String) : Except String Lean.Json :=
  json.getObjVal? field

private def requiredAs (json : Lean.Json) (field : String) (α : Type)
    [Lean.FromJson α] : Except String α := do
  Lean.fromJson? (← required json field)

def decodeRequest (json : Lean.Json) : Except String Request := do
  let id ← required json "id"
  let method ← requiredAs json "method" String
  match method with
  | "health" => return .health id
  | "analyze" =>
    return .analyze id (← requiredAs json "path" String)
      (← requiredAs json "version" Nat) (← requiredAs json "source" String)
  | "shutdown" => return .shutdown id
  | _ => throw s!"unknown method: {method}"

def versionAccepted (latest? : Option Nat) (version : Nat) : Bool :=
  latest?.all (· < version)

private def success (id result : Lean.Json) : Lean.Json :=
  Lean.Json.mkObj [
    ("schema", protocolSchema),
    ("id", id),
    ("ok", true),
    ("result", result)
  ]

private def failure (id : Lean.Json) (code message : String)
    (details : List (String × Lean.Json) := []) : Lean.Json :=
  Lean.Json.mkObj [
    ("schema", protocolSchema),
    ("id", id),
    ("ok", false),
    ("error", Lean.Json.mkObj (("code", code) :: ("message", message) :: details))
  ]

private def requestId (json : Lean.Json) : Lean.Json :=
  (json.getObjVal? "id").toOption.getD .null

private def healthResult (project : Project.Snapshot) : Lean.Json :=
  Lean.Json.mkObj [
    ("method", "health"),
    ("ready", true),
    ("root", project.root.toString),
    ("toolchain", s!"Lean {Lean.versionString} ({project.workspace.lakeEnv.lean.githash})")
  ]

private def analyzeResult (version : Nat) (report : FileReport) : Lean.Json :=
  Lean.Json.mkObj [
    ("method", "analyze"),
    ("path", report.path),
    ("version", version),
    ("status", report.status),
    ("findings", Lean.toJson report.findings),
    ("diagnostics", Lean.toJson report.diagnostics)
  ]

private def writeResponse (stdout : IO.FS.Stream) (response : Lean.Json) : IO Unit := do
  stdout.putStr (response.compress ++ "\n")
  stdout.flush

private structure Step where
  response : Lean.Json
  versions : Std.HashMap String Nat
  shutdown : Bool := false

private def handleRequest (run : ExactRun) (project : Project.Snapshot) (plan : RulePlan)
    (versions : Std.HashMap String Nat) : Request → IO Step
  | .health id =>
    return { response := success id (healthResult project), versions }
  | .shutdown id =>
    return {
      response := success id (Lean.Json.mkObj [("method", "shutdown")])
      versions
      shutdown := true
    }
  | .analyze id requestedPath version source => do
    if source.utf8ByteSize > maxSourceBytes then
      return {
        response := failure id "source-too-large"
          s!"source exceeds {maxSourceBytes} UTF-8 bytes"
        versions
      }
    let some target ← project.findTarget? requestedPath
      | return {
          response := failure id "invalid-path"
            "path must identify an existing selected Lean source inside the project root"
          versions
        }
    let latest? := versions.get? target.relativePath
    unless versionAccepted latest? version do
      return {
        response := failure id "stale-version"
          "version must be strictly greater than the latest accepted version"
          [("latestVersion", Lean.toJson latest?.get!)]
        versions
      }
    let versions := versions.insert target.relativePath version
    try
      let report ← run.checkSnapshot plan (target.withSource source)
      return { response := success id (analyzeResult version report), versions }
    catch error =>
      return {
        response := failure id "analysis-failure" (toString error)
        versions
      }

private partial def loop (run : ExactRun) (project : Project.Snapshot) (plan : RulePlan)
    (stdin stdout : IO.FS.Stream) (versions : Std.HashMap String Nat) : IO UInt32 := do
  let line ← stdin.getLine
  if line.isEmpty then
    return 0
  let step ← if line.utf8ByteSize > maxLineBytes then
    pure {
      response := failure .null "line-too-large" s!"request line exceeds {maxLineBytes} UTF-8 bytes"
      versions
    }
  else
    match Lean.Json.parse line with
    | .error _ =>
      pure { response := failure .null "malformed-json" "request line is not valid JSON", versions }
    | .ok json =>
      match decodeRequest json with
      | .error message =>
        let code := if message.startsWith "unknown method:" then "unknown-method" else "invalid-request"
        pure { response := failure (requestId json) code message, versions }
      | .ok request => handleRequest run project plan versions request
  writeResponse stdout step.response
  if step.shutdown then return 0
  loop run project plan stdin stdout step.versions

/- Start one capacity-one NDJSON service. Project/configuration state and only latest versions are
retained; source bodies and reports are released after each flushed response. The persistent result
cache and all source-writing capabilities are absent from this operation. -/
def serve (options : ServeOptions) : IO UInt32 := do
  unless options.maxMemoryGiB > 0 do
    throw <| IO.userError "--max-memory must provide a nonzero operating envelope"
  let root ← IO.FS.realPath options.root
  let configPath? := options.configPath?.map fun path =>
    if path.isAbsolute then path else root / path
  let config ← FormatterConfig.load root configPath?
  let plan ← match config.rulePlan
      { select := options.select, ignore := options.ignore, preview := options.preview } with
    | .ok plan => pure plan
    | .error message => throw <| IO.userError message
  for notice in plan.notices do IO.eprintln s!"lean-fmt: {notice}"
  let project ← Project.load root config #[]
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  withExactRun project options.maxMemoryGiB fun run =>
    loop run project plan stdin stdout {}

end LeanFmt.Internal.Service
