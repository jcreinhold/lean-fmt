import Lean
import LeanFmt.Source

/-!
# LeanFmt.Frontend

The source-snapshot parse command of the `LeanFmt` worker capability. It exposes a
single request/response export, `lean_fmt_parse_file`, that parses an in-memory Lean
source string with the imports declared in its own header and returns parse
diagnostics plus a lightweight syntax summary — **without elaborating**.

The flow mirrors `lean-rs-host-shims`' `buildModuleSnapshot`
(`InfoTree.lean`), specialized to a self-contained `String → IO String` JSON command
(the metadata/doctor export shape) rather than a function receiving a pre-loaded
`Environment`:

* `Lean.Parser.mkInputContext` + `Lean.Parser.parseHeader` split the header from the
  body and report header parse errors;
* `Lean.Elab.headerToImports` derives the declared imports;
* `Lean.initSearchPath` (sysroot + caller-supplied project build dirs) then
  `Lean.Elab.processHeader` builds a command environment carrying the imported
  parser/notation extensions — the step that makes import-dependent syntax parse;
* a parse-only loop over `Lean.Parser.parseCommand` against a `ParserModuleContext`
  built from that environment collects the top-level commands and parse messages,
  paying no elaboration cost;
* diagnostics are rendered from the `MessageLog` following `Elaboration.lean`'s
  `serializeMessages` pattern.

When an imported module cannot be resolved on the search path, the command **degrades
gracefully**: it reports the import errors as diagnostics, returns
`status = "degraded"`, and still delivers a best-effort parse, rather than crashing the
worker across the ABI. Per-request environment setup is the baseline here; per-project
environment caching is a later concern.
-/

namespace LeanFmt.Frontend

open Lean Lean.Parser Lean.Elab

/-- Default file label used when the request omits `file`. -/
private def defaultFileLabel : String := "<snapshot>"

/-- Byte budget for the serialized diagnostics body, keeping a pathological error
    storm from ballooning the response. -/
private def diagnosticByteLimit : Nat := 64 * 1024

/-- Parsed request fields. `imports` is informational (the authoritative import set is
    derived from the parsed header); `sysroot`/`searchPath` seed `initSearchPath`. -/
private structure ParseRequest where
  file : String
  source : String
  sysroot : Option String
  searchPath : List String

/-- Read a string field, falling back to `dflt` when absent or not a string. -/
private def getStr (obj : Json) (field : String) (dflt : String) : String :=
  (obj.getObjValAs? String field).toOption.getD dflt

/-- Decode the request envelope. Only `source` is required. -/
private def decodeRequest (requestJson : String) : Except String ParseRequest := do
  let json ← Json.parse requestJson
  let source ← json.getObjValAs? String "source"
    |>.mapError (fun _ => "request is missing a string `source` field")
  let file := getStr json "file" defaultFileLabel
  let options := (json.getObjVal? "options").toOption.getD Json.null
  let sysroot := (options.getObjValAs? String "sysroot").toOption
  let searchPath : List String :=
    match (options.getObjValAs? (Array String) "search_path").toOption with
    | some arr => arr.toList
    | none => []
  .ok { file, source, sysroot, searchPath }

/-- Map a `MessageSeverity` to its lowercase JSON tag. -/
private def severityTag : MessageSeverity → String
  | .information => "info"
  | .warning => "warning"
  | .error => "error"

/-- Render a `MessageLog` as a JSON array of diagnostics, bounding the cumulative
    message-body bytes at `diagnosticByteLimit`. Mirrors `serializeMessages`. -/
private def renderDiagnostics (msgs : MessageLog) (fallbackLabel : String) :
    IO (Array Json × Bool) := do
  let mut out : Array Json := #[]
  let mut bytes : Nat := 0
  let mut truncated := false
  for m in msgs.toArray do
    if out.size > 0 && bytes ≥ diagnosticByteLimit then
      truncated := true
      break
    let body ← m.data.toString
    let label := if m.fileName.isEmpty then fallbackLabel else m.fileName
    let mut fields : List (String × Json) :=
      [ ("severity", Json.str (severityTag m.severity))
      , ("message", Json.str body)
      , ("file", Json.str label)
      , ("line", toJson m.pos.line)
      , ("column", toJson m.pos.column) ]
    if let some endPos := m.endPos then
      fields := fields ++ [("end_line", toJson endPos.line), ("end_column", toJson endPos.column)]
    out := out.push (Json.mkObj fields)
    bytes := bytes + body.utf8ByteSize
  pure (out, truncated)

/-- Everything the parse-only command loop harvests from the body. -/
private structure BodyParse where
  /-- Per-kind top-level command counts. -/
  kinds : Array (Name × Nat)
  /-- Per-command byte-anchored `SyntaxRegion`s. -/
  regions : Array Json
  /-- Byte spans of every parsed token in the body (for the trivia complement). -/
  tokenSpans : Array (Nat × Nat)
  /-- Byte ranges of `docComment` nodes in the body. -/
  docstrings : Array Json
  /-- The accumulated parse message log. -/
  messages : MessageLog

/-- The parse-only command loop: fold `parseCommand` over the body, collecting the
    per-kind command counts, the per-command byte-anchored `SyntaxRegion`s, the token
    spans (for the trivia model), the docstring spans, and the parse message log. -/
private def parseCommands (inputCtx : Parser.InputContext) (env : Environment)
    (startState : Parser.ModuleParserState) (initialMessages : MessageLog) :
    BodyParse := Id.run do
  let mctx : Parser.ParserModuleContext := { env, options := {} }
  let mut state := startState
  let mut messages := initialMessages
  let mut kinds : Array (Name × Nat) := #[]
  let mut regions : Array Json := #[]
  let mut tokenSpans : Array (Nat × Nat) := #[]
  let mut docstrings : Array Json := #[]
  repeat
    let (stx, state', messages') := Parser.parseCommand inputCtx mctx state messages
    state := state'
    messages := messages'
    if Parser.isTerminalCommand stx then
      break
    let kind := stx.getKind
    kinds :=
      match kinds.findIdx? (fun (k, _) => k == kind) with
      | some idx =>
        match kinds[idx]? with
        | some (_, n) => kinds.set! idx (kind, n + 1)
        | none => kinds
      | none => kinds.push (kind, 1)
    if let some region := LeanFmt.Source.commandRegion inputCtx.fileMap stx then
      regions := regions.push region
    tokenSpans := LeanFmt.Source.tokenSpans stx tokenSpans
    docstrings := LeanFmt.Source.docCommentSpans stx docstrings
  pure { kinds, regions, tokenSpans, docstrings, messages }

/-- Build the `syntax_summary` JSON object from per-kind command counts and the
    per-command byte-anchored `SyntaxRegion`s. -/
private def syntaxSummary (kinds : Array (Name × Nat)) (regions : Array Json) : Json :=
  let total : Nat := kinds.foldl (fun acc (_, n) => acc + n) 0
  let kindObjs := kinds.map fun (k, n) => Json.mkObj [("kind", Json.str k.toString), ("count", toJson n)]
  Json.mkObj
    [ ("command_count", toJson total)
    , ("command_kinds", Json.arr kindObjs)
    , ("command_regions", Json.arr regions) ]

/-- The `source_model` object: trivia runs (inter-token byte ranges) and docstring
    spans. Empty when the parse never reached the body (header error / degrade). -/
private def sourceModel (triviaRuns : Array Json) (docstrings : Array Json) : Json :=
  Json.mkObj
    [ ("trivia_runs", Json.arr triviaRuns)
    , ("docstrings", Json.arr docstrings) ]

/-- Assemble the response envelope. `importSpans` carries one `{module, range}` record
    per `import` statement (byte-anchored), empty when the header never parsed cleanly. -/
private def mkResponse (status : String) (diagnostics : Array Json) (truncated : Bool)
    (imports : List String) (isModule : Bool) (importSpans : Array Json)
    (summary : Json) (srcModel : Json) : String :=
  Json.mkObj
    [ ("status", Json.str status)
    , ("diagnostics", Json.arr diagnostics)
    , ("diagnostics_truncated", Json.bool truncated)
    , ("module_header", Json.mkObj
        [ ("imports", Json.arr ((imports.map Json.str).toArray))
        , ("is_module", Json.bool isModule)
        , ("import_spans", Json.arr importSpans) ])
    , ("syntax_summary", summary)
    , ("source_model", srcModel) ]
    |>.compress

/-- Core parse routine over an already-decoded request. -/
private def runParse (req : ParseRequest) : IO String := do
  -- Seed the module search path so `processHeader` can resolve the header's imports.
  if let some sysroot := req.sysroot then
    Lean.initSearchPath sysroot (req.searchPath.map System.FilePath.mk)
  else if let some sysroot ← IO.getEnv "LEAN_SYSROOT" then
    Lean.initSearchPath sysroot (req.searchPath.map System.FilePath.mk)
  let inputCtx := Parser.mkInputContext req.source req.file
  let (header, parserState, headerMessages) ← Parser.parseHeader inputCtx
  let imports := ((Elab.headerToImports header).map (·.module.toString)).toList.eraseDups
  let isModule := Elab.HeaderSyntax.isModule header
  -- Byte-anchored per-import records, recovered from the parsed header. Reliable only
  -- once the header parses without error; the error branch below reports `#[]`.
  let importSpans := LeanFmt.Source.importSpans header.raw
  -- A header that itself fails to parse is a hard `error`: there is no reliable
  -- import set or body boundary to proceed from.
  if headerMessages.hasErrors then
    let (diags, trunc) ← renderDiagnostics headerMessages req.file
    return mkResponse "error" diags trunc imports isModule #[] (syntaxSummary #[] #[]) (sourceModel #[] #[])
  -- Build the command environment. `processHeader` reports unresolved imports as
  -- error messages (occasionally as a throw); either way we degrade rather than crash.
  let processed : Except MessageLog (Environment × MessageLog) ←
    try
      let result ← (do
        unsafe Lean.enableInitializersExecution
        Elab.processHeader header {} headerMessages inputCtx)
      pure (.ok result)
    catch e =>
      let mut log : MessageLog := {}
      log := log.add { fileName := req.file, pos := ⟨1, 0⟩, data := toString e, severity := .error }
      pure (.error log)
  match processed with
  | .error log =>
    let (diags, trunc) ← renderDiagnostics log req.file
    return mkResponse "degraded" diags trunc imports isModule importSpans (syntaxSummary #[] #[]) (sourceModel #[] #[])
  | .ok (env, importMessages) =>
    let body := parseCommands inputCtx env parserState importMessages
    let (diags, trunc) ← renderDiagnostics body.messages req.file
    -- Trivia runs are the complement of *all* tokens — header (imports/`module`) plus
    -- body — so inter-unit trivia (e.g. a comment between the imports and the first
    -- command) is captured. Docstrings come from both regions too.
    let allTokens := LeanFmt.Source.tokenSpans header body.tokenSpans
    let triviaRuns := LeanFmt.Source.triviaRunsJson req.source.utf8ByteSize allTokens
    let docstrings := LeanFmt.Source.docCommentSpans header body.docstrings
    let srcModel := sourceModel triviaRuns docstrings
    -- `degraded` when imports or body carried errors (e.g. a missing module's parser
    -- extensions were absent, so notation failed to parse); `ok` otherwise.
    let status := if body.messages.hasErrors then "degraded" else "ok"
    return mkResponse status diags trunc imports isModule importSpans (syntaxSummary body.kinds body.regions) srcModel

/--
Request/response export: parse an in-memory Lean source snapshot with the imports
declared in its header and return parse diagnostics plus a lightweight syntax summary.

Request: `{"file"?, "source", "imports"?, "options"?: {"sysroot"?, "search_path"?}}`.
Response: `{"status", "diagnostics", "diagnostics_truncated", "module_header":
{"imports", "is_module", "import_spans"}, "syntax_summary": {"command_count",
"command_kinds", "command_regions"}, "source_model": {"trivia_runs", "docstrings"}}`,
where `import_spans` are per-`import` `{module, range: {start, end}}` records, each
`command_regions` entry is a byte-anchored `SyntaxRegion`
(`{"kind", "range": {"start", "end"}, "line_column": …}`), `trivia_runs` are the
inter-token byte ranges (`{"start", "end"}`) that hold all comments and blank lines,
and `docstrings` are `docComment` node byte ranges.
A malformed request envelope yields a single `error` diagnostic rather than a throw.
-/
@[export lean_fmt_parse_file]
def parseFileCommand (requestJson : String) : IO String := do
  match decodeRequest requestJson with
  | .error msg =>
    let diag := Json.mkObj
      [ ("severity", Json.str "error")
      , ("message", Json.str s!"invalid parse_file request: {msg}")
      , ("file", Json.str defaultFileLabel)
      , ("line", toJson (0 : Nat))
      , ("column", toJson (0 : Nat)) ]
    pure <| mkResponse "error" #[diag] false [] false #[] (syntaxSummary #[] #[]) (sourceModel #[] #[])
  | .ok req => runParse req

end LeanFmt.Frontend
