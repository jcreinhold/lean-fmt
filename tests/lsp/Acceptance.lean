module

import Lean.Data.Lsp.CodeActions
import Lean.Data.Lsp.Ipc

/-!
# `ruff-17` RLP-FINAL — protocol acceptance, driven by a client we did not write

`tests/lsp/run.sh` drives the server from Python: it frames its own messages and parses its own
replies. That is a real independent implementation, but it is *our* independent implementation, and
the frame reader it exercises is the one it also models. This harness is the other kind of
independence: it drives the server with `Lean.Data.Lsp.Ipc`, the client the Lean team wrote to test
Lean's own language server. Nothing here shares a line with `LeanFmt.LanguageServer` — the framing
comes from `Lean.Data.Lsp.Communication`, the message algebra from `Lean.JsonRpc`, and the error-code
decoder from `Lean.JsonRpc.ErrorCode`, so a code we emit that the toolchain does not recognize fails
here rather than being compared against our own spelling of it.

It covers what `notes/01-protocol.md` §15 hands to RLP-FINAL: lifecycle (§3), concurrent cancellation
at the running child (§9), Unicode positions (§4), dynamic reconfiguration (§10), malformed-message
recovery (§11), code actions (§8), and the 100-request memory stability of §13.

Run it through `tests/lsp/acceptance.sh`, which builds the binary and passes its path.
-/

open Lean Lean.Lsp Lean.Lsp.Ipc Lean.JsonRpc

namespace LeanFmt.Acceptance

/-! ## Reporting -/

structure Harness where
  failures : IO.Ref (Array String)
  root : String
  application : String

def Harness.check (h : Harness) (label : String) (ok : Bool) (detail : String := "") : IO Unit := do
  if ok then
    IO.println s!"ok   {label}"
  else
    IO.println s!"FAIL {label}{if detail.isEmpty then "" else "\n  " ++ detail}"
    h.failures.modify (·.push label)

def Harness.checkEq [BEq α] [ToString α] (h : Harness) (label : String) (actual expected : α) :
    IO Unit :=
  h.check label (actual == expected) s!"expected: {expected}\n  actual:   {actual}"

/-! ## Talking to the server

Everything below writes with `Ipc.writeRequest`/`writeNotification` and reads with `Ipc.readMessage`.
`awaitResponse` is the one piece `Ipc` does not have in the shape this needs: `Ipc.readResponseAs`
*throws* on an error response, and half of what an acceptance suite asserts is which error came back.
-/

private def request (id : Nat) (method : String) (param : Json) : IpcM Unit :=
  writeRequest ⟨id, method, param⟩

private def notify (method : String) (param : Json) : IpcM Unit :=
  writeNotification ⟨method, param⟩

/-- The outcome of one request: a result, or the code and message of an error response. -/
inductive Answer where
  | result (value : Json)
  | error (code : ErrorCode) (message : String)
  deriving Inhabited

instance : ToString Answer where
  toString
    | .result value => s!"result {value.compress}"
    | .error code message => s!"error {(toJson code).compress} {message}"

/-- Read until the response to `id`, discarding notifications (`window/logMessage`,
`textDocument/publishDiagnostics`) that arrive in between. -/
private partial def awaitResponse (id : Nat) : IpcM Answer := do
  match ← readMessage with
  | .response responseId value =>
    if responseId == (id : RequestID) then return .result value else awaitResponse id
  | .responseError responseId code message _ =>
    if responseId == (id : RequestID) then return .error code message else awaitResponse id
  | _ => awaitResponse id

/-- Read until a `textDocument/publishDiagnostics` for `uri`, or run out of patience.

Diagnostics are published after a quiet interval, so this is the only thing in the suite that can
block on a timer rather than on work. The bound is a message count, not a clock: the server sends
nothing else unprompted, so an unbounded wait here would be a hang. -/
private partial def awaitDiagnostics (uri : String) (budget : Nat := 64) :
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

private def initializeSession (root : String) (options : Json := Json.mkObj []) : IpcM Answer := do
  request 0 "initialize" (Json.mkObj [
    ("processId", Json.null),
    ("rootUri", Json.str s!"file://{root}"),
    ("capabilities", Json.mkObj []),
    ("initializationOptions", options)
  ])
  let answer ← awaitResponse 0
  notify "initialized" (Json.mkObj [])
  return answer

private def openDocument (uri text : String) (version : Nat := 1) : IpcM Unit :=
  notify "textDocument/didOpen" (Json.mkObj [("textDocument", Json.mkObj [
    ("uri", Json.str uri), ("languageId", Json.str "lean"),
    ("version", Lean.toJson version), ("text", Json.str text)])])

private def changeDocument (uri text : String) (version : Nat) : IpcM Unit :=
  notify "textDocument/didChange" (Json.mkObj [
    ("textDocument", Json.mkObj [("uri", Json.str uri), ("version", Lean.toJson version)]),
    ("contentChanges", Json.arr #[Json.mkObj [("text", Json.str text)]])])

private def documentParam (uri : String) : Json :=
  Json.mkObj [("textDocument", Json.mkObj [("uri", Json.str uri)]), ("options", Json.mkObj [])]

private def position (line character : Nat) : Json :=
  Json.mkObj [("line", Lean.toJson line), ("character", Lean.toJson character)]

private def range (startLine startCharacter stopLine stopCharacter : Nat) : Json :=
  Json.mkObj [("start", position startLine startCharacter),
              ("end", position stopLine stopCharacter)]

/-- Spawn one server and run `body` against it. The process is waited for, so a session that leaks a
child fails here rather than in whatever runs next. -/
private def withServer {α : Type} (h : Harness) (body : IpcM α)
    (extraArgs : Array String := #[]) : IO (α × UInt32) := do
  let child ← IO.Process.spawn { ipcStdioConfig with
    cmd := h.application
    args := #["lsp", "--root", h.root] ++ extraArgs
    cwd := some h.root
    env := #[("LEAN_NUM_THREADS", some "1")] }
  let value ← body.run child
  let code ← child.wait
  return (value, code)

/-! ## 1. Lifecycle (§3)

`initialize` is answered before anything else is served; `shutdown` then `exit` leaves zero; `exit`
without `shutdown` leaves one, which the specification requires and which no ordinary client will ever
see. `Ipc.shutdown` is the toolchain's own shutdown sequence, so this is its assertion as much as
ours. -/

private def lifecycle (h : Harness) : IO Unit := do
  let (_, code) ← withServer h do
    let answer ← initializeSession h.root
    match answer with
    | .result value =>
      h.check "initialize is answered with capabilities"
        ((value.getObjVal? "capabilities").toOption.isSome)
      let name := ((value.getObjVal? "serverInfo").toOption.bind
        fun info => (info.getObjValAs? String "name").toOption)
      h.checkEq "the server names itself" (name.getD "") "lean-fmt"
      let capabilities := (value.getObjVal? "capabilities").toOption.getD (Json.mkObj [])
      h.checkEq "it offers document formatting"
        ((capabilities.getObjValAs? Bool "documentFormattingProvider").toOption.getD false) true
      h.checkEq "it offers range formatting"
        ((capabilities.getObjValAs? Bool "documentRangeFormattingProvider").toOption.getD false) true
      h.check "it offers code actions"
        ((capabilities.getObjVal? "codeActionProvider").toOption.isSome)
    | .error _ message => h.check "initialize is answered with capabilities" false message
    request 1 "$/lean-fmt/health" (Json.mkObj [])
    match ← awaitResponse 1 with
    | .result value =>
      h.checkEq "health reports ready"
        ((value.getObjValAs? Bool "ready").toOption.getD false) true
    | .error _ message => h.check "health reports ready" false message
    Ipc.shutdown 2
  h.checkEq "shutdown then exit leaves zero" code 0

  let (_, code) ← withServer h do
    discard <| initializeSession h.root
    notify "exit" (Json.mkObj [])
  h.checkEq "exit without shutdown leaves one" code 1

  let (_, code) ← withServer h do
    request 1 "textDocument/formatting" (documentParam s!"file://{h.root}/tests/check/Clean.lean")
    match ← awaitResponse 1 with
    | .error code message =>
      h.checkEq "a request before initialize is refused" (toJson code).compress "-32002"
      h.check "and the refusal names the method" ((message.splitOn "formatting").length > 1) message
    | .result value => h.check "a request before initialize is refused" false value.compress
    discard <| initializeSession h.root
    Ipc.shutdown 2
  h.checkEq "and the session survives to be initialized afterwards" code 0

/-! ## 2. Malformed messages (§11)

The freeze's claim is not "malformed input is answered" but "malformed input never terminates the
server". Both halves are asserted here, and the second is the one that needs a process: after each bad
message the session is asked a real question and must answer it. -/

/-- Read one frame and parse it as JSON, without going through `Ipc.readMessage`.

This exists for exactly one message, and the reason is a finding rather than a convenience.
JSON-RPC 2.0 §5 requires that a response to a message whose id could not be recovered — a parse error
— carry `"id": null`, and `notes/01-protocol.md` §11 adopts that. `Lean.JsonRpc`'s `RequestID` decoder
does not accept it: `fromJson? : Message` fails with "a request id needs to be a number or a string",
so `Ipc.readMessage` *throws* on a spec-conforming parse-error response. Real clients accept it
(`vscode-languageclient` and `lsp-mode` both do), the specification mandates it, and the server keeps
sending it; this reads that one frame at the JSON level instead. The header parsing and the JSON parser
are still the toolchain's. -/
private partial def readFrameJson : IpcM Json := do
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
private partial def awaitAnyError (budget : Nat := 16) : IpcM (Option (Json × Int)) := do
  if budget == 0 then return none
  let json ← readFrameJson
  match (json.getObjVal? "error").toOption with
  | some error =>
    let code := (error.getObjValAs? Int "code").toOption.getD 0
    return some ((json.getObjVal? "id").toOption.getD Json.null, code)
  | none => awaitAnyError (budget - 1)

private def writeRaw (text : String) : IpcM Unit := do
  let stream ← stdin
  stream.putStr text
  stream.flush

private def malformed (h : Harness) : IO Unit := do
  let (_, code) ← withServer h do
    discard <| initializeSession h.root
    -- A framed body that is not JSON. The frame is consumed, so the stream stays in sync.
    writeRaw "Content-Length: 5\r\n\r\n{{{{{"
    match ← awaitAnyError with
    | some (id, code) =>
      h.checkEq "an unparseable body is a parse error" code (-32700)
      h.checkEq "answered with a null id, because none could be recovered" id.compress "null"
    | none => h.check "an unparseable body is a parse error" false "no error response arrived"
    request 1 "$/lean-fmt/health" (Json.mkObj [])
    match ← awaitResponse 1 with
    | .result _ => h.check "and the session is still usable" true
    | .error _ message => h.check "and the session is still usable" false message
    -- Well-formed JSON that is not a request: an id and no method. Not answerable and not fatal.
    writeRaw "Content-Length: 12\r\n\r\n{\"id\": 4711}"
    request 2 "$/lean-fmt/health" (Json.mkObj [])
    match ← awaitResponse 2 with
    | .result _ => h.check "a message with no method is survived" true
    | .error _ message => h.check "a message with no method is survived" false message
    request 3 "textDocument/definition" (documentParam s!"file://{h.root}/tests/check/Clean.lean")
    match ← awaitResponse 3 with
    | .error code _ =>
      h.checkEq "an unknown method is method-not-found" (toJson code).compress "-32601"
    | .result value => h.check "an unknown method is method-not-found" false value.compress
    notify "$/someNotificationWeDoNotKnow" (Json.mkObj [])
    request 4 "$/lean-fmt/health" (Json.mkObj [])
    match ← awaitResponse 4 with
    | .result _ => h.check "an unknown notification is ignored, not answered" true
    | .error _ message => h.check "an unknown notification is ignored, not answered" false message
    Ipc.shutdown 5
  h.checkEq "and the whole malformed session still exits cleanly" code 0

/-! ## 3. Unicode positions (§4)

The conversion layer is UTF-16 in both directions and clamps rather than validates. Three sizes are
distinguishable on the fixture below — 12 UTF-16 units, 10 codepoints, 16 bytes — so an assertion on
the end position tells them apart instead of agreeing with all three. -/

/-- Ends without a newline so that the last line is the interesting one, and the astral characters sit
on it: `𝔽` is one codepoint, two UTF-16 units, four bytes. -/
private def unicodeSource : String :=
  "module\n\nnamespace     Alpha\n\ndef layoutValue : Nat := 1\n\nend Alpha\n-- 𝔽𝔽 tail"

private def unicode (h : Harness) : IO Unit := do
  let uri := s!"file://{h.root}/tests/check/Layout.lean"
  let (_, code) ← withServer h do
    discard <| initializeSession h.root
    openDocument uri unicodeSource
    request 1 "textDocument/formatting" (documentParam uri)
    match ← awaitResponse 1 with
    | .result value =>
      let edits := (value.getArr?).toOption.getD #[]
      h.checkEq "the document formats to one whole-document edit" edits.size 1
      let stop := ((edits[0]!.getObjVal? "range").toOption.bind fun r =>
        (r.getObjVal? "end").toOption).getD Json.null
      let line := (stop.getObjValAs? Nat "line").toOption.getD 0
      let character := (stop.getObjValAs? Nat "character").toOption.getD 0
      h.checkEq "the edit ends on the last line" line 7
      -- 12 is UTF-16 units. Codepoints would be 10 and bytes 16, so this discriminates all three.
      h.checkEq "and at the last line's length in UTF-16 code units" character 12
    | .error _ message => h.check "the document formats to one whole-document edit" false message
    -- A position that splits an astral pair. §4 clamps; it does not raise.
    request 2 "textDocument/rangeFormatting" (Json.mkObj [
      ("textDocument", Json.mkObj [("uri", Json.str uri)]),
      ("range", range 2 0 7 4), ("options", Json.mkObj [])])
    match ← awaitResponse 2 with
    | .result value =>
      h.check "a position splitting a surrogate pair is clamped, not refused"
        (value.getArr?.toOption.isSome) value.compress
    | .error _ message =>
      h.check "a position splitting a surrogate pair is clamped, not refused" false message
    -- A character index past the end of its line, which a client sends after a race with its own edit.
    request 3 "textDocument/rangeFormatting" (Json.mkObj [
      ("textDocument", Json.mkObj [("uri", Json.str uri)]),
      ("range", range 2 0 99 99), ("options", Json.mkObj [])])
    match ← awaitResponse 3 with
    | .result value =>
      h.check "an out-of-range position is clamped to the document" (value.getArr?.toOption.isSome)
        value.compress
    | .error _ message => h.check "an out-of-range position is clamped to the document" false message
    -- The map is rebuilt on change, so the same assertion must hold for text that arrived by edit.
    changeDocument uri (unicodeSource ++ " 中") 2
    request 4 "textDocument/formatting" (documentParam uri)
    match ← awaitResponse 4 with
    | .result value =>
      let edits := (value.getArr?).toOption.getD #[]
      let character := ((edits[0]!.getObjVal? "range").toOption.bind fun r =>
        (r.getObjVal? "end").toOption |>.bind fun stop =>
          (stop.getObjValAs? Nat "character").toOption).getD 0
      -- `中` is one UTF-16 unit; the line is now 12 + 1 (space) + 1.
      h.checkEq "a changed document's positions follow the new text" character 14
    | .error _ message => h.check "a changed document's positions follow the new text" false message
    Ipc.shutdown 5
  h.checkEq "the Unicode session exits cleanly" code 0

/-! ## 4. Dynamic reconfiguration (§10)

The configuration a client names at startup governs the session, and rewriting that file and sending
`workspace/didChangeConfiguration` changes what the open documents report — without reopening them and
without restarting the server. -/

private def findingsSource : String :=
  "module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n\ndef findingValue : Nat := 1\n"

private def reconfiguration (h : Harness) : IO Unit := do
  let directory : System.FilePath := (← IO.Process.run { cmd := "mktemp", args := #["-d"] }).trimAscii.toString
  let configuration := directory / "lean-fmt.toml"
  IO.FS.writeFile configuration "include = [\"**/*.lean\"]\n"
  let uri := s!"file://{h.root}/tests/check/Findings.lean"
  let (_, code) ← withServer h (extraArgs := #["--debounce-ms", "1"]) do
    discard <| initializeSession h.root
      (Json.mkObj [("configPath", Json.str configuration.toString)])
    openDocument uri findingsSource
    match ← awaitDiagnostics uri with
    | some diagnostics =>
      let codes := diagnostics.filterMap fun d => (d.getObjValAs? String "code").toOption
      h.check "the duplicate import is reported under the client's configuration"
        (codes.contains "FMT003") s!"{codes}"
    | none =>
      h.check "the duplicate import is reported under the client's configuration" false "none arrived"
    IO.FS.writeFile configuration
      "include = [\"**/*.lean\"]\n[per-file-ignores]\n\"**/Findings.lean\" = [\"FMT003\"]\n"
    notify "workspace/didChangeConfiguration" (Json.mkObj [("settings", Json.mkObj [])])
    match ← awaitDiagnostics uri with
    | some diagnostics =>
      let codes := diagnostics.filterMap fun d => (d.getObjValAs? String "code").toOption
      h.check "and it stops being reported when the file says to ignore it"
        (!codes.contains "FMT003") s!"{codes}"
    | none =>
      h.check "and it stops being reported when the file says to ignore it" false "none arrived"
    Ipc.shutdown 9
  h.checkEq "the reconfigured session exits cleanly" code 0
  IO.FS.removeDirAll directory

/-! ## 5. Code actions (§8)

Read from the client's side: an action must carry an edit a client can apply without asking anything
further, and must name the version it was computed against. -/

private def codeActions (h : Harness) : IO Unit := do
  let uri := s!"file://{h.root}/tests/check/Findings.lean"
  let (_, code) ← withServer h do
    discard <| initializeSession h.root
    openDocument uri findingsSource
    request 1 "textDocument/codeAction" (Json.mkObj [
      ("textDocument", Json.mkObj [("uri", Json.str uri)]),
      ("range", range 3 0 3 0),
      ("context", Json.mkObj [("diagnostics", Json.arr #[])])])
    match ← awaitResponse 1 with
    | .result value =>
      let actions := value.getArr?.toOption.getD #[]
      h.check "the duplicate import offers actions" (actions.size > 0) value.compress
      let kinds := actions.filterMap fun a => (a.getObjValAs? String "kind").toOption
      h.check "including a quickfix" (kinds.contains "quickfix") s!"{kinds}"
      let edits := actions.filterMap fun a => (a.getObjVal? "edit").toOption
      h.checkEq "every action carries its own edit" edits.size actions.size
      let versions := edits.filterMap fun edit =>
        ((edit.getObjValAs? (Array Json) "documentChanges").toOption.bind fun changes =>
          changes[0]?.bind fun change =>
            (change.getObjVal? "textDocument").toOption.bind fun identifier =>
              (identifier.getObjValAs? Int "version").toOption)
      h.checkEq "and states the version it was computed against" versions (edits.map fun _ => (1 : Int))
      -- The toolchain's own decoder must accept them, or the shape is ours rather than the protocol's.
      let decoded := actions.filterMap fun a => (fromJson? (α := CodeAction) a).toOption
      h.checkEq "and the toolchain decodes them as CodeActions" decoded.size actions.size
    | .error _ message => h.check "the duplicate import offers actions" false message
    Ipc.shutdown 2
  h.checkEq "the code-action session exits cleanly" code 0

/-! ## 6. Concurrent cancellation (§9)

The claim under test is not "a cancelled request is answered" — `tests/lsp/run.sh` already shows that
for a *queued* request. It is that a `$/cancelRequest` naming the request already running reaches the
document's active snapshot and shortens it. That can only be shown by timing: the same request, cancelled
mid-flight, must come back in a fraction of the time it takes to finish. -/

private def slowSource : String := Id.run do
  let mut source := "module\nimport Lean\n\nnamespace LspCancellation\n\n"
  for i in [0:2500] do
    source := source ++ s!"def cancellation_{i} : Nat := {i}\n"
  return source ++ "\nend LspCancellation\n"

private def cancellation (h : Harness) : IO Unit := do
  let uri := s!"file://{h.root}/LeanFmt/Application.lean"
  let source := slowSource
  let ((uncancelled, cancelled), code) ← withServer h do
    discard <| initializeSession h.root
    openDocument uri source
    -- Wait for the debounced analysis first. It is one incremental run of this same slow module, and it
    -- rides the same FIFO, so timing a request while it is still queued measures the queue rather than
    -- the child — which is exactly the mistake the first version of this check made, reporting a
    -- "cancelled" request that had not begun.
    discard <| awaitDiagnostics uri
    -- What the request costs when nobody interrupts it.
    let started ← IO.monoMsNow
    request 1 "textDocument/formatting" (documentParam uri)
    let answer ← awaitResponse 1
    let uncancelled := (← IO.monoMsNow) - started
    match answer with
    | .result _ => h.check "the slow document formats at all" true
    | .error _ message => h.check "the slow document formats at all" false message
    -- A new version prevents the completed canonical envelope above from answering this request.
    -- The same work is then cancelled while its candidate snapshot is running.
    changeDocument uri (source ++ "\n") 2
    let started ← IO.monoMsNow
    request 2 "textDocument/formatting" (documentParam uri)
    IO.sleep 400
    notify "$/cancelRequest" (Json.mkObj [("id", Lean.toJson (2 : Nat))])
    let answer ← awaitResponse 2
    let cancelled := (← IO.monoMsNow) - started
    match answer with
    | .error code _ =>
      h.checkEq "a request cancelled in flight is answered RequestCancelled"
        (toJson code).compress "-32800"
    | .result value =>
      h.check "a request cancelled in flight is answered RequestCancelled" false value.compress
    -- Exactly one response, and the session is still serving.
    request 3 "$/lean-fmt/health" (Json.mkObj [])
    match ← awaitResponse 3 with
    | .result _ => h.check "and the session serves the next request" true
    | .error _ message => h.check "and the session serves the next request" false message
    Ipc.shutdown 4
    return (uncancelled, cancelled)
  h.checkEq "the cancellation session exits cleanly" code 0
  IO.println s!"     uncancelled {uncancelled} ms, cancelled {cancelled} ms"
  -- Cancellation is sent at 400 ms, so a cancellation that reached the active snapshot returns well
  -- inside the uncancelled cost. Half is a wide
  -- margin chosen so the check does not depend on this machine's speed; the printed pair is the
  -- measurement.
  h.check "and it returned in a fraction of the uncancelled cost"
    (cancelled * 2 < uncancelled) s!"uncancelled {uncancelled} ms, cancelled {cancelled} ms"

/-! ## 7. Memory stability over 100 requests (§13)

§13's promise is one bounded document snapshot and one richest current-version envelope, with no
per-request snapshot chain or report history. The observable form is that the session's resident size
after a hundred requests is not meaningfully above its resident size after the first. -/

/-- Resident size of a process and everything below it, in KiB, from `ps`.

The subtree measurement also includes the specialized organize-import validation child used by odd
requests; the persistent document analyzer itself lives in the server process. -/
private def subtreeRssKiB (rootPid : Nat) : IO Nat := do
  let output ← IO.Process.run { cmd := "ps", args := #["-Ao", "ppid=,pid=,rss="] }
  let rows := output.splitOn "\n" |>.filterMap fun line =>
    match line.splitOn " " |>.filter (!·.isEmpty) with
    | [parent, pid, rss] => do return (← parent.toNat?, ← pid.toNat?, ← rss.toNat?)
    | _ => none
  let rec descendants (frontier : List Nat) (seen : List Nat) (fuel : Nat) : List Nat :=
    match fuel with
    | 0 => seen
    | fuel + 1 =>
      let children := rows.filterMap fun (parent, pid, _) =>
        if frontier.contains parent && !seen.contains pid then some pid else none
      if children.isEmpty then seen else descendants children (seen ++ children) fuel
  let family := descendants [rootPid] [rootPid] 8
  return rows.foldl (init := 0) fun total (_, pid, rss) =>
    if family.contains pid then total + rss else total

private def memoryStability (h : Harness) : IO Unit := do
  let uri := s!"file://{h.root}/tests/check/Findings.lean"
  let ourPid := (← IO.Process.getPID).toNat
  let child ← IO.Process.spawn { ipcStdioConfig with
    cmd := h.application
    args := #["lsp", "--root", h.root]
    cwd := some h.root
    env := #[("LEAN_NUM_THREADS", some "1")] }
  -- The server is our only child, so its pid is the one `ps` reports under ours.
  let output ← IO.Process.run { cmd := "ps", args := #["-Ao", "ppid=,pid="] }
  let serverPid := output.splitOn "\n" |>.findSome? fun line =>
    match line.splitOn " " |>.filter (!·.isEmpty) with
    | [parent, pid] => if parent.toNat? == some ourPid then pid.toNat? else none
    | _ => none
  let action : IpcM (Nat × Nat × Nat) := do
    discard <| initializeSession h.root
    openDocument uri findingsSource
    let mut first := 0
    let mut peak := 0
    let mut last := 0
    for i in [0:100] do
      -- Alternated so the hundred are not all one code path: formatting reads the richest envelope;
      -- code actions share it for fix-all/quickfix and separately validate organize-imports.
      if i % 2 == 0 then
        request (i + 10) "textDocument/formatting" (documentParam uri)
      else
        request (i + 10) "textDocument/codeAction" (Json.mkObj [
          ("textDocument", Json.mkObj [("uri", Json.str uri)]),
          ("range", range 3 0 3 0),
          ("context", Json.mkObj [("diagnostics", Json.arr #[])])])
      match ← awaitResponse (i + 10) with
      | .result _ => pure ()
      | .error _ message => h.check s!"request {i} is answered" false message
      if let some pid := serverPid then
        let rss ← subtreeRssKiB pid
        if i == 0 then first := rss
        if rss > peak then peak := rss
        last := rss
    Ipc.shutdown 500
    return (first, peak, last)
  let (first, peak, last) ← action.run child
  let code ← child.wait
  h.checkEq "the hundred-request session exits cleanly" code 0
  IO.println s!"     subtree RSS: first {first} KiB, peak {peak} KiB, last {last} KiB"
  h.check "the server was found and measured" (first > 0) "ps reported nothing under this process"
  -- A session that leaked a child, a report, or a document per request would climb monotonically. The
  -- bound is generous on purpose: this asserts the absence of growth, not an allocator's behavior.
  h.check "and the session does not grow across a hundred requests"
    (last < first + 262144 && last * 2 < first * 3)
    s!"first {first} KiB, last {last} KiB, peak {peak} KiB"

end LeanFmt.Acceptance

open LeanFmt.Acceptance in
public def main (args : List String) : IO UInt32 := do
  let [application, root] := args
    | IO.eprintln "usage: Acceptance.lean <lean-fmt binary> <repository root>"; return 2
  let h : Harness := { failures := ← IO.mkRef #[], root, application }
  lifecycle h
  malformed h
  unicode h
  reconfiguration h
  codeActions h
  cancellation h
  memoryStability h
  let failures ← h.failures.get
  if failures.isEmpty then
    IO.println "lean-fmt language server acceptance passed"
    return 0
  else
    IO.println s!"{failures.size} acceptance checks failed: {String.intercalate ", " failures.toList}"
    return 1
