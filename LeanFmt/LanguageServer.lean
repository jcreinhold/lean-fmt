module

import all LeanFmt.Application
import all LeanFmt.LosslessSource
import Lean.Data.Lsp
import Std.Sync.Channel
import Std.Sync.Mutex

open System

/- The Language Server Protocol surface.

`ruff-17` RLP-DOCUMENTS. The capability and state model this implements is frozen in
`docs/projects/ruff-17-lsp/notes/01-protocol.md`; this module is the transport and document lifecycle
half of it, and computes no findings and renders no text — `RLP-FEATURES` adds those on top of the
document store below.

The namespace is `LanguageServer` and not `Lsp` because `Lean.Lsp` is opened throughout and a
namespace of the same name would make every `Lsp.Position` ambiguous at the one boundary that must
never guess which position type it means. -/

namespace LeanFmt.Internal.LanguageServer

open LeanFmt.Internal LeanFmt.Internal.Application LeanFmt.Internal.Project
open Lean Lean.JsonRpc

/-! ## Bounds

Every bound is a refusal, never a truncation: exceeding one produces an error response and leaves the
session running. `notes/01-protocol.md` §6, §9, §13. -/

/-- The largest framed message body accepted, matching `serve`'s line bound (`Service.lean:13`). -/
def maxMessageBytes : Nat := 32 * 1024 * 1024

/-- The largest document body accepted, matching `serve`'s source bound (`Service.lean:15`). -/
def maxDocumentBytes : Nat := 16 * 1024 * 1024

/-- How many documents may be open at once. A client that opens more has stopped closing them; an
editor with a hundred tabs is unusual, and this is two hundred and fifty-six. -/
def maxOpenDocuments : Nat := 256

/-- How many messages may wait behind the one being served. The queue is bounded because the reader
runs ahead of the worker by construction (§9), so an unbounded one would grow with typing speed. -/
def maxQueuedMessages : Nat := 64

structure ServerOptions where
  root : FilePath := "."
  maxMemoryGiB : Nat := 8
  configPath? : Option FilePath := none
  select : Array String := #[]
  ignore : Array String := #[]
  preview : Bool := false
  /-- Offer unsafe fixes as code actions. Consumed by `RLP-FEATURES`; carried here because it is an
  initialization option and initialization is this prompt's. -/
  unsafeFixes : Bool := false

/-! ## Frames

The reply side is Lean's (`Lean.IO.FS.Stream.writeSerializedLspMessage`, whose single `putStr` is what
makes a write from the reader safe alongside one from the worker). The read side is ours, for two
reasons measured rather than assumed:

- `Lean.IO.FS.Stream.readLspMessage` collapses end-of-input, a malformed header, and an unparseable
  body into one `IO.userError` string (`Lean/Data/Lsp/Communication.lean:52-53, 76-81`). A server
  required to recover from a malformed message and to exit cleanly at end of input cannot tell those
  apart without matching on error text.
- `readJson`/`readUTF8` issue a single `h.read n` (`Lean/Data/Json/Stream.lean:21-30`), which is one
  syscall and may return fewer bytes than asked. A 16 MiB `didOpen` over a pipe does not arrive in one
  read.

The same split governs `Lean.Server.Utils`, whose `replaceLspRange` would otherwise be `applyChange`
below: it converts both endpoints with `lspPosToUtf8Pos` and clamps neither, and an unclamped client
position resolves *past the end of the buffer* (§4). Fifteen lines are cheaper than that defect.

`notes/01-protocol.md` §2 named Lean's reader as the framing layer; this is the amendment, and
`results/02-documents.md` records it. -/

inductive Frame where
  /-- A framed body that parsed as JSON. Whether it is a valid message is the dispatcher's question. -/
  | message (json : Json)
  /-- Framed, but the body was not JSON, or the header was not a header. The session continues. -/
  | malformed (detail : String)
  /-- End of input. -/
  | closed

/-- Read exactly `count` bytes, or fewer if the stream ends first.

`IO.FS.Stream.read` is one read: it returns what is available, not what was asked for. -/
private partial def readExactly (stream : IO.FS.Stream) (count : Nat)
    (acc : ByteArray := .empty) : IO ByteArray := do
  if acc.size >= count then return acc
  let chunk ← stream.read (USize.ofNat (count - acc.size))
  if chunk.isEmpty then return acc
  readExactly stream count (acc ++ chunk)

/-- One `Content-Length` header block and its body.

Header fields other than `Content-Length` are read and ignored, which is what the specification
requires of `Content-Type`. A header line that is not `name: value` ends the header block as malformed
rather than being skipped: a client that emits one has lost frame sync, and continuing to read would
interpret its body as headers. -/
partial def readFrame (stream : IO.FS.Stream) : IO Frame := do
  -- `length?` and `seen` are separate because a header block that ends without a `Content-Length` is
  -- a malformed *message*, not end of input. Collapsing the two is how a server recovering from one
  -- bad header silently stops reading: the blank line that follows it looks exactly like EOF.
  -- A bad field does not return immediately: the rest of the header block is drained first, so the
  -- next read starts at the next frame instead of at this block's leftovers. Returning early is how
  -- one malformed header becomes a run of them.
  let rec headers (length? : Option Nat) (error? : Option String) (seen : Bool) :
      IO (Except String (Option Nat)) := do
    let line ← stream.getLine
    if line.isEmpty then
      -- Genuine end of input, unless it truncated a header block already begun.
      return if seen then .error (error?.getD "input ended inside a message header") else .ok none
    if line == "\r\n" || line == "\n" then
      return match error?, length? with
        | some detail, _ => .error detail
        | none, some count => .ok (some count)
        | none, none => .error "message header has no Content-Length"
    let field := line.trimAscii.copy
    let keep (detail : String) : Option String := error?.getD detail
    match field.splitOn ": " with
    | [name, value] =>
      if name.toLower == "content-length" then
        match value.toNat? with
        | some count => headers (some count) error? true
        | none => headers length? (keep s!"Content-Length is not a number: {value}") true
      else headers length? error? true
    | _ => headers length? (keep s!"malformed header field: {field}") true
  match ← headers none none false with
  | .error detail => return .malformed detail
  | .ok none => return .closed
  | .ok (some count) =>
    if count > maxMessageBytes then
      -- The body is drained rather than left in the stream: leaving it would make the next read start
      -- mid-body and turn one oversized message into an unbounded run of malformed ones.
      discard <| readExactly stream count
      return .malformed s!"message exceeds {maxMessageBytes} bytes"
    let bytes ← readExactly stream count
    if bytes.size < count then return .closed
    let some body := String.fromUTF8? bytes
      | return .malformed "message body is not valid UTF-8"
    match Json.parse body with
    | .ok json => return .message json
    | .error detail => return .malformed s!"message body is not valid JSON: {detail}"

/-- Serialized output, serialized. One `Std.Mutex` so a notification written while a response is being
written cannot interleave with it. -/
structure Sink where
  private mk ::
  private stream : Std.Mutex IO.FS.Stream

def Sink.of (stream : IO.FS.Stream) : BaseIO Sink :=
  return ⟨← Std.Mutex.new stream⟩

def Sink.write (sink : Sink) (message : JsonRpc.Message) : IO Unit :=
  sink.stream.atomically do (← get).writeLspMessage message

def Sink.respond (sink : Sink) (id : RequestID) (result : Json) : IO Unit :=
  sink.write (.response id result)

def Sink.fail (sink : Sink) (id : RequestID) (code : ErrorCode) (message : String) : IO Unit :=
  sink.write (.responseError id code message none)

def Sink.notify (sink : Sink) (method : String) (params : Json) : IO Unit :=
  sink.write (.notification method (Json.toStructured? params).toOption)

/-- `window/logMessage`. Severity 1 error, 2 warning, 3 info, 4 log. -/
def Sink.log (sink : Sink) (severity : Nat) (text : String) : IO Unit :=
  sink.notify "window/logMessage" (Json.mkObj [("type", severity), ("message", text)])

/-- `window/showMessage` — the user-visible channel, reserved for the things a user must act on: a
document this server will not serve, and a workspace it is not covering. -/
def Sink.show (sink : Sink) (severity : Nat) (text : String) : IO Unit :=
  sink.notify "window/showMessage" (Json.mkObj [("type", severity), ("message", text)])

/-! ## Positions

One layer, over the **normalized** document. `notes/01-protocol.md` §4. -/

/-- The index of the last addressable LSP line.

**Not** `FileMap.getLastLine`, and the difference is a real off-by-one rather than a naming preference.
`positions` holds one entry per line start *plus* a final end-of-string entry, so its size is the line
count plus one — and when the document ends in a newline that final entry repeats the last line start
(`Lean/Data/Position.lean:41-44`). A document of three LSP lines therefore has four entries, and
`size - 1` addresses a line that is not there. -/
def lastLine (text : FileMap) : Nat := text.positions.size - 2

/-- The half-open byte range of an LSP line, excluding its terminator.

The terminator between line `n` and line `n+1` is exactly the byte before `positions[n+1]`. That
"exactly one byte" is a property of the *normalized* text, and it is the reason this operation is only
ever applied to normalized text. -/
def lineBytes (text : FileMap) (line : Nat) : Nat × Nat :=
  let last := lastLine text
  let line := min line last
  let start := (text.positions[line]!).byteIdx
  let stop :=
    if line < last then max start ((text.positions[line + 1]!).byteIdx - 1)
    else text.source.utf8ByteSize
  (start, stop)

/-- Bring a client position inside the document.

This is not defensive coding around a rare input; it is the correction for a measured behavior.
`FileMap.lspPosToUtf8Pos` does not validate: on a 43-byte document, LSP `(0,9999)` answers byte
**10003** (`evidence/01-position-probe.txt`). Every position that arrives from a client passes through
here before it is converted, so no offset derived from a client position can leave the buffer. -/
def clampPosition (text : FileMap) (position : Lsp.Position) : Lsp.Position :=
  let line := min position.line (lastLine text)
  let (start, stop) := lineBytes text line
  let width := Lean.String.utf16Length (String.Pos.Raw.extract text.source ⟨start⟩ ⟨stop⟩)
  { line, character := min position.character width }

/-- A clamped client position as a byte offset into the normalized document. -/
def offsetOf (text : FileMap) (position : Lsp.Position) : Nat :=
  (text.lspPosToUtf8Pos (clampPosition text position)).byteIdx

/-- A byte offset in the normalized document as a client position.

The offset must lie on a codepoint boundary: byte 20 of the astral fixture, interior to a character,
answers column 39 rather than an error (`evidence/01-position-probe.txt`). Every offset this server
converts outward comes from the compiler or from a layout mark, both of which are boundaries. -/
def positionOf (text : FileMap) (offset : Nat) : Lsp.Position :=
  text.utf8PosToLspPos ⟨min offset text.source.utf8ByteSize⟩

/-- The whole document as a range, for a full-document `TextEdit`. -/
def wholeDocument (text : FileMap) : Lsp.Range :=
  { start := ⟨0, 0⟩, «end» := positionOf text text.source.utf8ByteSize }

/-! ## Documents -/

/-- One open document.

The text is stored **normalized** and exactly once: `FileMap.source` is the buffer, and the identity
needed to resolve configuration and the exact Lake setup is re-derived per request through
`Project.unsavedTarget`, which reads no file content. Keeping a `SourceTarget` here instead would hold
a second copy of every open buffer. -/
structure Document where
  uri : String
  /-- The client's own path, as `System.Uri.fileUriToPath?` recovered it. Errors name this. -/
  path : FilePath
  /-- Root-relative, the form configuration and discovery are keyed by. -/
  relativePath : String
  text : FileMap
  /-- Decided once, at open, from the bytes the client first sent; edits do not change a file's
  line-ending convention, and output is denormalized back to it (`notes` §4). -/
  lineEndings : LineEndings
  version : Int

def Document.source (document : Document) : String := document.text.source

/-- Why a document cannot be served. The text is the user-facing message; it names the URI the client
sent, as every path-taking surface in this product names the caller's own argument. -/
abbrev Rejection := String

/-! ## Session -/

structure Session where
  private mk ::
  options : ServerOptions
  root : FilePath
  project : Project.Snapshot
  sink : Sink
  /-- Replaced wholesale on `workspace/didChangeConfiguration`; never mutated in place. -/
  discovery : IO.Ref Discovery.Discovery
  documents : IO.Ref (Std.HashMap String Document)
  /-- Documents the server has refused, with the reason. Kept so a refusal is explained once and its
  later requests are answered without re-deriving it — and so a refused document is never mistaken for
  an absent one, which would be answered "unknown document". -/
  refusals : IO.Ref (Std.HashMap String Rejection)
  /-- Request ids the client has cancelled. Written by the reader, read by the worker, so it is a
  mutex and not a ref. -/
  cancelled : Std.Mutex (Std.HashSet RequestID)
  initialized : IO.Ref Bool
  shuttingDown : IO.Ref Bool

/-- Whether the client cancelled this request while it waited. -/
def Session.cancelled? (session : Session) (id : RequestID) : IO Bool :=
  session.cancelled.atomically do return (← get).contains id

def Session.recordCancellation (session : Session) (id : RequestID) : IO Unit :=
  session.cancelled.atomically do modify (·.insert id)

def Session.forgetCancellation (session : Session) (id : RequestID) : IO Unit :=
  session.cancelled.atomically do modify (·.erase id)

/-! ## Admission

`notes/01-protocol.md` §5. Identity, not content, decides whether a buffer can be served at all. -/

/-- Resolve a document URI to a servable identity, or say why not.

The order is the frozen one, and each clause names the URI the client sent:

1. not a `file:` URI — `untitled:` buffers land here, and they land here because they have no location,
   therefore no closest configuration, therefore no answer this server could give that would agree with
   the answer the same bytes get on disk;
2. every gate `Project.unsavedTarget` applies — inside the root, `.lean`, and the `.lake` floor;
3. `force-exclude`, which `unsavedTarget` does not evaluate and `Project.load` does for explicitly
   named paths (`Project.lean:221-226`). An editor opening whatever the user clicked is not the
   deliberate act of typing a path: if `lean-fmt format` reports nothing for a vendored file, the
   editor must report nothing for the same bytes, or the editor has become a second configuration path
   answering differently than the command line. -/
def admit (session : Session) (uri : String) :
    IO (Except Rejection (FilePath × String)) := do
  let some path := System.Uri.fileUriToPath? uri
    | return .error s!"document has no file location, so it has no project configuration: {uri}"
  let discovery ← session.discovery.get
  let target ←
    try
      -- The empty source is deliberate: this asks only the identity question, and `unsavedTarget`
      -- reads no file for content.
      Except.ok <$> Project.unsavedTarget session.project.workspace discovery session.root
        path.toString "" (spelling? := some uri)
    catch error => pure (.error s!"{error}")
  match target with
  | .error message => return .error message
  | .ok target =>
    if target.config.forceExclude &&
        discovery.explain target.relativePath != Discovery.Gate.selected then
      return .error s!"document is excluded by this project's configuration \
        ({(discovery.explain target.relativePath).describe}): {uri}"
    return .ok (target.path, target.relativePath)

/-- The target a request runs against: the open document's bytes at its own identity.

Built per request rather than stored, so there is one copy of the buffer in the process. -/
def Session.targetOf (session : Session) (document : Document) : IO Project.SourceTarget := do
  Project.unsavedTarget session.project.workspace (← session.discovery.get) session.root
    document.path.toString document.source

/-! ## Text synchronization

Incremental, and the whole of it is `applyChange`. `notes/01-protocol.md` §6. -/

/-- Apply one content change to a normalized document.

Both endpoints are clamped before conversion (§4) and the result is re-ordered, so an inverted or
out-of-range range from a client deletes a well-defined region of the buffer instead of an arbitrary
one. Inserted text is normalized on the way in for the same reason the document is: one coordinate
system, and it is the compiler's. -/
def applyChange (text : FileMap) : Lsp.TextDocumentContentChangeEvent → FileMap
  | .rangeChange range newText =>
    let start := offsetOf text range.start
    let stop := max start (offsetOf text range.end)
    let before := String.Pos.Raw.extract text.source ⟨0⟩ ⟨start⟩
    let after := String.Pos.Raw.extract text.source ⟨stop⟩ ⟨text.source.utf8ByteSize⟩
    FileMap.ofString (before ++ (LosslessSource.normalize newText).1 ++ after)
  | .fullChange newText => FileMap.ofString (LosslessSource.normalize newText).1

def applyChanges (text : FileMap) (changes : Array Lsp.TextDocumentContentChangeEvent) : FileMap :=
  changes.foldl applyChange text

/-! ## Capabilities

Ours, because the toolchain has none for formatting: `Lean.Lsp.ServerCapabilities` has eighteen fields
and no formatting provider, and no formatting method is implemented anywhere in `Lean/Server/`
(`evidence/01-lsp-baseline.md` §3-§4). So there is nothing to contend with either. -/

def serverCapabilities : Json :=
  Json.mkObj [
    ("textDocumentSync", Json.mkObj [
      ("openClose", true),
      -- 2 is incremental. Sync payload is per keystroke where analysis is per debounced request, so
      -- full sync would retransmit the buffer on every character (`notes` §6).
      ("change", (2 : Nat))
    ]),
    ("documentFormattingProvider", true),
    ("documentRangeFormattingProvider", true),
    ("codeActionProvider", Json.mkObj [
      ("codeActionKinds", Json.arr #["quickfix", "source.fixAll", "source.organizeImports"])
    ])
  ]

def serverInfo : Json :=
  Json.mkObj [("name", "lean-fmt"), ("version", "0.1.0")]

/-! ## Handlers -/

private def documentOf? (session : Session) (uri : String) : IO (Option Document) :=
  return (← session.documents.get).get? uri

/-- Answer a request that names a document the server cannot serve.

A refused document and an unopened one are different errors, and saying so is the difference between
a user fixing their configuration and a user filing a bug. -/
private def failForDocument (session : Session) (id : RequestID) (uri : String) : IO Unit := do
  match (← session.refusals.get).get? uri with
  | some reason => session.sink.fail id .invalidParams reason
  | none => session.sink.fail id .invalidParams s!"document is not open: {uri}"

private def publishEmpty (session : Session) (uri : String) : IO Unit :=
  session.sink.notify "textDocument/publishDiagnostics"
    (Json.mkObj [("uri", uri), ("diagnostics", Json.arr #[])])

/-- `initialize`. The workspace root is resolved here and never again: a `lakefile` change invalidates
the exact setup, and the honest answer to that is a restart, not a silently different workspace. -/
private def handleInitialize (session : Session) (id : RequestID) (params : Json) : IO Unit := do
  if ← session.initialized.get then
    session.sink.fail id .invalidRequest "initialize was already answered"
    return
  -- One root is served. A client offering several gets the one it asked for first and is told which
  -- ones it is not getting, rather than being quietly half-served (`notes` §10).
  let folders := (params.getObjValAs? (Array Json) "workspaceFolders").toOption.getD #[]
  if folders.size > 1 then
    let names := folders.filterMap fun folder => (folder.getObjValAs? String "uri").toOption
    session.sink.show 2 s!"lean-fmt serves one workspace root ({session.root}); \
      not serving: {String.intercalate ", " (names.toList.drop 1)}"
  session.initialized.set true
  session.sink.respond id (Json.mkObj [
    ("capabilities", serverCapabilities),
    ("serverInfo", serverInfo)
  ])

private def handleDidOpen (session : Session) (params : Json) : IO Unit := do
  let .ok document := params.getObjVal? "textDocument"
    | return
  let .ok uri := document.getObjValAs? String "uri" | return
  let .ok text := document.getObjValAs? String "text" | return
  let version := (document.getObjValAs? Int "version").toOption.getD 0
  if text.utf8ByteSize > maxDocumentBytes then
    let reason := s!"document exceeds {maxDocumentBytes} bytes: {uri}"
    session.refusals.modify (·.insert uri reason)
    session.sink.show 2 reason
    return
  if (← session.documents.get).size >= maxOpenDocuments then
    let reason := s!"lean-fmt serves at most {maxOpenDocuments} open documents: {uri}"
    session.refusals.modify (·.insert uri reason)
    session.sink.show 2 reason
    return
  match ← admit session uri with
  | .error reason =>
    session.refusals.modify (·.insert uri reason)
    -- Said once, to the user, in their own terms. No diagnostics are published for a refused
    -- document: an empty set would read as "clean".
    session.sink.show 2 s!"lean-fmt: {reason}"
  | .ok (path, relativePath) =>
    let (normalized, lineEndings) := LosslessSource.normalize text
    session.refusals.modify (·.erase uri)
    session.documents.modify (·.insert uri {
      uri, path, relativePath, lineEndings, version
      text := FileMap.ofString normalized
    })

private def handleDidChange (session : Session) (params : Json) : IO Unit := do
  let .ok identifier := params.getObjVal? "textDocument" | return
  let .ok uri := identifier.getObjValAs? String "uri" | return
  let some document ← documentOf? session uri | return
  let version := (identifier.getObjValAs? Int "version").toOption.getD document.version
  -- Strictly increasing, as the session rule already is for `serve` (`Service.lean:50-51`). An equal
  -- or older version is a client bug; applying it would move the buffer under a request in flight.
  if version <= document.version then
    session.sink.log 2
      s!"ignoring a document change at version {version}, not newer than {document.version}: {uri}"
    return
  let .ok changes := params.getObjValAs? (Array Lsp.TextDocumentContentChangeEvent) "contentChanges"
    | session.sink.log 1 s!"unparseable contentChanges for {uri}"
      return
  let text := applyChanges document.text changes
  if text.source.utf8ByteSize > maxDocumentBytes then
    -- The document is closed rather than left at a stale version: continuing to answer from bytes the
    -- client has since edited past is exactly the stale publication the freeze forbids.
    session.documents.modify (·.erase uri)
    let reason := s!"document grew past {maxDocumentBytes} bytes and is no longer served: {uri}"
    session.refusals.modify (·.insert uri reason)
    publishEmpty session uri
    session.sink.show 2 reason
    return
  session.documents.modify (·.insert uri { document with text, version })

private def handleDidClose (session : Session) (params : Json) : IO Unit := do
  let .ok identifier := params.getObjVal? "textDocument" | return
  let .ok uri := identifier.getObjValAs? String "uri" | return
  session.documents.modify (·.erase uri)
  session.refusals.modify (·.erase uri)
  -- Clearing is not optional: a client keeps the last published set until told otherwise, so a closed
  -- document would keep showing diagnostics for bytes nobody holds.
  publishEmpty session uri

/-- `workspace/didChangeConfiguration`. Re-runs discovery and re-admits every open document.

Discovery is replaced wholesale rather than patched, so there is no state in which half the documents
are resolved against the old configuration. A document that the new configuration excludes is closed
and its diagnostics cleared; one that a previous configuration excluded is not reopened, because the
server does not hold the bytes of a document it refused — the client resends them on the next open. -/
private def handleDidChangeConfiguration (session : Session) : IO Unit := do
  let configPath? := session.options.configPath?.map fun path =>
    if path.isAbsolute then path else session.root / path
  let discovery ← Discovery.run session.root configPath?
  session.discovery.set discovery
  for notice in discovery.fallback.notices do
    session.sink.log 3 s!"lean-fmt: {notice}"
  let documents ← session.documents.get
  for (uri, _) in documents.toList do
    match ← admit session uri with
    | .ok _ => pure ()
    | .error reason =>
      session.documents.modify (·.erase uri)
      session.refusals.modify (·.insert uri reason)
      publishEmpty session uri
      session.sink.show 2 s!"lean-fmt: {reason}"
  session.sink.log 3 "lean-fmt: configuration reloaded"

/-- `$/lean-fmt/health`. The same question `serve`'s `health` answers, plus what only a long-running
session can be asked: how much it is holding. -/
private def handleHealth (session : Session) (id : RequestID) : IO Unit := do
  let documents ← session.documents.get
  let bytes := documents.fold (init := (0 : Nat)) fun total _ document =>
    total + document.source.utf8ByteSize
  session.sink.respond id (Json.mkObj [
    ("ready", true),
    ("root", session.root.toString),
    ("toolchain", s!"Lean {Lean.versionString} \
      ({session.project.workspace.lakeEnv.lean.githash})"),
    ("openDocuments", documents.size),
    ("openDocumentBytes", bytes),
    ("refusedDocuments", (← session.refusals.get).size)
  ])

/-! ## Dispatch -/

/-- Answer one message. Returns `true` when the session should stop reading.

Requests carry an id and must be answered exactly once, including when the answer is an error;
notifications carry none and are answered never. An unknown *notification* is ignored — the
specification requires it, since clients send `$/`-prefixed notifications servers need not know. -/
def dispatch (session : Session) (json : Json) : IO Bool := do
  let method? := (json.getObjValAs? String "method").toOption
  let id? := (json.getObjVal? "id").toOption.map fun value =>
    match value with
    | .str s => RequestID.str s
    | .num n => RequestID.num n
    | _ => RequestID.null
  let params := (json.getObjVal? "params").toOption.getD (Json.mkObj [])
  match method?, id? with
  | none, some id =>
    -- A response to something we never asked. Not our message; not an error we can answer.
    session.sink.log 4 s!"ignoring a client response with id {id}"
    return false
  | none, none =>
    session.sink.log 2 "ignoring a message with no method"
    return false
  | some method, none =>
    -- Notifications.
    if !(← session.initialized.get) && method != "exit" then return false
    match method with
    | "initialized" => return false
    | "exit" => return true
    | "textDocument/didOpen" => handleDidOpen session params; return false
    | "textDocument/didChange" => handleDidChange session params; return false
    | "textDocument/didClose" => handleDidClose session params; return false
    | "workspace/didChangeConfiguration" => handleDidChangeConfiguration session; return false
    | _ => return false
  | some method, some id =>
    -- Requests.
    if method == "initialize" then
      handleInitialize session id params
      return false
    unless ← session.initialized.get do
      session.sink.fail id .serverNotInitialized
        s!"lean-fmt received {method} before initialize"
      return false
    if ← session.shuttingDown.get then
      session.sink.fail id .invalidRequest s!"lean-fmt is shutting down and cannot answer {method}"
      return false
    -- Cancellation is checked at the moment of service, which is the only moment at which the answer
    -- is still worth not computing. A cancelled request is answered, not dropped: the specification
    -- requires every request to get exactly one response.
    if ← session.cancelled? id then
      session.forgetCancellation id
      session.sink.fail id .requestCancelled s!"{method} was cancelled"
      return false
    match method with
    | "shutdown" =>
      session.shuttingDown.set true
      session.sink.respond id Json.null
      return false
    | "$/lean-fmt/health" => handleHealth session id; return false
    | _ =>
      session.sink.fail id .methodNotFound s!"lean-fmt does not implement {method}"
      return false

/-! ## The loop

A reader task and a worker, joined by a bounded queue. `notes/01-protocol.md` §9.

The split exists for one reason: `$/cancelRequest` arrives *while* a request is being served, and a
single-threaded server cannot read it until it has finished the very thing being cancelled. So the
reader owns the stream, applies cancellation immediately, and hands everything else to the worker. -/

private inductive Work where
  | message (json : Json)
  | malformed (detail : String)
  deriving Inhabited

/-- Extract a request id without committing to the message being well formed. -/
private def idOf? (json : Json) : Option RequestID :=
  (json.getObjVal? "id").toOption.map fun value =>
    match value with
    | .str s => RequestID.str s
    | .num n => RequestID.num n
    | _ => RequestID.null

private partial def readLoop (session : Session) (input : IO.FS.Stream)
    (queue : Std.CloseableChannel.Sync Work) : IO Unit := do
  match ← readFrame input with
  | .closed => discard queue.close.toBaseIO
  | .malformed detail =>
    unless ← queue.trySend (Work.malformed detail) do
      session.sink.fail .null .internalError "lean-fmt request queue is full"
    readLoop session input queue
  | .message json =>
    let method? := (json.getObjValAs? String "method").toOption
    if method? == some "$/cancelRequest" then
      -- Applied here, not queued. Queuing a cancellation behind the request it cancels would make it
      -- arrive exactly too late, every time.
      if let some id := ((json.getObjVal? "params").toOption.bind idOf?) then
        session.recordCancellation id
      readLoop session input queue
    else if method? == some "exit" then
      discard <| queue.trySend (Work.message json)
      discard queue.close.toBaseIO
    else
      unless ← queue.trySend (Work.message json) do
        -- A full queue refuses; it does not grow and it does not drop silently. A request gets an
        -- error it can retry, a notification gets a log line, because a notification has no id to
        -- answer.
        match idOf? json with
        | some id =>
          session.sink.fail id .internalError
            s!"lean-fmt is behind: more than {maxQueuedMessages} messages are queued"
        | none =>
          session.sink.log 2
            s!"lean-fmt dropped a notification: more than {maxQueuedMessages} messages are queued"
      readLoop session input queue

private partial def workLoop (session : Session) (queue : Std.CloseableChannel.Sync Work) : IO UInt32 := do
  match ← queue.recv with
  | none => return 0
  | some (Work.malformed detail) =>
    -- Recovery, not termination: the frame was consumed, the session continues, and the client is
    -- told. There is no id to answer, because there was no parseable message.
    session.sink.fail .null .parseError s!"lean-fmt could not read a message: {detail}"
    workLoop session queue
  | some (Work.message json) =>
    let stop ←
      try dispatch session json
      catch error =>
        match idOf? json with
        | some id => session.sink.fail id .internalError s!"{error}"; pure false
        | none => session.sink.log 1 s!"lean-fmt: {error}"; pure false
    if stop then
      -- `exit` before `shutdown` is a protocol violation and exits non-zero, per the specification.
      return if ← session.shuttingDown.get then 0 else 1
    workLoop session queue

/-- Start one Language Server Protocol session on stdin/stdout.

Holds one Lake workspace and one discovery for its lifetime; writes no file and opens no result cache.
`Project.loadWorkspaceOnly` rather than `Project.load` because the client, not a selection walk, says
which documents exist — and a document may be a file that has never been saved. -/
def serveLanguageServer (options : ServerOptions) : IO UInt32 := do
  unless options.maxMemoryGiB > 0 do
    throw <| IO.userError "--max-memory must provide a nonzero operating envelope"
  let root ← IO.FS.realPath options.root
  let configPath? := options.configPath?.map fun path =>
    if path.isAbsolute then path else root / path
  let discovery ← Discovery.run root configPath?
  let project ← Project.loadWorkspaceOnly root
  let sink ← Sink.of (← IO.getStdout)
  let session : Session := {
    options, root, project, sink
    discovery := ← IO.mkRef discovery
    documents := ← IO.mkRef {}
    refusals := ← IO.mkRef {}
    cancelled := ← Std.Mutex.new {}
    initialized := ← IO.mkRef false
    shuttingDown := ← IO.mkRef false
  }
  for notice in discovery.fallback.notices do
    sink.log 3 s!"lean-fmt: {notice}"
  let queue : Std.CloseableChannel.Sync Work ←
    Std.CloseableChannel.Sync.new (capacity := some maxQueuedMessages)
  let input ← IO.getStdin
  let reader ← IO.asTask (prio := .dedicated) (readLoop session input queue)
  let code ← workLoop session queue
  -- The reader is already finished whenever the queue closed; waiting is what makes that true rather
  -- than probable, and it is what stops a half-read frame from outliving the session.
  discard <| IO.wait reader
  return code

end LeanFmt.Internal.LanguageServer
