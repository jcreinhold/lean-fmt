module

public import Test

/-!
# The LSP suite

Port of `tests/lsp/run.sh`: the protocol surface
against the real binary over a real pipe. The unit tests cover the position layer and frame
reader in isolation; this suite covers what only a process can show — lifecycle ordering, recovery
that leaves the session usable, refusal of a document with no project location, cancellation,
a bounded store, then diagnostics, formatting, and code actions over a live client.

The two halves are fed differently on purpose, as in the old script. Lifecycle and recovery write
the whole session in one go and read what comes back, which is the strongest way to assert
ordering (`runSession` + `parseFrames`). Diagnostics cannot be tested that way — they are
published after a quiet interval and `exit` closes the queue before the timer fires — so the
feature half drives the live `Test.LspClient`.

Lane: workspace — the server analyzes committed fixtures against the real root and shares the
root `.lean-fmt-cache`.
-/

open LeanFmt.Test
open LeanFmt.Test.LspClient
open Lean (Json)
open Lean.Lsp.Ipc (IpcM)

namespace Lsp

structure Ctx where
  root : System.FilePath
  application : String
  configToml : System.FilePath

private def Ctx.app (ctx : Ctx) : String :=
  ctx.application

private def Ctx.rootStr (ctx : Ctx) : String :=
  ctx.root.toString

-- -----------------------------------------------------------------------------------------------
-- The one-shot half: frame encoding and response-stream parsing, exactly the old script's
-- `frame`/`run`/`parse`.

/-- One framed message, compact separators like the old script's `json.dumps(separators=(",",":"))`. -/
private def frame (obj : Json) : String :=
  let body := obj.compress
  s!"Content-Length: {body.utf8ByteSize}\r\n\r\n{body}"

private def requestFrame (id : Nat) (method : String) (params : Option Json := none) : String :=
  let base := [("jsonrpc", Json.str "2.0"), ("id", Lean.toJson id), ("method", Json.str method)]
  frame
    (Json.mkObj
      (match params with
      | some value => base ++ [("params", value)]
      | none => base))

private def notificationFrame (method : String) (params : Option Json := none) : String :=
  let base := [("jsonrpc", Json.str "2.0"), ("method", Json.str method)]
  frame
    (Json.mkObj
      (match params with
      | some value => base ++ [("params", value)]
      | none => base))

private def openFrame (uri text : String) (version : Nat := 1) : String :=
  notificationFrame "textDocument/didOpen"
    (some
      (Json.mkObj
        [("textDocument",
            Json.mkObj
              [("uri", Json.str uri), ("languageId", Json.str "lean"),
                ("version", Lean.toJson version), ("text", Json.str text)])]))

/-- Split a response stream into messages, framing errors included — the old `parse`. The
declared `Content-Length` must match the bytes sent; anything else is a server bug the suite
must see, not a parse to recover from. -/
private partial def parseFrames (bytes : ByteArray) (label : String) (index : Nat := 0)
    (acc : Array Json := #[]) : IO (Array Json) := do
  if index >= bytes.size then
    return acc
  let mut headerStop := index
  let mut found := false
  for i in [index:bytes.size - 3]do
    if
        !found && bytes[i]! == 0x0D && bytes[i + 1]! == 0x0A && bytes[i + 2]! == 0x0D &&
          bytes[i + 3]! == 0x0A then
      headerStop := i
      found := true
  unless found do
    throw <| IO.userError s!"{label}: unterminated header at {index}"
  let header := (String.fromUTF8! (bytes.extract index headerStop))
  let mut length? : Option Nat := none
  for line in header.splitOn "\r\n"do
    if line.startsWith "Content-Length:" then
      length? := some (line.drop "Content-Length:".length).trimAscii.toString.toNat!
  let some length := length? | throw <| IO.userError s!"{label}: no Content-Length in {header}"
  let body := bytes.extract (headerStop + 4) (headerStop + 4 + length)
  unless body.size == length do
    throw <| IO.userError s!"{label}: declared Content-Length does not match the bytes sent"
  let json ←
    match Json.parse (String.fromUTF8! body) with
    | .ok value =>
      pure value
    | .error message =>
      throw <| IO.userError s!"{label}: a frame that is not JSON: {message}"
  parseFrames bytes label (headerStop + 4 + length) (acc.push json)

/-- Feed a whole session in one write and return (exit code, parsed stream) — the old `run`. -/
private def runSession (ctx : Ctx) (payload : String) (label : String) : IO (UInt32 × Array Json) :=
  do
  let result ←
    runProc ctx.app #["lsp", "--root", ctx.rootStr] (input? := some payload) (cwd? := some ctx.root)
        (env := #[("LEAN_NUM_THREADS", some "1")]) (timeoutMs := some 300000)
  return (result.exitCode, ← parseFrames result.stdout.toUTF8 label)

/-- The old `responses`: id → message for messages carrying a non-null id. -/
private def responsesOf (messages : Array Json) : Array (Nat × Json) :=
  messages.filterMap fun message =>
    match (message.getObjValAs? Nat "id").toOption with
    | some id => some (id, message)
    | none => none

private def answerOf (messages : Array Json) (id : Nat) : IO Json := do
  let some (_, answer) :=
    (responsesOf messages).find?
      (·.1 == id) | throw <| IO.userError s!"no response to id {id} in the stream"
  return answer

private def notificationsOf (messages : Array Json) (method : String) : Array Json :=
  messages.filter fun message => (message.getObjValAs? String "method").toOption == some method

private def shownMessages (messages : Array Json) : List String :=
  (notificationsOf messages "window/showMessage").toList.map fun message =>
    ((jsonAt? message [.field "params", .field "message"]).bind (·.getStr?.toOption)).getD ""

private def loggedMessages (messages : Array Json) : List String :=
  (notificationsOf messages "window/logMessage").toList.map fun message =>
    ((jsonAt? message [.field "params", .field "message"]).bind (·.getStr?.toOption)).getD ""

private def field (json : Json) (name : String) : Json :=
  (json.getObjVal? name).toOption.getD .null

private def strField (json : Json) (name : String) : String :=
  (json.getObjValAs? String name).toOption.getD ""

-- -----------------------------------------------------------------------------------------------
-- Fixture addresses

private def findingsUri (ctx : Ctx) : String :=
  s!"file://{ctx.rootStr}/tests/fixtures/check/Findings.lean"

private def layoutUri (ctx : Ctx) : String :=
  s!"file://{ctx.rootStr}/tests/fixtures/check/Layout.lean"

private def cleanUri (ctx : Ctx) : String :=
  s!"file://{ctx.rootStr}/tests/fixtures/check/Clean.lean"

private def readFixture (ctx : Ctx) (name : String) : IO String :=
  IO.FS.readFile (ctx.root / "tests" / "fixtures" / "check" / name)

-- -----------------------------------------------------------------------------------------------
-- One-shot sessions

private def lifecyclePayload : String :=
  requestFrame 1 "initialize" (some (Json.mkObj [])) ++
          notificationFrame "initialized" (some (Json.mkObj [])) ++
        requestFrame 2 "$/lean-fmt/health" ++
      requestFrame 3 "shutdown" ++
    notificationFrame "exit"

private def testLifecycle (ctx : Ctx) : IO Unit := do
  let (code, messages) ← runSession ctx lifecyclePayload "lifecycle"
  ensureEq "a clean session exits zero" 0 code
  ensureJsonAt (← answerOf messages 1)
      [.field "result", .field "capabilities", .field "documentFormattingProvider"]
      (Lean.toJson true) "formatting is advertised"
  ensureJsonAt (← answerOf messages 1)
      [.field "result", .field "capabilities", .field "documentRangeFormattingProvider"]
      (Lean.toJson true) "range formatting is advertised"
  ensureJsonAt (← answerOf messages 1)
      [.field "result", .field "capabilities", .field "textDocumentSync", .field "change"]
      (Lean.toJson (2 : Nat)) "sync is incremental"
  ensureJsonAt (← answerOf messages 1)
      [.field "result", .field "capabilities", .field "codeActionProvider",
        .field "codeActionKinds"]
      (Lean.toJson #["quickfix", "source.fixAll", "source.organizeImports"]) "code action kinds"
  ensureJsonAt (← answerOf messages 1) [.field "result", .field "serverInfo", .field "name"]
      (Lean.toJson "lean-fmt") "the server names itself"
  ensureJsonAt (← answerOf messages 2) [.field "result", .field "ready"] (Lean.toJson true)
      "health reports a ready server"
  ensureJsonAt (← answerOf messages 3) [.field "result"] .null "shutdown answers null"

private def testInitializationGuard (ctx : Ctx) : IO Unit := do
  -- A request before `initialize` is answered ServerNotInitialized (-32002), not ignored.
  let (_, messages) ←
    runSession ctx
        (requestFrame 1 "$/lean-fmt/health" ++ requestFrame 2 "initialize" (some (Json.mkObj [])) ++
            requestFrame 3 "shutdown" ++
          notificationFrame "exit")
        "pre-initialize"
  ensureJsonAt (← answerOf messages 1) [.field "error", .field "code"] (Lean.toJson (-32002 : Int))
      "a request before initialize is refused"
  ensure (((answerOf' messages 2).getObjVal? "result").toOption.isSome)
      "initialize still works afterwards"
  -- `exit` without `shutdown` is a protocol violation and exits non-zero.
  let (code, _) ←
    runSession ctx (requestFrame 1 "initialize" (some (Json.mkObj [])) ++ notificationFrame "exit")
        "bare exit"
  ensureEq "exit without shutdown exits non-zero" 1 code
  -- End of input ends the session cleanly, with no `exit` at all.
  let (eofCode, _) ← runSession ctx (requestFrame 1 "initialize" (some (Json.mkObj []))) "eof"
  ensureEq "end of input ends the session" 0 eofCode
where answerOf' (messages : Array Json) (id : Nat) : Json :=
    ((responsesOf messages).find? (·.1 == id)).map (·.2) |>.getD .null

private def testMalformedRecovery (ctx : Ctx) : IO Unit := do
  let (code, messages) ←
    runSession ctx
        (requestFrame 1 "initialize" (some (Json.mkObj [])) ++ "Content-Length: nope\r\n\r\n" ++
                  "Content-Length: 4\r\n\r\n{,,," ++
                "X-Only-Header: 1\r\n\r\n" ++
              requestFrame 2 "$/lean-fmt/health" ++
            requestFrame 3 "shutdown" ++
          notificationFrame "exit")
        "malformed"
  let parseErrors :=
    messages.filter fun message =>
      ((jsonAt? message [.field "error", .field "code"]).bind (·.getNum?.toOption)).map
          (·.mantissa == -32700) |>.getD
        false
  ensureEq "three malformed messages produce three parse errors" 3 parseErrors.size
  ensureJsonAt parseErrors[0]! [.field "id"] .null "a malformed message has a null id"
  ensure (((responsesOf messages).find? (·.1 == 2)).isSome) "the session survives them"
  ensureEq "and still exits cleanly" 0 code

private def testUnknownMethods (ctx : Ctx) : IO Unit := do
  let (code, messages) ←
    runSession ctx
        (requestFrame 1 "initialize" (some (Json.mkObj [])) ++
                requestFrame 2 "textDocument/hover" (some (Json.mkObj [])) ++
              notificationFrame "$/setTrace" (some (Json.mkObj [("value", Json.str "verbose")])) ++
            requestFrame 3 "shutdown" ++
          notificationFrame "exit")
        "unknown"
  ensureJsonAt (← answerOf messages 2) [.field "error", .field "code"] (Lean.toJson (-32601 : Int))
      "an unknown request is MethodNotFound"
  ensureEq "an unknown notification is not answered" 0 code

private def testDocumentAdmission (ctx : Ctx) : IO Unit := do
  let source ← readFixture ctx "Findings.lean"
  let (_, messages) ←
    runSession ctx
        (requestFrame 1 "initialize" (some (Json.mkObj [])) ++ openFrame (findingsUri ctx) source ++
                      openFrame "untitled:Untitled-1" "def x := 1\n" ++
                    openFrame "file:///etc/hosts" "def x := 1\n" ++
                  openFrame s!"file://{ctx.rootStr}/.lake/packages/x/X.lean" "def x := 1\n" ++
                openFrame s!"file://{ctx.rootStr}/README.md" "# not lean\n" ++
              requestFrame 2 "$/lean-fmt/health" ++
            requestFrame 3 "shutdown" ++
          notificationFrame "exit")
        "admission"
  let health ← answerOf messages 2
  ensureJsonAt health [.field "result", .field "openDocuments"] (Lean.toJson (1 : Nat))
      "one document is served"
  ensureJsonAt health [.field "result", .field "refusedDocuments"] (Lean.toJson (4 : Nat))
      "four are refused"
  ensureJsonAt health [.field "result", .field "openDocumentBytes"]
      (Lean.toJson source.utf8ByteSize) "the served bytes are the document's"
  let shown := shownMessages messages
  ensure
      (shown.any fun message =>
        message.contains "no file location" && message.contains "untitled:Untitled-1")
      "an untitled buffer is refused for having no location"
  ensure (shown.any (·.contains "outside the project root"))
      "a document outside the root is refused"
  ensure (shown.any (·.contains "Lake build directory")) "a document inside .lake is refused"
  ensure (shown.any (·.contains "not a Lean source"))
      "a document that is not Lean source is refused"
  ensure (shown.all fun message => message.contains "file://" || message.contains "untitled:")
      "every refusal names the URI the client sent"
  -- The refusal is announced once — not per request against the refused document.
  let (_, onceMessages) ←
    runSession ctx
        (requestFrame 1 "initialize" (some (Json.mkObj [])) ++
              openFrame "untitled:Untitled-1" "def x := 1\n" ++
            requestFrame 2 "shutdown" ++
          notificationFrame "exit")
        "refusal-once"
  ensureEq "the refusal is announced once" 1
      (notificationsOf onceMessages "window/showMessage").size

private def testVersionsSync (ctx : Ctx) : IO Unit := do
  let uri := findingsUri ctx
  let (_, messages) ←
    runSession ctx
        (requestFrame 1 "initialize" (some (Json.mkObj [])) ++ openFrame uri "def a := 1\n"
                  -- An incremental change: replace `1` with `22`.
                  ++
                  notificationFrame "textDocument/didChange"
                    (some
                      (Json.mkObj
                        [("textDocument",
                            Json.mkObj [("uri", Json.str uri), ("version", Lean.toJson (2 : Nat))]),
                          ("contentChanges",
                            Json.arr
                              #[Json.mkObj
                                  [("range", LspClient.range 0 9 0 10),
                                    ("text", Json.str "22")]])]))
                -- A stale version, which must be ignored rather than applied.
                ++
                notificationFrame "textDocument/didChange"
                  (some
                    (Json.mkObj
                      [("textDocument",
                          Json.mkObj [("uri", Json.str uri), ("version", Lean.toJson (2 : Nat))]),
                        ("contentChanges",
                          Json.arr #[Json.mkObj [("text", Json.str "wiped\n")]])])) ++
              requestFrame 2 "$/lean-fmt/health" ++
            requestFrame 3 "shutdown" ++
          notificationFrame "exit")
        "versions"
  ensureJsonAt (← answerOf messages 2) [.field "result", .field "openDocumentBytes"]
      (Lean.toJson "def a := 22\n".utf8ByteSize) "the incremental change applied"
  ensure ((loggedMessages messages).any (·.contains "not newer than"))
      "a non-increasing version is refused and said so"

private def testCloseClears (ctx : Ctx) : IO Unit := do
  let source ← readFixture ctx "Findings.lean"
  let uri := findingsUri ctx
  let (_, messages) ←
    runSession ctx
        (requestFrame 1 "initialize" (some (Json.mkObj [])) ++ openFrame uri source ++
                notificationFrame "textDocument/didClose"
                  (some (Json.mkObj [("textDocument", Json.mkObj [("uri", Json.str uri)])])) ++
              requestFrame 2 "$/lean-fmt/health" ++
            requestFrame 3 "shutdown" ++
          notificationFrame "exit")
        "close"
  let published := notificationsOf messages "textDocument/publishDiagnostics"
  ensureEq "closing publishes an empty diagnostic set" 1 published.size
  ensureJsonAt published[0]! [.field "params", .field "uri"] (Lean.toJson uri)
      "for the document that closed"
  ensureJsonAt published[0]! [.field "params", .field "diagnostics"] (.arr #[]) "and it is empty"
  ensureJsonAt (← answerOf messages 2) [.field "result", .field "openDocuments"]
      (Lean.toJson (0 : Nat)) "the document is gone"

private def testCancellation (ctx : Ctx) : IO Unit := do
  -- The cancellation arrives before the request it names: the reader applies it immediately, so
  -- the worker sees it when the request comes up for service and answers -32800.
  let (_, messages) ←
    runSession ctx
        (requestFrame 1 "initialize" (some (Json.mkObj [])) ++
                  notificationFrame "$/cancelRequest"
                    (some (Json.mkObj [("id", Lean.toJson (2 : Nat))])) ++
                requestFrame 2 "$/lean-fmt/health" ++
              requestFrame 3 "$/lean-fmt/health" ++
            requestFrame 4 "shutdown" ++
          notificationFrame "exit")
        "cancellation"
  ensureJsonAt (← answerOf messages 2) [.field "error", .field "code"] (Lean.toJson (-32800 : Int))
      "a cancelled request is answered RequestCancelled"
  ensureEq "and it is answered exactly once" 1
      (messages.filter fun message => (message.getObjValAs? Nat "id").toOption == some 2).size
  ensure (((field (← answerOf messages 3) "result")) != .null)
      "an uncancelled request is unaffected"

private def testBounds (ctx : Ctx) : IO Unit := do
  -- The document bound refuses; it does not truncate, and it does not stop the session.
  let big := "-- " ++ String.ofList (List.replicate (16 * 1024 * 1024) 'x') ++ "\n"
  let (code, messages) ←
    runSession ctx
        (requestFrame 1 "initialize" (some (Json.mkObj [])) ++ openFrame (findingsUri ctx) big ++
              requestFrame 2 "$/lean-fmt/health" ++
            requestFrame 3 "shutdown" ++
          notificationFrame "exit")
        "bounds"
  ensureJsonAt (← answerOf messages 2) [.field "result", .field "openDocuments"]
      (Lean.toJson (0 : Nat)) "an oversized document is refused"
  ensure ((shownMessages messages).any (·.contains "exceeds")) "and the refusal says so"
  ensureEq "the session continues" 0 code

-- -----------------------------------------------------------------------------------------------
-- The live half. Sessions run through `Test.LspClient`; each request id is used once.

private def liveSession {α : Type} (ctx : Ctx) (body : IpcM α) (debounceMs : Nat := 1)
    (extraArgs : Array String := #[]) (options : Json := Json.mkObj []) : IO (α × UInt32) :=
  LspClient.withServer ctx.app ctx.rootStr
    (do
      discard <| LspClient.initializeSession ctx.rootStr options
      body)
    (extraArgs := #["--debounce-ms", toString debounceMs] ++ extraArgs)

private def resultOf (answer : Answer) (label : String) : IO Json := do
  match answer with
  | .result value =>
    return value
  | .error code message =>
    throw <| IO.userError s!"{label}: {(Lean.toJson code).compress} {message}"

private def editsOf (answer : Answer) (label : String) : IO (Array Json) := do
  let value ← resultOf answer label
  match value with
  | .arr edits =>
    return edits
  | _ =>
    throw <| IO.userError s!"{label}: the result is not an edit array: {value.compress}"

/-- Apply one TextEdit the way a client would. ASCII fixtures, so a character is a code unit. -/
private def applyEdit (text : String) (edit : Json) : String :=
  let lines := text.splitOn "\n"
  let offset (position : Json) : Nat :=
    let line := (position.getObjValAs? Nat "line").toOption.getD 0
    let character := (position.getObjValAs? Nat "character").toOption.getD 0
    ((lines.take line).map (·.length + 1)).sum + character
  let start := offset (field (field edit "range") "start")
  let stop := offset (field (field edit "range") "end")
  String.Pos.Raw.extract text ⟨0⟩ ⟨start⟩ ++ strField edit "newText" ++
    String.Pos.Raw.extract text ⟨stop⟩ ⟨text.utf8ByteSize⟩

private def testDiagnostics (ctx : Ctx) : IO Unit := do
  let findingsSource ← readFixture ctx "Findings.lean"
  let cleanSource ← readFixture ctx "Clean.lean"
  let ((), code) ←
    liveSession ctx do
        openDocument (findingsUri ctx) findingsSource
        let some diagnostics ← awaitDiagnostics (findingsUri ctx) |
          throw <| IO.userError "no diagnostics were published for the findings fixture"
        ensureEq "a document publishes its findings" 1 diagnostics.size
        let first := diagnostics[0]!
        ensureJsonAt first [.field "source"] (Lean.toJson "lean-fmt") "the diagnostic is ours"
        ensureJsonAt first [.field "code"] (Lean.toJson "FMT003") "it carries the rule code"
        ensureJsonAt first [.field "severity"] (Lean.toJson (2 : Nat))
            "a formatter finding is a warning, not an error"
        let href := strField (field first "codeDescription") "href"
        ensure (href.endsWith "/docs/rules/FMT003.md") "and points at its rule's documentation"
        -- The whole point of the position layer: a byte range became a UTF-16 range on the right
        -- line. The duplicate is the *second* `import`, line 3 counting from zero.
        ensureJsonAt first [.field "range", .field "start", .field "line"] (Lean.toJson (3 : Nat))
            "the diagnostic's range is a client range"
        -- A clean document publishes an empty set -- which is a claim, not an absence.
        openDocument (cleanUri ctx) cleanSource
        let some cleanDiagnostics ← awaitDiagnostics (cleanUri ctx) |
          throw <| IO.userError "no diagnostics were published for the clean fixture"
        ensureEq "a clean document publishes nothing to report" 0 cleanDiagnostics.size
        request 90 "shutdown" (Json.mkObj [])
        discard <| awaitResponse 90
        notify "exit" (Json.mkObj [])
  ensureEq "the diagnostics session ends cleanly" 0 code

private def testFormatting (ctx : Ctx) : IO Unit := do
  -- `tests/fixtures/check/Clean.lean` has to actually be canonical for this to say anything. It held
  -- `def cleanValue : Nat := 1` on one line, which stopped being canonical at `3635d39` when the
  -- native adapter landed. The fixture was updated to the bytes Lean's own formatter produces;
  -- see `tests/modes/run.sh` for the full trace.
  let layoutSource ← readFixture ctx "Layout.lean"
  let cleanSource ← readFixture ctx "Clean.lean"
  let ((narrowEdit, wholeText), code) ←
    liveSession ctx do
        openDocument (cleanUri ctx) cleanSource
        request 1 "textDocument/formatting" (LspClient.documentParam (cleanUri ctx))
        ensureJsonAt (← resultOf (← awaitResponse 1) "clean formatting") [] (.arr #[])
            "a canonical document needs no edits"
        openDocument (layoutUri ctx) layoutSource
        request 2 "textDocument/formatting" (LspClient.documentParam (layoutUri ctx))
        let edits ← editsOf (← awaitResponse 2) "formatting"
        ensureEq "a non-canonical document gets exactly one edit" 1 edits.size
        ensureJsonAt edits[0]! [.field "range", .field "start"] (LspClient.position 0 0)
            "the edit replaces the whole document"
        let wholeText := strField edits[0]! "newText"
        ensure (wholeText.contains "namespace Alpha") "and it is the canonical bytes"
        ensure (wholeText != layoutSource) "which is not what the client already had"
        -- Range formatting answers over the *actual* range: the hull of the layout units the
        -- selection expands to.
        request 3 "textDocument/rangeFormatting"
            (Json.mkObj
              [("textDocument", Json.mkObj [("uri", Json.str (layoutUri ctx))]),
                ("range", LspClient.range 2 0 2 5), ("options", Json.mkObj [])])
        let rangeEdits ← editsOf (← awaitResponse 3) "range formatting"
        ensureEq "a range request is answered with an edit" 1 rangeEdits.size
        let narrowEdit := rangeEdits[0]!
        ensure (field (field narrowEdit "range") "end" != LspClient.position 2 5)
            "the actual range is not the requested one"
        ensure (!(strField narrowEdit "newText").contains "def layoutValue")
            "and the replacement is only the selected unit"
        -- The narrow edit and the whole-document edit must agree. This holds only while everything
        -- *outside* the selected range is already canonical, so keep `Layout.lean` dirty in exactly
        -- one place -- `namespace     Alpha`. If this fails, format the fixture and diff: a second
        -- dirty unit is the likely cause.
        ensureEq "the narrow edit does what the whole-document edit does" wholeText
            (applyEdit layoutSource narrowEdit)
        request 90 "shutdown" (Json.mkObj [])
        discard <| awaitResponse 90
        notify "exit" (Json.mkObj [])
        return (narrowEdit, wholeText)
  ensureEq "the formatting session ends cleanly" 0 code
  -- Drive the public stdin range surface over the identical unsaved bytes and requested
  -- coordinates. This must be the same complete spliced document that applying the LSP's narrow
  -- edit produces.
  let lines := layoutSource.splitOn "\n"
  let requestedStart := ((lines.take 2).map (·.length + 1)).sum
  let requestedStop := requestedStart + 5
  let stdin ←
    expectExit 0 "stdin range formatting" ctx.app
        #["format", "-", "--stdin-filename", "tests/fixtures/check/Layout.lean", "--range",
          s!"{requestedStart}:{requestedStop}"]
        (input? := some layoutSource) (cwd? := some ctx.root) (env :=
        #[("LEAN_NUM_THREADS", some "1")])
  ensureEq "stdin and LSP select and render identical range bytes"
      (applyEdit layoutSource narrowEdit) stdin.stdout

private def codeActionParam (uri : String) (startLine : Nat) (only : Array String := #[]) : Json :=
  Json.mkObj
    [("textDocument", Json.mkObj [("uri", Json.str uri)]),
      ("range", LspClient.range startLine 0 startLine 0),
      ("context",
        Json.mkObj
          ([("diagnostics", Json.arr #[])] ++
            (if only.isEmpty then [] else [("only", Lean.toJson only)])))]

private def kindsOf (actions : Array Json) : List String :=
  actions.toList.map (strField · "kind")

private def testCodeActions (ctx : Ctx) : IO Unit := do
  let findingsSource ← readFixture ctx "Findings.lean"
  let cleanSource ← readFixture ctx "Clean.lean"
  let ((), code) ←
    liveSession ctx do
        openDocument (findingsUri ctx) findingsSource
        discard <| awaitDiagnostics (findingsUri ctx)
        request 1 "textDocument/codeAction" (codeActionParam (findingsUri ctx) 3)
        let actions ← editsOf (← awaitResponse 1) "code actions"
        let kinds := (kindsOf actions).mergeSort (· < ·)
        -- All three: the fixture has a duplicate import, which FMT003 quickfixes, fix-all applies,
        -- and organize-imports removes as part of canonicalizing the header.
        ensureEq "every advertised kind is offered"
            ["quickfix", "source.fixAll", "source.organizeImports"] kinds
        let some quickfix :=
          actions.find?
            (strField · "kind" ==
              "quickfix") | throw <| IO.userError "no quickfix among the actions"
        ensure ((strField quickfix "title").startsWith "FMT003") "the quickfix names its rule"
        let changes := (field (field quickfix "edit") "documentChanges").getArr?.toOption.getD #[]
        ensureEq "the edit names one document" 1 changes.size
        ensureJsonAt changes[0]! [.field "textDocument", .field "version"] (Lean.toJson (1 : Nat))
            "computed against a stated version"
        ensureJsonAt changes[0]! [.field "textDocument", .field "uri"]
            (Lean.toJson (findingsUri ctx)) "for the document the action was asked about"
        ensureJsonAt changes[0]! [.field "edits", .index 0, .field "newText"] (Lean.toJson "")
            "and it deletes rather than rewrites"
        let some fixAll :=
          actions.find?
            (strField · "kind" ==
              "source.fixAll") | throw <| IO.userError "no fix-all among the actions"
        ensureJsonAt fixAll
            [.field "edit", .field "documentChanges", .index 0, .field "edits", .index 0,
              .field "range", .field "start"]
            (LspClient.position 0 0) "fix-all rewrites the whole document"
        -- `only` is honored: an editor asking on every cursor movement does not pay for two
        -- whole-document rewrites it did not ask for.
        request 2 "textDocument/codeAction"
            (codeActionParam (findingsUri ctx) 3 (only := #["source.organizeImports"]))
        let onlyActions ← editsOf (← awaitResponse 2) "only"
        ensureEq "only is honored" ["source.organizeImports"] (kindsOf onlyActions)
        -- A cursor away from every finding gets no quickfix, and still gets the source actions.
        openDocument (cleanUri ctx) cleanSource
        discard <| awaitDiagnostics (cleanUri ctx)
        request 3 "textDocument/codeAction" (codeActionParam (cleanUri ctx) 0)
        let cleanActions ← editsOf (← awaitResponse 3) "clean actions"
        ensureEq "a clean document offers no quickfix" 0
            (cleanActions.filter (strField · "kind" == "quickfix")).size
        request 90 "shutdown" (Json.mkObj [])
        discard <| awaitResponse 90
        notify "exit" (Json.mkObj [])
  ensureEq "the session ends cleanly" 0 code

private def testIgnoreOption (ctx : Ctx) : IO Unit := do
  -- The client's own configuration reaches the rule plan: ignoring FMT003 leaves the same bytes
  -- with nothing to report, which is the check that the option is read rather than accepted and
  -- dropped.
  let findingsSource ← readFixture ctx "Findings.lean"
  let ((), code) ←
    liveSession ctx (options := Json.mkObj [("ignore", Lean.toJson #["FMT003"])]) do
        openDocument (findingsUri ctx) findingsSource
        let some diagnostics ← awaitDiagnostics (findingsUri ctx) |
          throw <| IO.userError "no publication for the configured session"
        ensureEq "an ignored rule reports nothing" 0 diagnostics.size
        request 1 "textDocument/codeAction" (codeActionParam (findingsUri ctx) 3)
        let actions ← editsOf (← awaitResponse 1) "configured actions"
        ensureEq "and offers no quickfix for it" 0
            (actions.filter (strField · "kind" == "quickfix")).size
        request 90 "shutdown" (Json.mkObj [])
        discard <| awaitResponse 90
        notify "exit" (Json.mkObj [])
  ensureEq "the configured session ends cleanly" 0 code

private def testUnsafeDemoted (ctx : Ctx) : IO Unit := do
  -- `extend-unsafe-fixes` demotes FMT003 to unsafe (`tests/modes/run.sh` §"extend-unsafe-fixes").
  -- A demoted fix is still *reported* -- the finding does not go away -- but no quickfix is
  -- offered without explicit intent. Turning `--unsafe-fixes` on brings it back.
  let findingsSource ← readFixture ctx "Findings.lean"
  let quickfixes (extraArgs : Array String) : IO (Nat × List String × UInt32) := do
    let ((reported, kinds), code) ←
      liveSession ctx (extraArgs := #["--config", ctx.configToml.toString] ++ extraArgs) do
          openDocument (findingsUri ctx) findingsSource
          let some diagnostics ← awaitDiagnostics (findingsUri ctx) |
            throw <| IO.userError "no publication for the demoted session"
          request 1 "textDocument/codeAction" (codeActionParam (findingsUri ctx) 3)
          let actions ← editsOf (← awaitResponse 1) "demoted actions"
          request 90 "shutdown" (Json.mkObj [])
          discard <| awaitResponse 90
          notify "exit" (Json.mkObj [])
          return (diagnostics.size, kindsOf actions)
    return (reported, kinds, code)
  let (reported, offered, _) ← quickfixes #[]
  ensureEq "a demoted fix is still reported" 1 reported
  ensure (!(offered.contains "quickfix")) "but no quickfix is offered for it"
  let (reported', offered', _) ← quickfixes #["--unsafe-fixes"]
  ensureEq "the same document reports the same finding" 1 reported'
  ensure (offered'.contains "quickfix") "and the quickfix returns under explicit intent"

/-- Await a publication for `uri` carrying exactly `version` — the superseded-analyses case cares
about the version, which `awaitDiagnostics` does not select on. -/
private partial def awaitPublication (uri : String) (version : Nat) (budget : Nat := 64) :
    IpcM Json := do
  if budget == 0 then
    throw <| IO.userError s!"no publication for version {version} arrived"
  let json ← readFrameJson
  let params := field json "params"
  if
      (json.getObjValAs? String "method").toOption == some "textDocument/publishDiagnostics" &&
          (params.getObjValAs? String "uri").toOption == some uri &&
        (params.getObjValAs? Nat "version").toOption == some version then
    return params
  awaitPublication uri version (budget - 1)

private def testSuperseded (ctx : Ctx) : IO Unit := do
  -- Three edits in a row must not publish three times for the versions that were passed through:
  -- a publication for version 1 after version 3 has arrived describes bytes the client has
  -- edited past.
  let layoutSource ← readFixture ctx "Layout.lean"
  let ((), code) ←
    liveSession ctx (debounceMs := 80) do
        openDocument (layoutUri ctx) layoutSource
        for version in [2, 3, 4]do
          notify "textDocument/didChange"
              (Json.mkObj
                [("textDocument",
                    Json.mkObj
                      [("uri", Json.str (layoutUri ctx)), ("version", Lean.toJson version)]),
                  ("contentChanges",
                    Json.arr
                      #[Json.mkObj
                          [("range", LspClient.range 4 0 4 0),
                            ("text", Json.str s!"-- {version}\n")]])])
        let published ← awaitPublication (layoutUri ctx) 4
        ensureJsonAt published [.field "version"] (Lean.toJson (4 : Nat))
            "the surviving publication is the newest version"
        request 90 "shutdown" (Json.mkObj [])
        discard <| awaitResponse 90
        notify "exit" (Json.mkObj [])
  ensureEq "the superseding session ends cleanly" 0 code

end Lsp

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  withTempDir fun work => do
      let configToml := work / "lean-fmt.toml"
      writeFile configToml "[lint]\nextend-unsafe-fixes = [\"FMT003\"]\n"
      let ctx : Lsp.Ctx :=
        {
          root,
          application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
          configToml }
      let cases : Array Case :=
        #[{ name := "lifecycle", run := Lsp.testLifecycle ctx },
          { name := "initialization-guard", run := Lsp.testInitializationGuard ctx },
          { name := "malformed-recovery", run := Lsp.testMalformedRecovery ctx },
          { name := "unknown-methods", run := Lsp.testUnknownMethods ctx },
          { name := "document-admission", run := Lsp.testDocumentAdmission ctx },
          { name := "versions-sync", run := Lsp.testVersionsSync ctx },
          { name := "close-clears", run := Lsp.testCloseClears ctx },
          { name := "cancellation", run := Lsp.testCancellation ctx },
          { name := "bounds", run := Lsp.testBounds ctx },
          { name := "diagnostics", run := Lsp.testDiagnostics ctx },
          { name := "formatting", run := Lsp.testFormatting ctx },
          { name := "code-actions", run := Lsp.testCodeActions ctx },
          { name := "ignore-option", run := Lsp.testIgnoreOption ctx },
          { name := "unsafe-demoted", run := Lsp.testUnsafeDemoted ctx },
          { name := "superseded", run := Lsp.testSuperseded ctx }]
      runCases "lsp" cases args
