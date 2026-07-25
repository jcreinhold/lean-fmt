module

public import Lean.Data.Lsp.Ipc

import Test.Harness

/-!
# A language-server test client

The client half of every LSP suite, factored out of `tests/lsp/Acceptance.lean` so the suites
speak protocol and only protocol. The framing, message algebra, and error-code decoding come from
`Lean.Data.Lsp.Ipc` — the client the Lean team wrote to test Lean's own language server — so a
suite that asserts the server speaks LSP is not comparing the server against our own spelling of
the protocol.

Two deliberate exceptions live here rather than in `Ipc`, with their reasons:

- `awaitResponse` reports an error response instead of throwing. `Ipc.readResponseAs` throws on
  one, and half of what a server suite asserts is *which* error came back.
- `readFrameJson` reads one frame at the JSON level. JSON-RPC 2.0 §5 requires that a response to a
  message whose id could not be recovered — a parse error — carry `"id": null`, and
  `notes/01-protocol.md` §11 adopts that. `Lean.JsonRpc`'s `RequestID` decoder does not accept it,
  so `Ipc.readMessage` throws on a spec-conforming parse-error response. Real clients accept it
  (`vscode-languageclient` and `lsp-mode` both do), the specification mandates it, and the server
  keeps sending it. The header parsing and the JSON parser are still the toolchain's.
-/

open Lean Lean.Lsp Lean.Lsp.Ipc Lean.JsonRpc

namespace LeanFmt.Test.LspClient

/-- The outcome of one request: a result, or the code and message of an error response. -/
public inductive Answer where
  | result (value : Json)
  | error (code : ErrorCode) (message : String)
  deriving Inhabited

instance : ToString Answer where
  toString
    | .result value => s!"result {value.compress}"
    | .error code message => s!"error {(toJson code).compress} {message}"

public def request (id : Nat) (method : String) (param : Json) : IpcM Unit :=
  writeRequest ⟨id, method, param⟩

public def notify (method : String) (param : Json) : IpcM Unit :=
  writeNotification ⟨method, param⟩

/-- Read until the response to `id`, discarding notifications (`window/logMessage`,
`textDocument/publishDiagnostics`) that arrive in between. -/
public partial def awaitResponse (id : Nat) : IpcM Answer := do
  match ← readMessage with
  | .response responseId value =>
    if responseId == (id : RequestID) then return .result value else awaitResponse id
  | .responseError responseId code message _ =>
    if responseId == (id : RequestID) then return .error code message else awaitResponse id
  | _ => awaitResponse id

/-- Read until a `textDocument/publishDiagnostics` for `uri`, or run out of patience.

Diagnostics are published after a quiet interval, so this is the one client operation that can
block on a timer rather than on work. The bound is a message count, not a clock: the server sends
nothing else unprompted, so an unbounded wait here would be a hang. -/
public partial def awaitDiagnostics (uri : String) (budget : Nat := 64) :
    IpcM (Option (Array Json)) := do
  if budget == 0 then return none
  match ← readMessage with
  | .notification "textDocument/publishDiagnostics" (some param) =>
    let json := toJson param
    if (json.getObjValAs? String "uri").toOption == some uri then
      return (json.getObjValAs? (Array Json) "diagnostics").toOption.getD #[]
    else
      awaitDiagnostics uri (budget - 1)
  | _ => awaitDiagnostics uri (budget - 1)

/-- The standard session opening: `initialize`, its answer awaited, `initialized` sent. -/
public def initializeSession (root : String) (options : Json := Json.mkObj []) : IpcM Answer := do
  request 0 "initialize" (Json.mkObj [
    ("processId", Json.null),
    ("rootUri", Json.str s!"file://{root}"),
    ("capabilities", Json.mkObj []),
    ("initializationOptions", options)
  ])
  let answer ← awaitResponse 0
  notify "initialized" (Json.mkObj [])
  return answer

public def openDocument (uri text : String) (version : Nat := 1) : IpcM Unit :=
  notify "textDocument/didOpen" (Json.mkObj [("textDocument", Json.mkObj [
    ("uri", Json.str uri), ("languageId", Json.str "lean"),
    ("version", Lean.toJson version), ("text", Json.str text)])])

public def changeDocument (uri text : String) (version : Nat) : IpcM Unit :=
  notify "textDocument/didChange" (Json.mkObj [
    ("textDocument", Json.mkObj [("uri", Json.str uri), ("version", Lean.toJson version)]),
    ("contentChanges", Json.arr #[Json.mkObj [("text", Json.str text)]])])

public def documentParam (uri : String) : Json :=
  Json.mkObj [("textDocument", Json.mkObj [("uri", Json.str uri)]), ("options", Json.mkObj [])]

public def position (line character : Nat) : Json :=
  Json.mkObj [("line", Lean.toJson line), ("character", Lean.toJson character)]

public def range (startLine startCharacter stopLine stopCharacter : Nat) : Json :=
  Json.mkObj [("start", position startLine startCharacter),
              ("end", position stopLine stopCharacter)]

/-- Spawn one server and run `body` against it. The process is waited for, so a session that leaks
a child fails the suite rather than whatever runs next. -/
public def withServer {α : Type} (application : String) (root : String) (body : IpcM α)
    (extraArgs : Array String := #[]) : IO (α × UInt32) := do
  let child ← IO.Process.spawn { ipcStdioConfig with
    cmd := application
    args := #["lsp", "--root", root] ++ extraArgs
    cwd := some root
    env := #[("LEAN_NUM_THREADS", some "1")] }
  let value ← body.run child
  let code ← child.wait
  return (value, code)

/-- Read one frame and parse it as JSON, without going through `Ipc.readMessage` — see the module
docstring for why the message algebra cannot be the reader for a parse-error response. -/
public partial def readFrameJson : IpcM Json := do
  let stream ← stdout
  let mut length := 0
  repeat
    let line := (← stream.getLine).trimAscii.toString
    if line.isEmpty then break
    if line.startsWith "Content-Length:" then
      length := (line.drop "Content-Length:".length).trimAscii.toString.toNat!
  let body ← stream.read length.toUSize
  match Json.parse (String.fromUTF8! body) with
  | .ok json => return json
  | .error message => throw <| IO.userError s!"the server sent a frame that is not JSON: {message}"

/-- Read until any error response, whatever its id, at the JSON level. See `readFrameJson`. -/
public partial def awaitAnyError (budget : Nat := 16) : IpcM (Option (Json × Int)) := do
  if budget == 0 then return none
  let json ← readFrameJson
  match (json.getObjVal? "error").toOption with
  | some error =>
    let code := (error.getObjValAs? Int "code").toOption.getD 0
    return some ((json.getObjVal? "id").toOption.getD Json.null, code)
  | none => awaitAnyError (budget - 1)

/-- Write bytes the frame reader has to survive, verbatim. -/
public def writeRaw (text : String) : IpcM Unit := do
  let stream ← stdin
  stream.putStr text
  stream.flush

end LeanFmt.Test.LspClient
