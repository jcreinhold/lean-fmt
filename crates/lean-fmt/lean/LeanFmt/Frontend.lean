import Lean

/-!
# LeanFmt.Frontend

The semantic boundary of `lean-fmt`. Each request is self-contained: Lean parses the
source's actual ordered header, resolves exactly those imports against the supplied
search path, and processes the body in source order. No environment or strategy state
survives between requests.

`lean_fmt_analyze` selectively elaborates only environment-affecting commands while
collecting byte-accurate source structure. `lean_fmt_validate` runs Lean's full command
processor and therefore checks both parsing and elaboration.
-/

namespace LeanFmt.Frontend

open Lean Lean.Parser Lean.Elab

private def defaultFile : String := "<snapshot>"
private def diagnosticByteLimit : Nat := 64 * 1024

private structure Request where
  file : String
  source : String
  sysroot : Option String
  searchPath : List String

private def getString (json : Json) (field fallback : String) : String :=
  (json.getObjValAs? String field).toOption.getD fallback

private def decodeRequest (text : String) : Except String Request := do
  let json ← Json.parse text
  let source ← (json.getObjValAs? String "source").mapError fun _ =>
    "request is missing a string `source` field"
  let options := (json.getObjVal? "options").toOption.getD Json.null
  let searchPath :=
    match (options.getObjValAs? (Array String) "search_path").toOption with
    | some paths => paths.toList
    | none => []
  return {
    file := getString json "file" defaultFile
    source
    sysroot := (options.getObjValAs? String "sysroot").toOption
    searchPath
  }

private def initializeSearchPath (request : Request) : IO Unit := do
  let sysroot := request.sysroot <|> (← IO.getEnv "LEAN_SYSROOT")
  if let some root := sysroot then
    Lean.initSearchPath root (request.searchPath.map System.FilePath.mk)

private def severityJson : MessageSeverity → Json
  | .information => Json.str "info"
  | .warning => Json.str "warning"
  | .error => Json.str "error"

private def renderDiagnostics (messages : MessageLog) (fallbackFile : String) :
    IO (Array Json × Bool) := do
  let mut result := #[]
  let mut bytes := 0
  let mut truncated := false
  for message in messages.toArray do
    if !result.isEmpty && bytes ≥ diagnosticByteLimit then
      truncated := true
      break
    let body ← message.data.toString
    let file := if message.fileName.isEmpty then fallbackFile else message.fileName
    let mut fields :=
      [ ("severity", severityJson message.severity)
      , ("message", Json.str body)
      , ("file", Json.str file)
      , ("line", toJson message.pos.line)
      , ("column", toJson message.pos.column) ]
    if let some endPos := message.endPos then
      fields := fields ++ [("end_line", toJson endPos.line), ("end_column", toJson endPos.column)]
    result := result.push (Json.mkObj fields)
    bytes := bytes + body.utf8ByteSize
  return (result, truncated)

private def textRangeJson (range : Syntax.Range) : Json :=
  Json.mkObj [("start", toJson range.start.byteIdx), ("end", toJson range.stop.byteIdx)]

private def positionJson (position : Position) : Json :=
  Json.mkObj [("line", toJson position.line), ("column", toJson position.column)]

private def commandRegion (fileMap : FileMap) (stx : Syntax) : Option Json := do
  let range ← stx.getRange?
  return Json.mkObj
    [ ("kind", Json.str stx.getKind.toString)
    , ("range", textRangeJson range)
    , ("line_column", Json.mkObj
        [ ("start", positionJson (fileMap.toPosition range.start))
        , ("end", positionJson (fileMap.toPosition range.stop)) ]) ]

private partial def tokenSpans (stx : Syntax) (spans : Array (Nat × Nat) := #[]) :
    Array (Nat × Nat) :=
  let add (info : SourceInfo) (current : Array (Nat × Nat)) :=
    match info with
    | .original _ start _ stop => current.push (start.byteIdx, stop.byteIdx)
    | _ => current
  match stx with
  | .atom info _ => add info spans
  | .ident info .. => add info spans
  | .node _ _ children => children.foldl (fun current child => tokenSpans child current) spans
  | .missing => spans

private partial def docstringSpans (stx : Syntax) (spans : Array Json := #[]) : Array Json :=
  match stx with
  | .node _ kind children =>
    let spans :=
      if kind == ``Lean.Parser.Command.docComment then
        match stx.getRange? with
        | some range => spans.push (textRangeJson range)
        | none => spans
      else spans
    children.foldl (fun current child => docstringSpans child current) spans
  | _ => spans

private def triviaRuns (byteSize : Nat) (tokenRanges : Array (Nat × Nat)) : Array Json := Id.run do
  let sorted := tokenRanges.qsort fun left right => left.1 < right.1
  let mut cursor := 0
  let mut result := #[]
  for (start, stop) in sorted do
    if start > cursor then
      result := result.push (Json.mkObj [("start", toJson cursor), ("end", toJson start)])
    cursor := max cursor stop
  if cursor < byteSize then
    result := result.push (Json.mkObj [("start", toJson cursor), ("end", toJson byteSize)])
  return result

private def importJson (imp : Import) : Json :=
  Json.mkObj
    [ ("module", Json.str imp.module.toString)
    , ("is_meta", Json.bool imp.isMeta)
    , ("is_exported", Json.bool imp.isExported)
    , ("import_all", Json.bool imp.importAll) ]

private partial def importSpans (stx : Syntax) (result : Array Json := #[]) : Array Json :=
  match stx with
  | .node _ kind children =>
    let result :=
      if kind == ``Lean.Parser.Module.import then
        match stx.getRange? with
        | some range =>
          let moduleName :=
            (children.findSome? fun child => if child.isIdent then some child.getId.toString else none).getD ""
          result.push (Json.mkObj [("module", Json.str moduleName), ("range", textRangeJson range)])
        | none => result
      else result
    children.foldl (fun current child => importSpans child current) result
  | _ => result

private partial def firstAtomRange? (stx : Syntax) : Option Syntax.Range :=
  match stx with
  | .atom .. => stx.getRange?
  | .node _ _ children => children.findSome? firstAtomRange?
  | _ => none

private partial def lastAtomRange? (stx : Syntax) : Option Syntax.Range :=
  match stx with
  | .atom .. => stx.getRange?
  | .node _ _ children =>
    children.foldl (fun previous child => (lastAtomRange? child).orElse fun _ => previous) none
  | _ => none

private partial def firstIdentRange? (stx : Syntax) : Option Syntax.Range :=
  match stx with
  | .ident .. => stx.getRange?
  | .node _ _ children => children.findSome? firstIdentRange?
  | _ => none

private partial def atomRange? (stx : Syntax) (value : String) : Option Syntax.Range :=
  match stx with
  | .atom _ actual => if actual == value then stx.getRange? else none
  | .node _ _ children => children.findSome? fun child => atomRange? child value
  | _ => none

private partial def nodeOfKind? (stx : Syntax) (wanted : Name) : Option Syntax :=
  match stx with
  | .node _ kind children =>
    if kind == wanted then some stx
    else children.findSome? fun child => nodeOfKind? child wanted
  | _ => none

private partial def binderRecords (stx : Syntax) (records : Array Json := #[]) : Array Json :=
  match stx with
  | .node _ kind children =>
    if kind == ``Lean.Parser.Term.explicitBinder || kind == ``Lean.Parser.Term.implicitBinder ||
        kind == ``Lean.Parser.Term.strictImplicitBinder || kind == ``Lean.Parser.Term.instBinder then
      match stx.getRange? with
      | none => records
      | some range =>
        let fields :=
          [("range", textRangeJson range)]
            ++ (match firstAtomRange? stx with
                | some openRange => [("open", textRangeJson openRange)]
                | none => [])
            ++ (match lastAtomRange? stx with
                | some closeRange => [("close", textRangeJson closeRange)]
                | none => [])
            ++ (match atomRange? stx ":" with
                | some colonRange => [("colon", textRangeJson colonRange)]
                | none => [])
        records.push (Json.mkObj fields)
    else
      children.foldl (fun current child => binderRecords child current) records
  | _ => records

private partial def declarationHeaders (stx : Syntax) (records : Array Json := #[]) : Array Json :=
  match stx with
  | .node _ kind children =>
    if kind == ``Lean.Parser.Command.declaration then
      match children.find? fun child => child.getKind != ``Lean.Parser.Command.declModifiers with
      | none => records
      | some declaration =>
        match declaration.getRange? with
        | none => records
        | some range =>
          let signature? :=
            (nodeOfKind? declaration ``Lean.Parser.Command.optDeclSig).orElse fun _ =>
              nodeOfKind? declaration ``Lean.Parser.Command.declSig
          let name? :=
            (nodeOfKind? declaration ``Lean.Parser.Command.declId).bind firstIdentRange?
          let signatureColon? := signature?.bind fun signature =>
            (nodeOfKind? signature ``Lean.Parser.Term.typeSpec).bind firstAtomRange?
          let assignment? :=
            (nodeOfKind? declaration ``Lean.Parser.Command.declValSimple).bind firstAtomRange?
          let fields :=
            [ ("kind", Json.str declaration.getKind.toString)
            , ("range", textRangeJson range) ]
              ++ (match firstAtomRange? declaration with
                  | some keyword => [("keyword", textRangeJson keyword)]
                  | none => [])
              ++ (match name? with
                  | some name => [("name", textRangeJson name)]
                  | none => [])
              ++ [("binders", Json.arr (match signature? with
                  | some signature => binderRecords signature #[]
                  | none => #[]))]
              ++ (match signatureColon? with
                  | some colon => [("sig_colon", textRangeJson colon)]
                  | none => [])
              ++ (match assignment? with
                  | some assignment => [("assign", textRangeJson assignment)]
                  | none => [])
              ++ (match atomRange? declaration "where" with
                  | some whereRange => [("where", textRangeJson whereRange)]
                  | none => [])
          records.push (Json.mkObj fields)
    else
      children.foldl (fun current child => declarationHeaders child current) records
  | _ => records

private partial def bulletMarkers (stx : Syntax) (records : Array Json := #[]) : Array Json :=
  match stx with
  | .node _ kind children =>
    if kind == ``Lean.Parser.Term.byTactic then records
    else
      let records :=
        if kind == ``Lean.cdotTk then
          match stx.getRange? with
          | some range => records.push <| Json.mkObj
              [("kind", Json.str "cdot"), ("range", textRangeJson range)]
          | none => records
        else if kind == ``Lean.Parser.Tactic.case then
          match atomRange? stx "case" with
          | some range => records.push <| Json.mkObj
              [("kind", Json.str "case"), ("range", textRangeJson range)]
          | none => records
        else records
      children.foldl (fun current child => bulletMarkers child current) records
  | _ => records

private def firstTacticStep? (sequence : Syntax) : Option Syntax.Range := do
  let indented ← nodeOfKind? sequence ``Lean.Parser.Tactic.tacticSeq1Indented
  let children := indented.getArgs.foldl (fun result child => result ++ child.getArgs) #[]
  children.findSome? fun child =>
    match child with
    | .node .. => child.getRange?
    | _ => none

private partial def tacticBlocks (fileMap : FileMap) (stx : Syntax)
    (records : Array Json := #[]) : Array Json :=
  match stx with
  | .node _ kind children =>
    let records :=
      if kind == ``Lean.Parser.Term.byTactic then
        match firstAtomRange? stx with
        | none => records
        | some byRange =>
          let sequence? := nodeOfKind? stx ``Lean.Parser.Tactic.tacticSeq
          let sequenceRange? := sequence?.bind Syntax.getRange?
          let fields :=
            [("by", textRangeJson byRange)]
              ++ (match sequenceRange? with
                  | some range =>
                    [ ("seq", textRangeJson range)
                    , ("base_column", toJson (fileMap.toPosition range.start).column) ]
                  | none => [])
              ++ (match sequence?.bind firstTacticStep? with
                  | some range => [("first_step", textRangeJson range)]
                  | none => [])
              ++ [("bullets", Json.arr (match sequence? with
                  | some sequence => bulletMarkers sequence #[]
                  | none => #[]))]
          records.push (Json.mkObj fields)
      else records
    children.foldl (fun current child => tacticBlocks fileMap child current) records
  | _ => records

private structure BodyAnalysis where
  kinds : Array (Name × Nat) := #[]
  regions : Array Json := #[]
  declarationHeaders : Array Json := #[]
  tacticBlocks : Array Json := #[]
  tokenRanges : Array (Nat × Nat) := #[]
  docstrings : Array Json := #[]
  messages : MessageLog := {}

private def absorbCommand (input : Parser.InputContext) (stx : Syntax)
    (analysis : BodyAnalysis) : BodyAnalysis :=
  let kind := stx.getKind
  let kinds :=
    match analysis.kinds.findIdx? fun entry => entry.1 == kind with
    | some index =>
      match analysis.kinds[index]? with
      | some (_, count) => analysis.kinds.set! index (kind, count + 1)
      | none => analysis.kinds
    | none => analysis.kinds.push (kind, 1)
  let regions :=
    match commandRegion input.fileMap stx with
    | some region => analysis.regions.push region
    | none => analysis.regions
  { analysis with
    kinds
    regions
    declarationHeaders := declarationHeaders stx analysis.declarationHeaders
    tacticBlocks := tacticBlocks input.fileMap stx analysis.tacticBlocks
    tokenRanges := tokenSpans stx analysis.tokenRanges
    docstrings := docstringSpans stx analysis.docstrings }

private def skipSelectiveElaboration (kind : Name) : Bool :=
  [ ``Lean.Parser.Command.declaration
  , ``Lean.Parser.Command.«mutual»
  , ``Lean.Parser.Command.«deriving»
  , ``Lean.Parser.Command.eval
  , ``Lean.Parser.Command.evalBang
  , ``Lean.Parser.Command.«initialize» ].contains kind

/-- Parse in source order and retain scope/parser changes from safe environment-affecting
commands. Errors from this best-effort elaboration are deliberately discarded; only parser
and import diagnostics describe analysis fidelity. -/
private def analyzeCommands (input : Parser.InputContext) (environment : Environment)
    (initialParser : Parser.ModuleParserState) (initialMessages : MessageLog) : IO BodyAnalysis := do
  let mut commandState := Command.mkState environment
  let mut parserState := initialParser
  let mut parseMessages := initialMessages
  let mut analysis : BodyAnalysis := {}
  repeat
    let scope := commandState.scopes.head?
    let parserContext : Parser.ParserModuleContext :=
      { env := commandState.env
        options := (scope.map fun value => value.opts).getD {}
        currNamespace := (scope.map fun value => value.currNamespace).getD Name.anonymous
        openDecls := (scope.map fun value => value.openDecls).getD [] }
    let commandPosition := parserState.pos
    let (stx, nextParser, nextMessages) :=
      Parser.parseCommand input parserContext parserState parseMessages
    parserState := nextParser
    parseMessages := nextMessages
    if Parser.isTerminalCommand stx then
      break
    analysis := absorbCommand input stx analysis
    if !skipSelectiveElaboration stx.getKind then
      let context : Command.Context :=
        { cmdPos := commandPosition
          fileName := input.fileName
          fileMap := input.fileMap
          snap? := none
          cancelTk? := none }
      match ← EIO.toIO' (((Command.elabCommand stx) context).run commandState) with
      | .ok (_, nextState) => commandState := { nextState with messages := {} }
      | .error _ => pure ()
  return { analysis with messages := parseMessages }

private def syntaxSummary (analysis : BodyAnalysis) : Json :=
  let total := analysis.kinds.foldl (fun count entry => count + entry.2) 0
  let kinds := analysis.kinds.map fun (kind, count) =>
    Json.mkObj [("kind", Json.str kind.toString), ("count", toJson count)]
  Json.mkObj
    [ ("command_count", toJson total)
    , ("command_kinds", Json.arr kinds)
    , ("command_regions", Json.arr analysis.regions)
    , ("declaration_headers", Json.arr analysis.declarationHeaders)
    , ("tactic_blocks", Json.arr analysis.tacticBlocks) ]

private def emptySourceModel : Json :=
  Json.mkObj [("trivia_runs", Json.arr #[]), ("docstrings", Json.arr #[])]

private def sourceModel (request : Request) (header : Elab.HeaderSyntax)
    (analysis : BodyAnalysis) : Json :=
  let tokens := tokenSpans header analysis.tokenRanges
  let docs := docstringSpans header analysis.docstrings
  Json.mkObj
    [ ("trivia_runs", Json.arr (triviaRuns request.source.utf8ByteSize tokens))
    , ("docstrings", Json.arr docs) ]

private def headerJson (header : Elab.HeaderSyntax) : Json :=
  Json.mkObj
    [ ("is_module", Json.bool header.isModule)
    , ("imports", Json.arr ((header.imports false).map importJson))
    , ("import_spans", Json.arr (importSpans header.raw)) ]

private def emptyHeaderJson : Json :=
  Json.mkObj
    [ ("is_module", Json.bool false)
    , ("imports", Json.arr #[])
    , ("import_spans", Json.arr #[]) ]

private def analyzeResponse (status : String) (diagnostics : Array Json) (truncated : Bool)
    (header summary model : Json) : String :=
  Json.mkObj
    [ ("status", Json.str status)
    , ("diagnostics", Json.arr diagnostics)
    , ("diagnostics_truncated", Json.bool truncated)
    , ("module_header", header)
    , ("syntax_summary", summary)
    , ("source_model", model) ]
  |>.compress

private def emptySummary : Json := syntaxSummary {}

private def exceptionLog (file message : String) : MessageLog :=
  ({} : MessageLog).add
    { fileName := file, pos := ⟨1, 0⟩, data := message, severity := .error }

private def processExactHeader (request : Request) (input : Parser.InputContext)
    (header : Elab.HeaderSyntax) (messages : MessageLog) :
    IO (Except MessageLog (Environment × MessageLog)) := do
  try
    let result ← (do
      unsafe Lean.enableInitializersExecution
      Elab.processHeader header {} messages input)
    return .ok result
  catch error =>
    return .error (exceptionLog request.file (toString error))

private def invalidAnalyzeRequest (message : String) : String :=
  let diagnostic := Json.mkObj
    [ ("severity", Json.str "error")
    , ("message", Json.str s!"invalid analyze request: {message}")
    , ("file", Json.str defaultFile)
    , ("line", toJson (0 : Nat))
    , ("column", toJson (0 : Nat)) ]
  analyzeResponse "error" #[diagnostic] false emptyHeaderJson emptySummary emptySourceModel

private def runAnalyze (request : Request) : IO String := do
  initializeSearchPath request
  let input := Parser.mkInputContext request.source request.file
  let (header, parserState, headerMessages) ← Parser.parseHeader input
  if headerMessages.hasErrors then
    let (diagnostics, truncated) ← renderDiagnostics headerMessages request.file
    return analyzeResponse "error" diagnostics truncated emptyHeaderJson emptySummary emptySourceModel
  match ← processExactHeader request input header headerMessages with
  | .error messages =>
    let (diagnostics, truncated) ← renderDiagnostics messages request.file
    return analyzeResponse "degraded" diagnostics truncated (headerJson header) emptySummary emptySourceModel
  | .ok (environment, importMessages) =>
    let analysis ← analyzeCommands input environment parserState importMessages
    let (diagnostics, truncated) ← renderDiagnostics analysis.messages request.file
    let status := if analysis.messages.hasErrors then "degraded" else "ok"
    return analyzeResponse status diagnostics truncated (headerJson header)
      (syntaxSummary analysis) (sourceModel request header analysis)

/-- Analyze one source snapshot in its exact declared module context. -/
@[export lean_fmt_analyze]
def analyzeCommand (requestJson : String) : IO String := do
  match decodeRequest requestJson with
  | .error message => pure (invalidAnalyzeRequest message)
  | .ok request => runAnalyze request

private def validateResponse (valid : Bool) (diagnostics : Array Json)
    (truncated : Bool) : String :=
  Json.mkObj
    [ ("valid", Json.bool valid)
    , ("diagnostics", Json.arr diagnostics)
    , ("diagnostics_truncated", Json.bool truncated) ]
  |>.compress

private def invalidValidateRequest (message : String) : String :=
  let diagnostic := Json.mkObj
    [ ("severity", Json.str "error")
    , ("message", Json.str s!"invalid validate request: {message}")
    , ("file", Json.str defaultFile)
    , ("line", toJson (0 : Nat))
    , ("column", toJson (0 : Nat)) ]
  validateResponse false #[diagnostic] false

private def runValidate (request : Request) : IO String := do
  initializeSearchPath request
  let input := Parser.mkInputContext request.source request.file
  let (header, parserState, headerMessages) ← Parser.parseHeader input
  if headerMessages.hasErrors then
    let (diagnostics, truncated) ← renderDiagnostics headerMessages request.file
    return validateResponse false diagnostics truncated
  match ← processExactHeader request input header headerMessages with
  | .error messages =>
    let (diagnostics, truncated) ← renderDiagnostics messages request.file
    return validateResponse false diagnostics truncated
  | .ok (environment, importMessages) =>
    let initialState := Command.mkState environment importMessages {}
    let state ← Lean.Elab.IO.processCommands input parserState initialState
    let messages := state.commandState.messages
    let (diagnostics, truncated) ← renderDiagnostics messages request.file
    return validateResponse (!messages.hasErrors) diagnostics truncated

/-- Parse and fully elaborate one source snapshot in its exact declared module context. -/
@[export lean_fmt_validate]
def validateCommand (requestJson : String) : IO String := do
  match decodeRequest requestJson with
  | .error message => pure (invalidValidateRequest message)
  | .ok request => runValidate request

end LeanFmt.Frontend
