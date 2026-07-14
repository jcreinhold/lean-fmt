import Lean
import LeanFmt.Source

/-!
# LeanFmt.Frontend

The source-snapshot parse command of the `LeanFmt` worker capability. It exposes a
single request/response export, `lean_fmt_parse_file`, that parses an in-memory Lean
source string with the imports declared in its own header and returns parse
diagnostics plus a lightweight syntax summary. It is **parse-only by default**: it pays
no elaboration cost. Only when a parse-only body degrades does it retry with *selective
elaboration* (`elaborateCommands`) — elaborating every command except the heavy
declarations and the effectful ones, so file-local notation the file declares itself
(including via downstream commands like mathlib's `notation3`) registers into the parser,
while declaration bodies and their proof-elaboration cost stay untouched.

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
* on a degraded body only, `elaborateCommands` re-runs the loop, elaborating every command
  except the heavy/effectful ones so file-local notation registers into the parser; its
  elaboration messages are discarded, so the reported status still reflects parse
  fidelity alone;
* diagnostics are rendered from the `MessageLog` following `Elaboration.lean`'s
  `serializeMessages` pattern.

When an imported module cannot be resolved on the search path, the command **degrades
gracefully**: it reports the import errors as diagnostics, returns
`status = "degraded"`, and still delivers a best-effort parse, rather than crashing the
worker across the ABI.

By default this command rebuilds the import environment on every request. When a request
carries a `superset_id`, it instead builds the project-wide superset environment once — the
union of every file's imports — retains it in a process-global cell, and parses every file
against it, turning N per-file imports into one import plus N parses. A file whose parse
degrades under that wider grammar (a token or ambiguity introduced by notation it does not
import) is transparently re-parsed against its own imports and marked `fell_back`, so the
result is never worse than the per-file path. `docs/performance.md` explains the cost model
and the memory bound.
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
  /-- Union of every project file's imports. Present only in pinned mode; the worker
      builds this environment once and parses every file against it. -/
  supersetImports : List String
  /-- Stable id of the superset (a hash of the sorted-unique union). `none` selects the
      per-file path; `some id` selects the pinned path and keys the retained environment. -/
  supersetId : Option String

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
  let supersetImports : List String :=
    match (json.getObjValAs? (Array String) "superset_imports").toOption with
    | some arr => arr.toList
    | none => []
  let supersetId : Option String := (json.getObjValAs? String "superset_id").toOption
  .ok { file, source, sysroot, searchPath, supersetImports, supersetId }

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
  /-- Per-declaration header role spans (keyword/name/binders/sig-colon/`:=`/`where`). -/
  declHeaders : Array Json
  /-- Per-`by`-block tactic anchor spans (`by`/seq/first-step/bullets). -/
  tacticBlocks : Array Json
  /-- Byte spans of every parsed token in the body (for the trivia complement). -/
  tokenSpans : Array (Nat × Nat)
  /-- Byte ranges of `docComment` nodes in the body. -/
  docstrings : Array Json
  /-- The accumulated parse message log. -/
  messages : MessageLog

/-- The empty body accumulator: nothing harvested yet, empty message log. -/
private def BodyParse.empty : BodyParse :=
  { kinds := #[], regions := #[], declHeaders := #[], tacticBlocks := #[]
    tokenSpans := #[], docstrings := #[], messages := {} }

/-- Fold one parsed command into the running body accumulator: bump its per-kind count and
    append its `SyntaxRegion`, declaration-header spans, tactic-block spans, token spans, and
    docstring spans. Pure, and shared by the parse-only and selective-elaboration loops, so the
    two can never disagree on the projection the formatter rules consume — only on the parse
    trees they feed it. Leaves `messages` untouched; the caller owns the parse message log. -/
private def absorbCommand (inputCtx : Parser.InputContext) (stx : Syntax)
    (body : BodyParse) : BodyParse :=
  let kind := stx.getKind
  let kinds :=
    match body.kinds.findIdx? (fun (k, _) => k == kind) with
    | some idx =>
      match body.kinds[idx]? with
      | some (_, n) => body.kinds.set! idx (kind, n + 1)
      | none => body.kinds
    | none => body.kinds.push (kind, 1)
  let regions :=
    match LeanFmt.Source.commandRegion inputCtx.fileMap stx with
    | some region => body.regions.push region
    | none => body.regions
  { body with
    kinds
    regions
    declHeaders := LeanFmt.Source.declHeaderSpans stx body.declHeaders
    tacticBlocks := LeanFmt.Source.tacticBlockSpans inputCtx.fileMap stx body.tacticBlocks
    tokenSpans := LeanFmt.Source.tokenSpans stx body.tokenSpans
    docstrings := LeanFmt.Source.docCommentSpans stx body.docstrings }

/-- The parse-only command loop: fold `parseCommand` over the body, collecting via
    `absorbCommand` the per-kind command counts, the per-command byte-anchored `SyntaxRegion`s,
    the token spans (for the trivia model), the docstring spans, and the parse message log. The
    parser context is fixed to the imported environment, so file-local `notation`/`syntax` is
    invisible here — only what the imports define. `elaborateCommands` lifts that limit for the
    files that need it. -/
private def parseCommands (inputCtx : Parser.InputContext) (env : Environment)
    (startState : Parser.ModuleParserState) (initialMessages : MessageLog) :
    BodyParse := Id.run do
  let mctx : Parser.ParserModuleContext := { env, options := {} }
  let mut state := startState
  let mut messages := initialMessages
  let mut body : BodyParse := BodyParse.empty
  repeat
    let (stx, state', messages') := Parser.parseCommand inputCtx mctx state messages
    state := state'
    messages := messages'
    if Parser.isTerminalCommand stx then
      break
    body := absorbCommand inputCtx stx body
  pure { body with messages }

/-- Command kinds selective elaboration **skips**: the proof/term-heavy declarations (the cost
    the parse-only default exists to avoid) and the effectful commands (`#eval`, `initialize`)
    a formatter must not run. Every *other* command is elaborated for its syntax/scope
    side-effect, so file-local notation registers into the parser — including downstream custom
    notation commands like mathlib's `notation3`, which no fixed allowlist could name from here
    (the `LeanFmt` package does not depend on mathlib).

    A denylist, not an allowlist, because the failure modes are asymmetric: missing a
    notation-defining command silently breaks parsing, whereas elaborating a harmless extra
    command only wastes a little best-effort work — and most such commands fail fast anyway,
    since the declarations they reference were skipped and are absent from the environment. -/
private def skipElaborationKind (kind : Name) : Bool :=
  [ ``Lean.Parser.Command.declaration, ``Lean.Parser.Command.«mutual»,
    ``Lean.Parser.Command.«deriving», ``Lean.Parser.Command.eval,
    ``Lean.Parser.Command.evalBang, ``Lean.Parser.Command.«initialize» ].contains kind

/-- The selective-elaboration command loop: like `parseCommands`, but it elaborates each
    command that is not `skipElaborationKind` as it goes, so file-local `notation`, `macro`,
    `open`, and `namespace` register into the parser context for the commands that follow — the
    reason a notation-declaring file parses cleanly here but degrades under the parse-only loop.
    Declaration bodies are never elaborated, so the cost is a handful of cheap notation/scope
    elaborations, not proof checking; commands that depend on skipped declarations fail fast.

    Elaboration is best-effort and its messages are discarded: only *parse* messages reach the
    result, so the reported `status` reflects parse fidelity alone. If elaborating a
    syntax-affecting command throws (e.g. it references a declaration this loop skipped), the
    loop keeps the pre-elaboration environment and continues; that command's notation simply
    stays unregistered. The parser context is rebuilt from the live command-state scope each
    step — the `currNamespace`/`openDecls` the parse-only loop cannot track. -/
private def elaborateCommands (inputCtx : Parser.InputContext) (env : Environment)
    (startState : Parser.ModuleParserState) (initialMessages : MessageLog) :
    IO BodyParse := do
  let mut cmdState := Command.mkState env
  let mut pstate := startState
  let mut parseMessages := initialMessages
  let mut body : BodyParse := BodyParse.empty
  repeat
    let scope := cmdState.scopes.head?
    let pmctx : Parser.ParserModuleContext :=
      { env := cmdState.env
        options := (scope.map (·.opts)).getD {}
        currNamespace := (scope.map (·.currNamespace)).getD Name.anonymous
        openDecls := (scope.map (·.openDecls)).getD [] }
    let cmdPos := pstate.pos
    let (stx, pstate', parseMessages') := Parser.parseCommand inputCtx pmctx pstate parseMessages
    pstate := pstate'
    parseMessages := parseMessages'
    if Parser.isTerminalCommand stx then
      break
    body := absorbCommand inputCtx stx body
    if !skipElaborationKind stx.getKind then
      let cmdCtx : Command.Context :=
        { cmdPos, fileName := inputCtx.fileName, fileMap := inputCtx.fileMap
          snap? := none, cancelTk? := none }
      match ← EIO.toIO' (((Command.elabCommand stx) cmdCtx).run cmdState) with
      | .ok (_, sNew) => cmdState := { sNew with messages := {} }
      | .error _ => pure ()
  pure { body with messages := parseMessages }

/-- Build the `syntax_summary` JSON object from per-kind command counts, the
    per-command byte-anchored `SyntaxRegion`s, and the per-declaration header spans. -/
private def syntaxSummary (kinds : Array (Name × Nat)) (regions : Array Json)
    (declHeaders : Array Json) (tacticBlocks : Array Json) : Json :=
  let total : Nat := kinds.foldl (fun acc (_, n) => acc + n) 0
  let kindObjs := kinds.map fun (k, n) => Json.mkObj [("kind", Json.str k.toString), ("count", toJson n)]
  Json.mkObj
    [ ("command_count", toJson total)
    , ("command_kinds", Json.arr kindObjs)
    , ("command_regions", Json.arr regions)
    , ("declaration_headers", Json.arr declHeaders)
    , ("tactic_blocks", Json.arr tacticBlocks) ]

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
    (summary : Json) (srcModel : Json) (fellBack : Bool) : String :=
  Json.mkObj
    [ ("status", Json.str status)
    , ("diagnostics", Json.arr diagnostics)
    , ("diagnostics_truncated", Json.bool truncated)
    , ("module_header", Json.mkObj
        [ ("imports", Json.arr ((imports.map Json.str).toArray))
        , ("is_module", Json.bool isModule)
        , ("import_spans", Json.arr importSpans) ])
    , ("syntax_summary", summary)
    , ("source_model", srcModel)
    , ("fell_back", Json.bool fellBack) ]
    |>.compress

/-- Process-global cell holding the built superset `Environment`, keyed by the caller's
    superset id. It survives across requests within a warm worker child; a recycled child
    finds it empty and rebuilds from the request-carried import list on the next request. -/
initialize pinnedEnvRef : IO.Ref (Option (String × Environment)) ← IO.mkRef none

/-- Build the project-wide superset environment by importing the union of every file's
    imports once. Returns the diagnostics log on any failure — a header parse error, an
    unresolved import, or a `processHeader` throw — so the caller falls back to per-file
    parsing rather than pinning a partial environment. -/
private def buildSupersetEnv (supersetImports : List String) (fileName : String) :
    IO (Except MessageLog Environment) := do
  let headerSrc := String.intercalate "\n" (supersetImports.map (fun m => "import " ++ m)) ++ "\n"
  let inputCtx := Parser.mkInputContext headerSrc "<superset>"
  let (header, _, headerMessages) ← Parser.parseHeader inputCtx
  if headerMessages.hasErrors then
    return .error headerMessages
  try
    let (env, msgs) ← (do
      unsafe Lean.enableInitializersExecution
      Elab.processHeader header {} headerMessages inputCtx)
    if msgs.hasErrors then
      pure (.error msgs)
    else
      pure (.ok env)
  catch e =>
    let mut log : MessageLog := {}
    log := log.add { fileName, pos := ⟨1, 0⟩, data := toString e, severity := .error }
    pure (.error log)

/-- Return the retained superset environment for `id`, building and retaining it on the
    first pinned request (or after a child recycle or an id change). `none` means the
    superset could not be built, so the caller parses against the file's own imports. -/
private def getOrBuildPinnedEnv (id : String) (supersetImports : List String)
    (fileName : String) : IO (Option Environment) := do
  if let some (id', env) ← pinnedEnvRef.get then
    if id' == id then
      return some env
  match ← buildSupersetEnv supersetImports fileName with
  | .ok env =>
    pinnedEnvRef.set (some (id, env))
    return some env
  | .error _ =>
    return none

/-- Core parse routine over an already-decoded request. -/
private def runParse (req : ParseRequest) : IO String := do
  -- Seed the module search path so `processHeader` can resolve the header's imports.
  if let some sysroot := req.sysroot then
    Lean.initSearchPath sysroot (req.searchPath.map System.FilePath.mk)
  else if let some sysroot ← IO.getEnv "LEAN_SYSROOT" then
    Lean.initSearchPath sysroot (req.searchPath.map System.FilePath.mk)
  let inputCtx := Parser.mkInputContext req.source req.file
  let (header, parserState, headerMessages) ← Parser.parseHeader inputCtx
  -- A header that itself fails to parse is a hard `error`: there is no reliable import
  -- set or body boundary to proceed from. This guard runs **before** any header-syntax
  -- extraction, because `Elab.headerToImports`/`HeaderSyntax.isModule` on an
  -- error-recovered header can reach unreachable code and abort the frontend outright
  -- (e.g. a tab in the header region: `parseHeader` recovers, but import extraction
  -- panics). A failed header has no trustworthy imports, so we report none.
  if headerMessages.hasErrors then
    let (diags, trunc) ← renderDiagnostics headerMessages req.file
    return mkResponse "error" diags trunc [] false #[] (syntaxSummary #[] #[] #[] #[]) (sourceModel #[] #[]) false
  let imports := ((Elab.headerToImports header).map (·.module.toString)).toList.eraseDups
  let isModule := Elab.HeaderSyntax.isModule header
  -- Byte-anchored per-import records, recovered from the parsed header. Reliable only
  -- once the header parses without error; the guard above reports `#[]` otherwise.
  let importSpans := LeanFmt.Source.importSpans header.raw
  -- Assemble the response from a completed body parse. Shared by the per-file and pinned
  -- paths, so only the source of the `Environment` differs between them. `fellBack`
  -- records whether the pinned environment was bypassed for this file.
  let respond : BodyParse → Bool → IO String := fun body fellBack => do
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
    pure <| mkResponse status diags trunc imports isModule importSpans
      (syntaxSummary body.kinds body.regions body.declHeaders body.tacticBlocks) srcModel fellBack
  -- Parse the body against `env`, parse-only first. If it degrades — typically a token from
  -- notation the file declares itself, which the parse-only loop never registers — retry with
  -- selective elaboration, which registers file-local `notation`/`macro`/`open` as it goes.
  -- Adopt the elaborated result only when it clears the parse errors, so a file already clean
  -- is never re-elaborated and a still-degrading file is never made worse. The elaboration
  -- cost is paid only on the files that actually need it.
  let parseBody : Environment → MessageLog → IO BodyParse := fun env msgs => do
    let body := parseCommands inputCtx env parserState msgs
    if body.messages.hasErrors then
      let elaborated ← elaborateCommands inputCtx env parserState msgs
      pure (if elaborated.messages.hasErrors then body else elaborated)
    else
      pure body
  -- Parse against the file's own imports: build its environment (reporting unresolved
  -- imports as a degrade rather than a crash) and run the command loop.
  let perFile : Bool → IO String := fun fellBack => do
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
      pure <| mkResponse "degraded" diags trunc imports isModule importSpans
        (syntaxSummary #[] #[] #[] #[]) (sourceModel #[] #[]) fellBack
    | .ok (env, importMessages) =>
      respond (← parseBody env importMessages) fellBack
  -- Pinned superset path: parse against the retained project-wide environment. If the
  -- superset grammar perturbs this file's parse (a new token or an ambiguity introduced
  -- by notation the file does not import), re-parse it against its own imports, so a file
  -- that parses cleanly on its own is never reported degraded by the superset.
  match req.supersetId with
  | none => perFile false
  | some id =>
    match ← getOrBuildPinnedEnv id req.supersetImports req.file with
    | none => perFile true
    | some env =>
      let body ← parseBody env headerMessages
      if body.messages.hasErrors then
        perFile true
      else
        respond body false

/--
Request/response export: parse an in-memory Lean source snapshot with the imports
declared in its header and return parse diagnostics plus a lightweight syntax summary.

Request: `{"file"?, "source", "imports"?, "superset_imports"?, "superset_id"?,
"options"?: {"sysroot"?, "search_path"?}}`. A `superset_id` (with `superset_imports`)
selects the pinned path; omitting it parses against the file's own header imports.
Response: `{"status", "diagnostics", "diagnostics_truncated", "module_header":
{"imports", "is_module", "import_spans"}, "syntax_summary": {"command_count",
"command_kinds", "command_regions", "declaration_headers", "tactic_blocks"},
"source_model": {"trivia_runs", "docstrings"}, "fell_back"}`, where `fell_back` is `true`
when the pinned environment was bypassed for this file, and `import_spans` are per-`import`
`{module, range: {start, end}}` records, each `command_regions` entry is a byte-anchored
`SyntaxRegion` (`{"kind", "range": {"start", "end"}, "line_column": …}`), each
`declaration_headers` entry names the byte ranges of one declaration's header roles
(`{"kind", "range", "keyword", "name"?, "binders": [{"range", "open"?, "close"?,
"colon"?}], "sig_colon"?, "assign"?, "where"?}`), each `tactic_blocks` entry names one
`by` block's anchors (`{"by", "seq"?, "base_column"?, "first_step"?, "bullets":
[{"kind", "range"}]}`), `trivia_runs` are the inter-token byte ranges (`{"start",
"end"}`) that hold all comments and blank lines, and `docstrings` are `docComment` node
byte ranges.
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
    pure <| mkResponse "error" #[diag] false [] false #[] (syntaxSummary #[] #[] #[] #[]) (sourceModel #[] #[]) false
  | .ok req => runParse req

/-- Assemble the `lean_fmt_validate` response envelope: whether the snapshot elaborated
    cleanly plus the (parse *and* elaboration) diagnostics. -/
private def mkValidateResponse (valid : Bool) (diagnostics : Array Json) (truncated : Bool) :
    String :=
  Json.mkObj
    [ ("valid", Json.bool valid)
    , ("diagnostics", Json.arr diagnostics)
    , ("diagnostics_truncated", Json.bool truncated) ]
    |>.compress

/-- Core validate routine: parse the header, build the command environment, then run the
    full front-end command loop (`Lean.Elab.IO.processCommands`), which **parses and
    elaborates** every command. The snapshot is `valid` only when the accumulated message
    log carries no error — so a snapshot that parses but fails to elaborate (an unknown
    identifier, a type error) is rejected, unlike the parse-only `lean_fmt_parse_file`.

    A header that fails to parse, or imports that fail to resolve, mean elaboration cannot
    be confirmed, so the snapshot is conservatively `valid = false` with the diagnostics. -/
private def runValidate (req : ParseRequest) : IO String := do
  -- Seed the module search path so `processHeader` can resolve the header's imports.
  if let some sysroot := req.sysroot then
    Lean.initSearchPath sysroot (req.searchPath.map System.FilePath.mk)
  else if let some sysroot ← IO.getEnv "LEAN_SYSROOT" then
    Lean.initSearchPath sysroot (req.searchPath.map System.FilePath.mk)
  let inputCtx := Parser.mkInputContext req.source req.file
  let (header, parserState, headerMessages) ← Parser.parseHeader inputCtx
  -- A header that itself fails to parse cannot be elaborated: reject.
  if headerMessages.hasErrors then
    let (diags, trunc) ← renderDiagnostics headerMessages req.file
    return mkValidateResponse false diags trunc
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
    -- Unresolved imports: elaboration cannot be confirmed, so reject conservatively.
    let (diags, trunc) ← renderDiagnostics log req.file
    return mkValidateResponse false diags trunc
  | .ok (env, importMessages) =>
    -- The full front-end loop parses *and* elaborates each command, accumulating both
    -- parse and elaboration messages in `commandState.messages`.
    let commandState := Command.mkState env importMessages {}
    let s ← Lean.Elab.IO.processCommands inputCtx parserState commandState
    let msgs := s.commandState.messages
    let (diags, trunc) ← renderDiagnostics msgs req.file
    return mkValidateResponse (!msgs.hasErrors) diags trunc

/--
Request/response export: parse **and elaborate** an in-memory Lean source snapshot with
the imports declared in its header, reporting whether elaboration succeeded. This is the
stricter counterpart of `lean_fmt_parse_file`: it runs the full front-end command loop
(`Lean.Elab.IO.processCommands`), so a snapshot that parses but fails to elaborate (an
unknown identifier, a type error) is reported invalid.

Request: `{"file"?, "source", "imports"?, "options"?: {"sysroot"?, "search_path"?}}`
(the same envelope as `lean_fmt_parse_file`).
Response: `{"valid", "diagnostics", "diagnostics_truncated"}`, where `valid` is `true`
only when the accumulated parse+elaboration message log carries no error. A malformed
request envelope, a header parse error, or unresolved imports all yield `valid = false`
with the diagnostics rather than a throw.
-/
@[export lean_fmt_validate]
def validateFileCommand (requestJson : String) : IO String := do
  match decodeRequest requestJson with
  | .error msg =>
    let diag := Json.mkObj
      [ ("severity", Json.str "error")
      , ("message", Json.str s!"invalid validate request: {msg}")
      , ("file", Json.str defaultFileLabel)
      , ("line", toJson (0 : Nat))
      , ("column", toJson (0 : Nat)) ]
    pure <| mkValidateResponse false #[diag] false
  | .ok req => runValidate req

end LeanFmt.Frontend
