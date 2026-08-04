/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.Analysis
import all LeanFmt.Application
import all LeanFmt.Basic
import all LeanFmt.LosslessSource

import Lean.Data.Lsp
import Std.Sync.Channel
import Std.Sync.Mutex

open System

/- The Language Server Protocol surface.

This module is the whole of the server: the transport and document store, and the diagnostics,
formatting, and code actions served from them.

It computes no formatter policy itself. Each admitted document owns one bounded incremental
frontend; its envelope enters `Application.ExactRun.streamEnvelope`, the same projection and
rendering path used by `--stdin`. What this module adds is the protocol: client coordinates,
document and analyzer lifetime, which fixes may be offered, and when to run an analysis.

The namespace is `LanguageServer` and not `Lsp` because `Lean.Lsp` is opened throughout, and a
namespace of the same name would make every `Lsp.Position` ambiguous. -/

namespace LeanFmt.Internal.LanguageServer

open LeanFmt.Internal LeanFmt.Internal.Application LeanFmt.Internal.Project
open Lean Lean.JsonRpc

/-! ## Bounds

Exceeding a bound produces an error response and leaves the session running. Nothing is truncated.
-/

/-- The largest framed message body accepted. -/
def maxMessageBytes : Nat :=
  32 * 1024 * 1024

/-- The largest document body accepted. -/
def maxDocumentBytes : Nat :=
  16 * 1024 * 1024

/-- How many documents may be open at once. A client that opens more has stopped closing
them. -/
def maxOpenDocuments : Nat :=
  256

/-- How many messages may wait behind the one being served. The queue is bounded because
the reader runs ahead of the worker by construction (§9), so an unbounded one would grow with
typing speed. -/
def maxQueuedMessages : Nat :=
  64

structure ServerOptions where
  root : FilePath := "."
  configPath? : Option FilePath := none
  select : Array String := #[]
  ignore : Array String := #[]
  preview : Bool := false
  /-- Offer unsafe fixes as code actions. A withheld fix produces no action rather than a
  disabled one: `CodeActionDisabled` would advertise a fix the product has decided not to apply
  (`notes` §8). -/
  unsafeFixes : Bool := false
  /-- Quiet interval before a changed document is analyzed. Every analysis is one exact
  frontend run over the whole buffer (`evidence/03-stream-cost.txt`), so this is the
  difference between one run per pause and one run per character. -/
  debounceMs : Nat := 150

/-- The rule selection every document's plan is resolved against. -/
def ServerOptions.selection (options : ServerOptions) : CliSelection :=
  { select := options.select, ignore := options.ignore, preview := options.preview }

/-! ## Frames

The reply side is Lean's `Lean.IO.FS.Stream.writeSerializedLspMessage`; its single `putStr`
makes a write from the reader safe alongside one from the worker. The read side is ours, for two
reasons:

- `Lean.IO.FS.Stream.readLspMessage` collapses end-of-input, a malformed header, and an unparseable
  body into one `IO.userError` string (`Lean/Data/Lsp/Communication.lean:52-53, 76-81`). A server
  required to recover from a malformed message and to exit cleanly at end of input cannot tell
  those apart without matching on error text.
- `readJson`/`readUTF8` issue a single `h.read n` (`Lean/Data/Json/Stream.lean:21-30`), which is
  one syscall and may return fewer bytes than asked. A 16 MiB `didOpen` over a pipe does not arrive
  in one read.

The same split governs `Lean.Server.Utils`, whose `replaceLspRange` would otherwise be
`applyChange` below: it converts both endpoints with `lspPosToUtf8Pos` and clamps neither, so an
unclamped client position resolves past the end of the buffer (§4).

Lean's reader was named as the framing layer; this is the amendment, and it records the decision. -/

inductive Frame where
  /-- A framed body that parsed as JSON. The dispatcher decides whether it is a valid message. -/
  | message (json : Json)
  /-- Framed, but the body was not JSON, or the header was not a header. The session continues. -/
  | malformed (detail : String)
  /-- End of input. -/
  | closed

/-- Read exactly `count` bytes, or fewer if the stream ends first.

`IO.FS.Stream.read` is one read: it returns what is available, not what was asked for. -/
private partial def readExactly (stream : IO.FS.Stream) (count : Nat) (acc : ByteArray := .empty) :
    IO ByteArray := do
  if acc.size >= count then
    return acc
  let chunk ← stream.read (USize.ofNat (count - acc.size))
  if chunk.isEmpty then
    return acc
  readExactly stream count (acc ++ chunk)

/-- One `Content-Length` header block and its body.

Header fields other than `Content-Length` are read and ignored, which is what the
specification requires of `Content-Type`. A header line that is not `name: value` ends the header
block as malformed rather than being skipped: a client that emits one has lost frame sync, and
continuing to read would interpret its body as headers. -/
partial def readFrame (stream : IO.FS.Stream) : IO Frame := do
  -- `length?` and `seen` are separate because a header block that ends without a
  -- `Content-Length` is a malformed message, not end of input. If the two were collapsed, a
  -- server recovering from one bad header would stop reading: the blank line after it looks like
  -- EOF.
  -- A bad field does not return immediately: the rest of the header block is drained first, so the
  -- next read starts at the next frame instead of at this block's leftovers. Returning early would
  -- turn one malformed header into a run of them.
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
        | some count =>
          headers (some count) error? true
        | none =>
          headers length? (keep s!"Content-Length is not a number: {value}") true
      else
        headers length? error? true
    | _ =>
      headers length? (keep s!"malformed header field: {field}") true
  match ← headers none none false with
  | .error detail =>
    return .malformed detail
  | .ok none =>
    return .closed
  | .ok (some count) =>
    if count > maxMessageBytes then
      -- The body is drained rather than left in the stream: leaving it would make the next
      -- read start mid-body and turn one oversized message into an unbounded run of malformed
      -- ones.
      discard <| readExactly stream count
      return .malformed s!"message exceeds {maxMessageBytes} bytes"
    let bytes ← readExactly stream count
    if bytes.size < count then
      return .closed
    let some body := String.fromUTF8? bytes | return .malformed "message body is not valid UTF-8"
    match Json.parse body with
    | .ok json =>
      return .message json
    | .error detail =>
      return .malformed s!"message body is not valid JSON: {detail}"

/-- One `Std.Mutex`, so a notification written while a response is being written cannot interleave
with it. -/
structure Sink where private mk ::
  private stream : Std.Mutex IO.FS.Stream

def Sink.of (stream : IO.FS.Stream) : BaseIO Sink :=
  return ⟨← Std.Mutex.new stream⟩

def Sink.write (sink : Sink) (message : JsonRpc.Message) : IO Unit :=
  sink.stream.atomically do
    (← get).writeLspMessage message

def Sink.respond (sink : Sink) (id : RequestID) (result : Json) : IO Unit :=
  sink.write (.response id result)

def Sink.fail (sink : Sink) (id : RequestID) (code : ErrorCode) (message : String) : IO Unit :=
  sink.write (.responseError id code message none)

def Sink.notify (sink : Sink) (method : String) (params : Json) : IO Unit :=
  sink.write (.notification method (Json.toStructured? params).toOption)

/-- `window/logMessage`. Severity 1 error, 2 warning, 3 info, 4 log. -/
def Sink.log (sink : Sink) (severity : Nat) (text : String) : IO Unit :=
  sink.notify "window/logMessage" (Json.mkObj [("type", severity), ("message", text)])

/-- `window/showMessage` — the user-visible channel, reserved for the things a user must
act on: a document this server will not serve, and a workspace it is not covering. -/
def Sink.show (sink : Sink) (severity : Nat) (text : String) : IO Unit :=
  sink.notify "window/showMessage" (Json.mkObj [("type", severity), ("message", text)])

/-! ## Positions

One layer, over the **normalized** document. -/

/-- The index of the last addressable LSP line.

Not `FileMap.getLastLine`: the difference is an off-by-one. `positions` holds one entry per line
start *plus* a final end-of-string entry, so its size is the line count plus one — and when the
document ends in a newline that final entry repeats the last line start
(`Lean/Data/Position.lean:41-44`). A document of three LSP lines therefore has four entries, and
`size - 1` addresses a line that is not there. -/
def lastLine (text : FileMap) : Nat :=
  text.positions.size - 2

/-- The half-open byte range of an LSP line, excluding its terminator.

The terminator between line `n` and line `n+1` is the byte before `positions[n+1]`. That
single byte holds only for *normalized* text, which is the only text this operation is applied
to. -/
def lineBytes (text : FileMap) (line : Nat) : Nat × Nat :=
  let last := lastLine text
  let line := min line last
  let start := (text.positions[line]!).byteIdx
  let stop :=
    if line < last then max start ((text.positions[line + 1]!).byteIdx - 1)
    else text.source.utf8ByteSize
  (start, stop)

/-- Bring a client position inside the document.

`FileMap.lspPosToUtf8Pos` does not validate: a client position past the end of a line
answers a byte offset past the end of the document (`evidence/01-position-probe.txt`). Every
position that arrives from a client passes through here before it is converted, so no offset
derived from a client position can leave the buffer. -/
def clampPosition (text : FileMap) (position : Lsp.Position) : Lsp.Position :=
  let line := min position.line (lastLine text)
  let (start, stop) := lineBytes text line
  let width := Lean.String.utf16Length (String.Pos.Raw.extract text.source ⟨start⟩ ⟨stop⟩)
  { line, character := min position.character width }

/-- A clamped client position as a byte offset into the normalized document. -/
def offsetOf (text : FileMap) (position : Lsp.Position) : Nat :=
  (text.lspPosToUtf8Pos (clampPosition text position)).byteIdx

/-- A byte offset in the normalized document as a client position.

The offset must lie on a codepoint boundary: an offset interior to a character answers a
column rather than an error (`evidence/01-position-probe.txt`). Every offset this server converts
outward comes from the compiler or from a layout mark, both of which are boundaries. -/
def positionOf (text : FileMap) (offset : Nat) : Lsp.Position :=
  text.utf8PosToLspPos ⟨min offset text.source.utf8ByteSize⟩

/-- The whole document as a range, for a full-document `TextEdit`. -/
def wholeDocument (text : FileMap) : Lsp.Range :=
  { start := ⟨0, 0⟩, «end» := positionOf text text.source.utf8ByteSize }

/-! ## Documents -/

/-- One open document.

The text is stored **normalized** and exactly once: `FileMap.source` is the buffer, and the
identity needed to resolve configuration and the exact Lake setup is re-derived per request through
`Project.unsavedTarget`, which reads no file content. Keeping a `SourceTarget` here instead would
hold a second copy of every open buffer. -/
structure Document where
  uri : String
  /-- The client's own path, as `System.Uri.fileUriToPath?` recovered it. Errors name this. -/
  path : FilePath
  /-- Root-relative, the form configuration and discovery are keyed by. -/
  relativePath : String
  text : FileMap
  /-- Decided once, at open, from the bytes the client first sent; edits do not change a
  file's line-ending convention, and output is denormalized back to it (`notes` §4). -/
  lineEndings : LineEndings
  version : Int
  /-- One bounded last-good frontend session for this document's normalized lineage. -/
  analyzer : IncrementalAnalyzer

def Document.source (document : Document) : String :=
  document.text.source

private structure DocumentEnvelope where
  version : Int
  semantic : Bool
  occurrences : Bool
  format? : Option FormatConfig
  envelope : AnalysisEnvelope

private def DocumentEnvelope.meets (cached : DocumentEnvelope) (version : Int)
    (semantic occurrences : Bool) (format? : Option FormatConfig) : Bool :=
  cached.version == version && (!semantic || cached.semantic) &&
      (!occurrences || cached.occurrences) &&
    match format? with
    | some format => cached.format? == some format
    | none => true

/-- Why a document cannot be served. The text is the user-facing message; it names the URI
the client sent, as every path-taking surface in this product names the caller's own argument. -/
abbrev Rejection :=
  String

/-! ## Session -/

structure Session where private mk ::
  /-- The options the process started with. `root` is read from here and only from here: one Lake
  workspace is fixed when the session opens, and a client that asks to move it is told to restart
  (§3, §10). -/
  options : ServerOptions
  /-- The options a client may still change: rule selection, preview, unsafe fixes, the
  quiet interval, and the configuration path. Written by `initialize` from `initializationOptions`,
  and read per request — so a setting is never captured into a closure that outlives it. -/
  settings : IO.Ref ServerOptions
  root : FilePath
  project : Project.Snapshot
  /-- One exact capability for the session. It resolves exact module setups for document
  analyzers and supplies the shared projection/rendering path; workspace loading and discovery are
  not paid per request. The specialized organize-imports operation still uses its isolated exact
  child. -/
  run : Application.ExactRun
  sink : Sink
  /-- Replaced wholesale on `workspace/didChangeConfiguration`; never mutated in place. -/
  discovery : IO.Ref Discovery.Discovery
  documents : IO.Ref (Std.HashMap String Document)
  /-- Documents the server has refused, with the reason. Kept so a refusal is explained once
  and its later requests are answered without re-deriving it, and so a refused document is never
  mistaken for an unopened one. -/
  refusals : IO.Ref (Std.HashMap String Rejection)
  /-- Request ids the client has cancelled. Written by the reader, read by the worker, so it
  is a mutex and not a ref. -/
  cancelled : Std.Mutex (Std.HashSet RequestID)
  /-- The request being served right now, with the cancellation token its operation observes (§9).

  A cancellation for a *queued* request is answered out of `cancelled` when the worker reaches
  it. A cancellation for the request already running is delivered directly: the reader cancels this
  token and, while a document frontend is active, also cancels its snapshot tree. -/
  inFlight : Std.Mutex (Option (RequestID × Std.CancellationToken))
  /-- The document analyzer currently serving that request, installed only around its
  frontend call. The reader uses it to propagate `$/cancelRequest` directly into Lean's snapshot
  tree. -/
  activeAnalyzer : Std.Mutex (Option IncrementalAnalyzer)
  /-- The findings last computed for a document, with the version they describe. An entry is
  only ever read for the version it names, and a `didChange` supersedes it. It exists because an
  editor asks for code actions on cursor movement, and the alternative is one exact frontend run
  per cursor movement over bytes that did not change. -/
  analyses : IO.Ref (Std.HashMap String (Int × Array Finding))
  /-- The richest envelope computed for each current document version. One validated
  canonical envelope also answers non-rendering source/syntax checks, preventing identical editor
  requests from building chains of fully reused snapshots or retaining duplicate semantic
  results. -/
  envelopes : IO.Ref (Std.HashMap String DocumentEnvelope)
  /-- Ask for a debounced analysis of one document version. A handler sees a function, not
  the queue, so no handler can reorder the queue. -/
  schedule : String → Int → IO Unit
  initialized : IO.Ref Bool
  shuttingDown : IO.Ref Bool

/-- Whether the client cancelled this request while it waited. -/
def Session.cancelled? (session : Session) (id : RequestID) : IO Bool :=
  session.cancelled.atomically do
    return (← get).contains id

def Session.recordCancellation (session : Session) (id : RequestID) : IO Unit :=
  session.cancelled.atomically do
    modify (·.insert id)

def Session.forgetCancellation (session : Session) (id : RequestID) : IO Unit :=
  session.cancelled.atomically do
    modify (·.erase id)

/-- Cancel the in-flight request if it is this one. Called by the reader, so it must not
block on anything the worker holds. Reading the in-flight slot and cancelling a token are both
wait-free. -/
def Session.cancelInFlight (session : Session) (id : RequestID) : IO Unit := do
  if let some (running, token)←
      session.inFlight.atomically do
        get then
    if running == id then
      token.cancel
      if let some analyzer←
          session.activeAnalyzer.atomically do
            get then
        analyzer.cancel

/-- Serve one request under a fresh cancellation token, and answer `RequestCancelled` if it is used.

Install-then-check is the order that closes the race with the reader. The reader records
the id in `cancelled` and *then* reads the in-flight slot; this installs the slot and *then* reads
`cancelled`. Whichever runs first, the other sees its write, so a cancellation arriving in the
window between the worker's admission check and the operation starting is never lost.

The body raises `Application.cancellationMessage` when the token stops either execution path. That
is a cancelled request rather than a failed one and gets the code the specification assigns it.
Every other error is the caller's to answer. -/
def Session.serveCancellable (session : Session) (id : RequestID)
    (body : Std.CancellationToken → IO Unit) : IO Unit := do
  let token ← Std.CancellationToken.new
  session.inFlight.atomically do
      set (some (id, token) : Option (RequestID × Std.CancellationToken))
  if ← session.cancelled? id then
    token.cancel
  try
    body token
  catch error =>
    if Application.cancelled? error then
      session.sink.fail id .requestCancelled "the request was cancelled"
    else
      throw error
  finally
    session.inFlight.atomically do
        set (none : Option (RequestID × Std.CancellationToken))
    session.forgetCancellation id

/-! ## Admission

Identity, not content, decides whether a buffer can be served at all. -/

/-- Resolve a document URI to a servable identity, or say why not.

The order is the frozen one, and each clause names the URI the client sent:

1. not a `file:` URI. An `untitled:` buffer has no location, so no closest configuration, so no
   answer this server could give that would agree with the answer the same bytes get on disk;
2. every gate `Project.unsavedTarget` applies — inside the root, `.lean`, and the `.lake` floor;
3. `force-exclude`, which `unsavedTarget` does not evaluate and `Project.load` does for explicitly
   named paths (`Project.lean:221-226`). An editor opening whatever the user clicked is not the
   deliberate act of typing a path: if `lean-fmt format` reports nothing for a vendored file, the
   editor must report nothing for the same bytes, or configuration answers differently in the
   editor than on the command line. -/
def admit (session : Session) (uri : String) : IO (Except Rejection (FilePath × String)) := do
  let some path :=
    System.Uri.fileUriToPath?
      uri | return .error s!"document has no file location, so it has no project configuration: {uri}"
  let discovery ← session.discovery.get
  let target ←
    try
      -- The empty source is deliberate: this asks only the identity question, and
      -- `unsavedTarget` reads no file for content.
      Except.ok <$>
          Project.unsavedTarget session.project.workspace discovery session.root path.toString ""
            (spelling? := some uri)
    catch error =>
      pure (.error s!"{error}")
  match target with
  | .error message =>
    return .error message
  | .ok target =>
    if
        target.config.forceExclude &&
          discovery.explain target.relativePath != Discovery.Gate.selected then
      return .error
          s!"document is excluded by this project's configuration \
        ({(discovery.explain target.relativePath).describe}): {uri}"
    return .ok (target.path, target.relativePath)

/-- The target a request runs against: the open document's bytes at its own identity.

Built per request rather than stored, so there is one copy of the buffer in the process. -/
def Session.targetOf (session : Session) (document : Document) : IO Project.SourceTarget := do
  Project.unsavedTarget session.project.workspace (← session.discovery.get) session.root
      document.path.toString document.source

/-! ## Text synchronization

Incremental; `applyChange` is all of it. -/

/-- Apply one content change to a normalized document.

Both endpoints are clamped before conversion (§4) and the result is re-ordered, so an inverted
or out-of-range range from a client deletes a well-defined region of the buffer instead of an
arbitrary one. Inserted text is normalized on the way in for the same reason the document is: one
coordinate system, the compiler's. -/
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

Ours, because the toolchain has none for formatting: `Lean.Lsp.ServerCapabilities` has no
formatting provider, and no formatting method is implemented anywhere in `Lean/Server/`
(`evidence/01-lsp-baseline.md` §3-§4). So there is nothing to contend with. -/

def serverCapabilities : Json :=
  Json.mkObj
    [("textDocumentSync",
        Json.mkObj
          [("openClose", true),
            -- 2 is incremental. Sync payload is per keystroke where analysis is per debounced
            -- request, so full sync would retransmit the buffer on every character (`notes` §6).
            ("change", (2 : Nat))]),
      ("documentFormattingProvider", true), ("documentRangeFormattingProvider", true),
      ("codeActionProvider",
        Json.mkObj
          [("codeActionKinds", Json.arr #["quickfix", "source.fixAll", "source.organizeImports"])])]

def serverInfo : Json :=
  Json.mkObj [("name", "lean-fmt"), ("version", LeanFmt.version)]

/-! ## Handlers -/

private def documentOf? (session : Session) (uri : String) : IO (Option Document) :=
  return (← session.documents.get).get? uri

/-- Answer a request that names a document the server cannot serve.

A refused document and an unopened one are different errors, and the message says which. -/
private def failForDocument (session : Session) (id : RequestID) (uri : String) : IO Unit := do
  match (← session.refusals.get).get? uri with
  | some reason =>
    session.sink.fail id .invalidParams reason
  | none =>
    session.sink.fail id .invalidParams s!"document is not open: {uri}"

private def publishEmpty (session : Session) (uri : String) : IO Unit :=
  session.sink.notify "textDocument/publishDiagnostics"
    (Json.mkObj [("uri", uri), ("diagnostics", Json.arr #[])])

/-- `initialize`. The workspace root is resolved here and never again: a `lakefile` change
invalidates the exact setup, and the answer to that is a restart, not a different workspace. -/
private def handleInitialize (session : Session) (id : RequestID) (params : Json) : IO Unit := do
  if ← session.initialized.get then
    session.sink.fail id .invalidRequest "initialize was already answered"
    return
  -- One root is served. A client offering several gets the one it asked for first and is
  -- told which ones it is not getting (`notes` §10).
  let folders := (params.getObjValAs? (Array Json) "workspaceFolders").toOption.getD #[]
  if folders.size > 1 then
    let names := folders.filterMap fun folder => (folder.getObjValAs? String "uri").toOption
    session.sink.show 2
        s!"lean-fmt serves one workspace root ({session.root}); \
      not serving: {String.intercalate ", " (names.toList.drop 1)}"
  -- `initializationOptions` (§10). Absent keys keep the command line's value, so a client
  -- that sends `{}` is configured as the process was started.
  if let .ok initialization := params.getObjVal? "initializationOptions" then
    let str? (key : String) := (initialization.getObjValAs? String key).toOption
    let strings (key : String) (fallback : Array String) :=
      (initialization.getObjValAs? (Array String) key).toOption.getD fallback
    let bool (key : String) (fallback : Bool) :=
      (initialization.getObjValAs? Bool key).toOption.getD fallback
    let nat (key : String) (fallback : Nat) :=
      (initialization.getObjValAs? Nat key).toOption.getD fallback
    let current ← session.settings.get
    -- Named, not silently dropped: a client that asks to move the root is asking for a different
    -- session.
    if (str? "root").isSome then
      session.sink.show 3 "lean-fmt fixes rootUri at startup; restart the server to change it"
    session.settings.set
        { current with
          configPath? := (str? "configPath").map FilePath.mk |>.orElse fun _ => current.configPath?
          select := strings "select" current.select
          ignore := strings "ignore" current.ignore
          preview := bool "preview" current.preview
          unsafeFixes := bool "unsafeFixes" current.unsafeFixes
          debounceMs := nat "debounceMs" current.debounceMs }
    -- A `configPath` from the client names a different configuration than the one discovery
    -- already walked, so discovery is re-run rather than left describing the old one.
    if (str? "configPath").isSome then
      let settings ← session.settings.get
      let configPath? :=
        settings.configPath?.map fun path => if path.isAbsolute then path else session.root / path
      session.discovery.set (← Discovery.run session.root configPath?)
  session.initialized.set true
  session.sink.respond id
      (Json.mkObj [("capabilities", serverCapabilities), ("serverInfo", serverInfo)])

private def handleDidOpen (session : Session) (params : Json) : IO Unit := do
  let .ok document := params.getObjVal? "textDocument" | return
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
    if let some previous := (← session.documents.get).get? uri then
      previous.analyzer.close
    let analyzer ← IncrementalAnalyzer.open
    session.refusals.modify (·.erase uri)
    session.documents.modify
        (·.insert uri
          {
            uri,
            path,
            relativePath,
            lineEndings,
            version,
            analyzer
            text := FileMap.ofString normalized })
    session.analyses.modify (·.erase uri)
    session.envelopes.modify (·.erase uri)
    session.schedule uri version

private def handleDidChange (session : Session) (params : Json) : IO Unit := do
  let .ok identifier := params.getObjVal? "textDocument" | return
  let .ok uri := identifier.getObjValAs? String "uri" | return
  let some document ← documentOf? session uri |
    return
  let version := (identifier.getObjValAs? Int "version").toOption.getD document.version
  -- Strictly increasing. An equal or older version is a client bug; applying it would move
  -- the buffer under a request in flight.
  if version <= document.version then
    session.sink.log 2
        s!"ignoring a document change at version {version}, not newer than {document.version}: {uri}"
    return
  let .ok changes :=
    params.getObjValAs? (Array Lsp.TextDocumentContentChangeEvent) "contentChanges" |
    session.sink.log 1 s!"unparseable contentChanges for {uri}"
    return
  let text := applyChanges document.text changes
  if text.source.utf8ByteSize > maxDocumentBytes then
    -- The document is closed rather than left at a stale version: continuing to answer from
    -- bytes the client has since edited past is the stale publication the freeze forbids.
    session.documents.modify (·.erase uri)
    document.analyzer.close
    session.analyses.modify (·.erase uri)
    session.envelopes.modify (·.erase uri)
    let reason := s!"document grew past {maxDocumentBytes} bytes and is no longer served: {uri}"
    session.refusals.modify (·.insert uri reason)
    publishEmpty session uri
    session.sink.show 2 reason
    return
  session.documents.modify
      (·.insert uri
        { document with
          text, version })
  session.analyses.modify (·.erase uri)
  session.envelopes.modify (·.erase uri)
  session.schedule uri version

private def handleDidClose (session : Session) (params : Json) : IO Unit := do
  let .ok identifier := params.getObjVal? "textDocument" | return
  let .ok uri := identifier.getObjValAs? String "uri" | return
  if let some document := (← session.documents.get).get? uri then
    document.analyzer.close
  session.documents.modify (·.erase uri)
  session.analyses.modify (·.erase uri)
  session.envelopes.modify (·.erase uri)
  session.refusals.modify (·.erase uri)
  -- A client keeps the last published set until told otherwise, so without this a closed
  -- document keeps showing diagnostics for bytes nobody holds.
  publishEmpty session uri

/-- `workspace/didChangeConfiguration`. Re-runs discovery and re-admits every open document.

Discovery is replaced wholesale rather than patched, so there is no state in which half the
documents are resolved against the old configuration. A document that the new configuration
excludes is closed and its diagnostics cleared; one that a previous configuration excluded is not
reopened, because the server does not hold the bytes of a document it refused — the client resends
them on the next open. -/
private def handleDidChangeConfiguration (session : Session) : IO Unit := do
  let configPath? :=
    (← session.settings.get).configPath?.map fun path =>
      if path.isAbsolute then path else session.root / path
  let discovery ← Discovery.run session.root configPath?
  session.discovery.set discovery
  for notice in discovery.fallback.notices do
    session.sink.log 3 s!"lean-fmt: {notice}"
  let documents ← session.documents.get
  -- Every memoized analysis was computed against the old configuration and is now describing
  -- rules, selections, or a margin that no longer apply. Dropped wholesale rather than compared:
  -- a memo whose key does not mention the configuration cannot be checked against a new one.
  session.analyses.set { }
  session.envelopes.set { }
  for (uri, document) in documents.toList do
    match ← admit session uri with
    | .ok _ =>
      -- Re-analyzed, not merely re-admitted. The roadmap requires a `line-width` change to
      -- re-format affected open documents rather than serve output rendered at the old margin. The
      -- margin is `FormatConfig.lineWidth`, resolved per document from discovery.
      session.schedule uri document.version
    | .error reason =>
      session.documents.modify (·.erase uri)
      document.analyzer.close
      session.refusals.modify (·.insert uri reason)
      publishEmpty session uri
      session.sink.show 2 s!"lean-fmt: {reason}"
  session.sink.log 3 "lean-fmt: configuration reloaded"

/-- `$/lean-fmt/health`. The same question `serve`'s `health` answers, plus how much the session is
holding. -/
private def handleHealth (session : Session) (id : RequestID) : IO Unit := do
  let documents ← session.documents.get
  let bytes :=
    documents.fold (init := (0 : Nat)) fun total _ document => total + document.source.utf8ByteSize
  session.sink.respond id
      (Json.mkObj
        [("ready", true), ("root", session.root.toString),
          ("toolchain",
            s!"Lean {Lean.versionString} \
      ({session.project.workspace.lakeEnv.lean.githash})"),
          ("openDocuments", documents.size), ("openDocumentBytes", bytes),
          ("refusedDocuments", (← session.refusals.get).size)])

/-! ## Analysis

Every answer below consumes the current whole-buffer frontend
envelope. Successive versions reuse the document's last-good snapshot; projection and rendering
remain the same `ExactRun.streamEnvelope` path used outside the editor. -/

/-- The document's identity and the rule plan that identity resolves.

Both come from the *buffer's location*, never its content, which is why a document with no
location cannot be served at all (§5). The plan is per document rather than per session because
two files in one project can legitimately disagree about `line-width` or `[lint]`. -/
private def resolve (session : Session) (document : Document) :
    IO (Except String (Project.SourceTarget × RulePlan)) := do
  try
    let target ← session.targetOf document
    match target.config.rulePlan (← session.settings.get).selection with
    | .ok plan =>
      return .ok (target, plan)
    | .error message =>
      return .error message
  catch error =>
    return .error s!"{error}"

private def withAnalyzerCancellation (session : Session) (analyzer : IncrementalAnalyzer)
    (cancel? : Option Std.CancellationToken) (action : IO α) : IO α := do
  let some cancel := cancel? | action
  session.activeAnalyzer.atomically do
      set (some analyzer)
  try
    if ← cancel.isCancelled then
      throw <| IO.userError Application.cancellationMessage
    action
  finally
    session.activeAnalyzer.atomically do
        set (none : Option IncrementalAnalyzer)

private def replaceAnalyzer (session : Session) (document : Document) : IO IncrementalAnalyzer := do
  document.analyzer.close
  let analyzer ← IncrementalAnalyzer.open
  session.documents.modify fun documents =>
      match documents.get? document.uri with
      | some current =>
        if current.version == document.version then
          documents.insert document.uri { current with analyzer }
        else documents
      | none => documents
  return analyzer

/- Run the one document-owned frontend, recreating its empty session once after an
infrastructure failure. Recovery starts from these in-memory bytes and exact setup; it never
consults disk evidence or the persistent result cache. A cancellation is propagated and never
treated as a crash. -/
private def incrementalEnvelope (session : Session) (document : Document)
    (target : Project.SourceTarget) (plan : RulePlan) (mode : RunMode)
    (cancel? : Option Std.CancellationToken := none) : IO AnalysisEnvelope := do
  let setup ← session.run.setupSnapshot target
  let semantic := plan.requiredTier == .semantic
  let occurrences := (plan.demandedCaps (mode == .fix)).occurrences
  let format? := if mode.rendersCanonical then some target.config.format else none
  if let some cached := (← session.envelopes.get).get? document.uri then
    if cached.meets document.version semantic occurrences format? then
      return cached.envelope
  let run (analyzer : IncrementalAnalyzer) :=
    withAnalyzerCancellation session analyzer cancel? do
      let result ←
        if mode.rendersCanonical then
          analyzer.format setup document.source document.path target.config.format
              (captureSemantic := semantic) (captureOccurrences := occurrences)
        else
          analyzer.analyze setup document.source document.path (captureSemantic := semantic)
              (captureOccurrences := occurrences)
      if result.cancelled then
        throw <| IO.userError Application.cancellationMessage
      return result.envelope
  let envelope ←
    try
      run document.analyzer
    catch error =>
      if Application.cancelled? error then
        throw error
      let analyzer ← replaceAnalyzer session document
      run analyzer
  if let some current := (← session.documents.get).get? document.uri then
    if current.version == document.version then
      session.envelopes.modify
          (·.insert document.uri
            { version := document.version, semantic, occurrences, format?, envelope })
  return envelope

private def incrementalReport (session : Session) (document : Document)
    (target : Project.SourceTarget) (plan : RulePlan) (mode : RunMode)
    (range? : Option SourceRange := none) (unsafeFixes : Bool := false)
    (cancel? : Option Std.CancellationToken := none) : IO StreamReport := do
  let envelope ← incrementalEnvelope session document target plan mode cancel?
  session.run.streamEnvelope target plan mode envelope range? unsafeFixes

/-- Byte range in the normalized document → LSP range. Both ends convert through the same
`FileMap` the client's own positions convert through, so a round trip is the identity on positions
that name a character boundary. -/
private def lspRangeOf (text : FileMap) (range : SourceRange) : Lsp.Range :=
  { start := positionOf text range.start, «end» := positionOf text range.stop }

private def sourceRangeOf (text : FileMap) (range : Lsp.Range) : SourceRange :=
  let start := offsetOf text range.start
  { start, stop := max start (offsetOf text range.end) }

private def severityJson : Severity → Nat
  -- Warning. A formatter finding is not an error: the file compiles, and a client that
  -- treated these as errors would gate the user's workflow on layout (§7).
  | _ => 2

/-- One finding as a published diagnostic. `source` names the tool. LSP scopes published
sets per server per URI, so this never contends with the Lean server's own. -/
private def diagnosticJson (text : FileMap) (finding : Finding) : Json :=
  Json.mkObj
    [("range", Lean.toJson (lspRangeOf text finding.range)),
      ("severity", severityJson finding.severity), ("code", finding.code),
      ("codeDescription",
        Json.mkObj
          [("href",
              s!"https://github.com/jcreinhold/lean-fmt/blob/main/docs/rules/{finding.code}.md")]),
      ("source", "lean-fmt"), ("message", finding.message)]

private def publishFindings (session : Session) (document : Document) (findings : Array Finding) :
    IO Unit :=
  session.sink.notify "textDocument/publishDiagnostics"
    (Json.mkObj
      [("uri", document.uri), ("version", Lean.toJson document.version),
        ("diagnostics", Json.arr (findings.map (diagnosticJson document.text)))])

/-- Run one analysis, or reuse the one already computed for exactly this version.

The memo is keyed on the version the client stated. A changed document has a new version by
protocol, and a new version never matches a stored one. -/
private def findingsFor (session : Session) (document : Document)
    (cancel? : Option Std.CancellationToken := none) : IO (Except String (Array Finding)) := do
  if let some (version, findings) := (← session.analyses.get).get? document.uri then
    if version == document.version then
      return .ok findings
  match ← resolve session document with
  | .error message =>
    return .error message
  | .ok (target, plan) =>
    try
      let report ← incrementalReport session document target plan .check (cancel? := cancel?)
      -- A buffer that did not analyze reports its diagnostics as a log line, not as
      -- findings: it is mid-keystroke, and reporting that as a finding is wrong (§7). It is also
      -- not memoized, because the next request should try again.
      if report.status == "broken" then
        return .error (String.intercalate "; " report.diagnostics.toList)
      session.analyses.modify (·.insert document.uri (document.version, report.findings))
      return .ok report.findings
    catch error =>
      -- A cancelled analysis is not a broken buffer. Reporting it as one would log a failure
      -- the client asked for; whoever answers the request answers this.
      if Application.cancelled? error then
        throw error
      return .error s!"{error}"

/-- Analyze and publish, or say why not and publish nothing.

An analysis failure is a `window/logMessage`, not a diagnostic and not an empty publish: an
empty set reads as "clean", and a broken buffer mid-keystroke is the normal state of editing. -/
private def analyzeAndPublish (session : Session) (uri : String) (version : Int) : IO Unit := do
  let some document ← documentOf? session uri |
    return
  -- Superseded: a newer version arrived while this analysis waited its turn. Publishing now
  -- would describe bytes the client has already edited past, which is the stale publication §6
  -- forbids.
  unless document.version == version do
    return
  match ← findingsFor session document with
  | .error message =>
    session.sink.log 3 s!"lean-fmt could not analyze {uri}: {message}"
  | .ok findings =>
    publishFindings session document findings

/-! ## Formatting -/

/-- A whole-document replacement, in the document's own line endings.

`Lsp.TextEdit`'s range is in client coordinates, so the replaced span is the whole buffer as
the *client* measures it — `wholeDocument`, not a byte count. -/
private def wholeEdit (document : Document) (output : String) : Json :=
  Lean.toJson ({ range := wholeDocument document.text, newText := output } : Lsp.TextEdit)

/-- `textDocument/formatting` and `textDocument/rangeFormatting`.

One operation, because they are one operation below: `streamEnvelope .format` with or
without a range. A range answer replaces the **actual** range — the hull of the layout units the
selection expands to — not the range the client asked for, because reflow can rebreak the enclosing
unit past the selection (§8). Clients that re-format are expected to send back the range
the unit now occupies; repeated range formatting is a fixed point only in output coordinates. -/
private def handleFormatting (session : Session) (id : RequestID) (params : Json) (ranged : Bool)
    (cancel : Std.CancellationToken) : IO Unit := do
  let .ok identifier := params.getObjVal? "textDocument" |
    session.sink.fail id .invalidParams "formatting request has no textDocument"
    return
  let .ok uri := identifier.getObjValAs? String "uri" |
    session.sink.fail id .invalidParams "formatting request has no document uri"
    return
  let some document ← documentOf? session uri |
    failForDocument session id uri
    return
  let range? ←
    if ranged then
      match params.getObjValAs? Lsp.Range "range" with
      | .ok range =>
        pure (some (sourceRangeOf document.text range))
      | .error _ =>
        session.sink.fail id .invalidParams s!"range formatting request has no range: {uri}"
        return
    else
      pure none
  match ← resolve session document with
  | .error message =>
    session.sink.fail id .invalidParams message
  | .ok (target, plan) =>
    let report ←
      try
        incrementalReport session document target plan .format (range? := range?) (cancel? :=
            some cancel)
      catch error =>
        -- A cancellation is not a formatting failure, and saying so here would report the
        -- client's own `$/cancelRequest` back to it as an internal error. `serveCancellable`
        -- answers it.
        if Application.cancelled? error then
          throw error
        session.sink.fail id .internalError s!"lean-fmt could not format {uri}: {error}"
        return
    match report.output with
    | none =>
      -- The buffer did not analyze. Answering "no edits" would claim it is already
      -- canonical.
      session.sink.fail id .internalError
          s!"lean-fmt could not format {uri}: {String.intercalate "; " report.diagnostics.toList}"
    | some output =>
      unless report.changed do
        session.sink.respond id (Json.arr #[])
        return
      match report.actual?, report.sourceMap[0]?, report.sourceMap.back? with
      | some actual, some first, some last =>
        -- `stream`'s ranged output is the whole document with the selected units reformatted
        -- in place, because a shell redirect must write a complete file. An editor wants the
        -- narrowest edit that does the same thing, so its undo stack and cursor survive. The
        -- source map makes that conversion a lookup rather than a second range computation:
        -- `sliceRange` re-bases each mark onto the spliced text, so the marks' hull is the body
        -- that replaced `actual` (`Application.lean`, `sliceRange`).
        let (spliced, _) := LosslessSource.normalize output
        let body := String.Pos.Raw.extract spliced ⟨first.output.start⟩ ⟨last.output.stop⟩
        session.sink.respond id
            (Json.arr
              #[Lean.toJson
                  ({
                      range := lspRangeOf document.text actual
                      newText := LosslessSource.denormalize body document.lineEndings } :
                    Lsp.TextEdit)])
      | _, _, _ =>
        session.sink.respond id (Json.arr #[wholeEdit document output])

/-! ## Code actions

Every action carries its own `WorkspaceEdit` against a stated version; no
`executeCommandProvider` is advertised, because nothing here needs a round trip through the client. -/

/-- A `WorkspaceEdit` in `documentChanges` form, so it names the version it was computed against.

The version is the protocol's staleness check, so this server needs no separate one: if the
buffer moved between the action being offered and applied, the client rejects the edit. -/
private def workspaceEdit (document : Document) (edits : Array Json) : Json :=
  Json.mkObj
    [("documentChanges",
        Json.arr
          #[Json.mkObj
              [("textDocument",
                  Json.mkObj [("uri", document.uri), ("version", Lean.toJson document.version)]),
                ("edits", Json.arr edits)]])]

private def codeAction (title kind : String) (edit : Json) (diagnostics : Array Json := #[]) :
    Json :=
  Json.mkObj <|
    [("title", Json.str title), ("kind", Json.str kind), ("edit", edit)] ++
      (if diagnostics.isEmpty then [] else [("diagnostics", Json.arr diagnostics)])

/-- `textDocument/codeAction`. One quickfix per admitted fix overlapping the cursor, one `source.fixAll`,
one `source.organizeImports`.

A withheld fix produces no action. `Application.admittedFix?` is the one admission rule,
shared with the patch a write would publish, so an editor never offers a quickfix `lean-fmt fix`
would refuse.

`fixAll` and `organizeImports` each cost one exact run, and are computed only when the client's
requested kinds ask for them: an editor that asks for quickfixes on every cursor movement must not
pay for two whole-document rewrites each time. -/
private def handleCodeAction (session : Session) (id : RequestID) (params : Json)
    (cancel : Std.CancellationToken) : IO Unit := do
  let .ok identifier := params.getObjVal? "textDocument" |
    session.sink.fail id .invalidParams "code action request has no textDocument"
    return
  let .ok uri := identifier.getObjValAs? String "uri" |
    session.sink.fail id .invalidParams "code action request has no document uri"
    return
  let some document ← documentOf? session uri |
    failForDocument session id uri
    return
  let selected :=
    match params.getObjValAs? Lsp.Range "range" with
    | .ok range => sourceRangeOf document.text range
    | .error _ => { start := 0, stop := document.source.utf8ByteSize }
  -- An absent `only` means "everything you have", which is what a client asking on a
  -- keystroke sends.
  let only? :=
    ((params.getObjVal? "context").toOption.bind fun context =>
      (context.getObjValAs? (Array String) "only").toOption)
  let wants (kind : String) : Bool :=
    match only? with
    | none => true
    | some kinds => kinds.any fun asked => kind == asked || kind.startsWith (asked ++ ".")
  match ← resolve session document with
  | .error message =>
    session.sink.fail id .invalidParams message
    return
  | .ok (target, plan) =>
    let unsafeFixes := (← session.settings.get).unsafeFixes
    let mut actions : Array Json := #[]
    if wants "quickfix" then
      match ← findingsFor session document (cancel? := some cancel) with
      | .error message =>
        session.sink.log 3 s!"lean-fmt could not analyze {uri}: {message}"
      | .ok findings =>
        for finding in findings do
          -- Overlap, not containment: a client sends the cursor as an empty range, and an
          -- empty range is contained in nothing.
          if
              finding.range.start < selected.stop && selected.start < finding.range.stop ||
                finding.range.start == selected.start then
            if let some fix := Application.admittedFix? plan unsafeFixes finding then
              let edits :=
                fix.edits.map fun edit =>
                  Lean.toJson
                    ({ range := lspRangeOf document.text edit.range, newText := edit.replacement } :
                      Lsp.TextEdit)
              actions :=
                actions.push
                  (codeAction s!"{finding.code}: {finding.message}" "quickfix"
                    (workspaceEdit document edits) #[diagnosticJson document.text finding])
    if wants "source.fixAll" then
      let fixed? ←
        try
          let report ←
            incrementalReport session document target plan .fix (unsafeFixes := unsafeFixes)
                (cancel? := some cancel)
          pure (some report)
        catch error =>
          if Application.cancelled? error then
            throw error
          session.sink.log 3 s!"lean-fmt could not compute fix-all for {uri}: {error}"
          pure none
      if let some report := fixed? then
        if report.changed then
          if let some output := report.output then
            actions :=
              actions.push
                (codeAction "lean-fmt: fix all" "source.fixAll"
                  (workspaceEdit document #[wholeEdit document output]))
    if wants "source.organizeImports" then
      match
        ←
          (try
              session.run.organizeSnapshot target (cancel? := some cancel)
            catch error =>
              if Application.cancelled? error then
                throw error
              pure (.error s!"{error}")) with
      | .error message =>
        session.sink.log 3 s!"lean-fmt: {message}"
      | .ok none =>
        pure ()
      | .ok (some output) =>
        actions :=
          actions.push
            (codeAction "lean-fmt: organize imports" "source.organizeImports"
              (workspaceEdit document #[wholeEdit document output]))
    session.sink.respond id (Json.arr actions)

/-! ## Dispatch -/

/-- Answer one message. Returns `true` when the session should stop reading.

Requests carry an id and must be answered exactly once, including when the answer is an
error; notifications carry none and are answered never. An unknown *notification* is ignored — the
specification requires it, since clients send `$/`-prefixed notifications servers need not know. -/
def dispatch (session : Session) (json : Json) : IO Bool := do
  let method? := (json.getObjValAs? String "method").toOption
  let id? :=
    (json.getObjVal? "id").toOption.map fun value =>
      match value with
      | .str s => RequestID.str s
      | .num n => RequestID.num n
      | _ => RequestID.null
  let params := (json.getObjVal? "params").toOption.getD (Json.mkObj [])
  match method?, id? with
  | none, some id =>
    -- A response to something we never asked. Not our message; not an error we can
    -- answer.
    session.sink.log 4 s!"ignoring a client response with id {id}"
    return false
  | none, none =>
    session.sink.log 2 "ignoring a message with no method"
    return false
  | some method, none =>
    -- Notifications.
    if !(← session.initialized.get) && method != "exit" then
      return false
    match method with
    | "initialized" =>
      return false
    | "exit" =>
      return true
    | "textDocument/didOpen" =>
      handleDidOpen session params;
      return false
    | "textDocument/didChange" =>
      handleDidChange session params;
      return false
    | "textDocument/didClose" =>
      handleDidClose session params;
      return false
    | "workspace/didChangeConfiguration" =>
      handleDidChangeConfiguration session;
      return false
    | _ =>
      return false
  | some method, some id =>
    -- Requests.
    if method == "initialize" then
      handleInitialize session id params
      return false
    unless ← session.initialized.get do
      session.sink.fail id .serverNotInitialized s!"lean-fmt received {method} before initialize"
      return false
    if ← session.shuttingDown.get then
      session.sink.fail id .invalidRequest s!"lean-fmt is shutting down and cannot answer {method}"
      return false
    -- Cancellation is checked at the moment of service, which is the only moment at which
    -- the answer is still worth not computing. A cancelled request is answered, not dropped: the
    -- specification requires every request to get exactly one response.
    if ← session.cancelled? id then
      session.forgetCancellation id
      session.sink.fail id .requestCancelled s!"{method} was cancelled"
      return false
    match method with
    | "shutdown" =>
      session.shuttingDown.set true
      session.sink.respond id Json.null
      return false
    | "$/lean-fmt/health" =>
      handleHealth session id;
      return false
    | "textDocument/formatting" =>
      session.serveCancellable id (handleFormatting session id params (ranged := false))
      return false
    | "textDocument/rangeFormatting" =>
      session.serveCancellable id (handleFormatting session id params (ranged := true))
      return false
    | "textDocument/codeAction" =>
      session.serveCancellable id (handleCodeAction session id params)
      return false
    | _ =>
      session.sink.fail id .methodNotFound s!"lean-fmt does not implement {method}"
      return false

/-! ## The loop

A reader task and a worker, joined by a bounded queue.

The split exists for one reason: `$/cancelRequest` arrives *while* a request is being
served, and a single-threaded server cannot read it until it has finished the very thing being
cancelled. So the reader owns the stream, applies cancellation immediately, and hands everything
else to the worker. -/

private inductive Work where
  | message (json : Json)
  | malformed (detail : String)
  /-- A debounced analysis, scheduled by `didOpen`/`didChange` and dropped by the worker if
  the document has moved past `version` in the meantime (§9). It goes on the same queue as
  everything else, so analysis and message handling share the single FIFO the freeze specifies and
  nothing touches a document concurrently. -/
  | analyze (uri : String) (version : Int)
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
  | .closed =>
    discard queue.close.toBaseIO
  | .malformed detail =>
    unless ← queue.trySend (Work.malformed detail) do
      session.sink.fail .null .internalError "lean-fmt request queue is full"
    readLoop session input queue
  | .message json =>
    let method? := (json.getObjValAs? String "method").toOption
    if method? == some "$/cancelRequest" then
      -- Applied here, not queued: a cancellation queued behind the request it cancels
      -- arrives too late.
      if let some id := ((json.getObjVal? "params").toOption.bind idOf?) then
        session.recordCancellation id
        -- If it is the request already running, cancel its token. Recording first makes
        -- the pair race-free: `serveCancellable` installs the token and then re-reads this set.
        session.cancelInFlight id
      readLoop session input queue
    else if method? == some "exit" then
      discard <| queue.trySend (Work.message json)
      discard queue.close.toBaseIO
    else
      unless ← queue.trySend (Work.message json) do
        -- A full queue refuses; it does not grow and it does not drop silently. A request
        -- gets an error it can retry, a notification gets a log line, because a notification has
        -- no id to answer.
        match idOf? json with
        | some id =>
          session.sink.fail id .internalError
              s!"lean-fmt is behind: more than {maxQueuedMessages} messages are queued"
        | none =>
          session.sink.log 2
              s!"lean-fmt dropped a notification: more than {maxQueuedMessages} messages are queued"
      readLoop session input queue

private partial def workLoop (session : Session) (queue : Std.CloseableChannel.Sync Work) :
    IO UInt32 := do
  match ← queue.recv with
  | none =>
    return 0
  | some (Work.malformed detail) =>
    -- Recovery, not termination: the frame was consumed, the session continues, and the
    -- client is told. There is no id to answer, because there was no parseable message.
    session.sink.fail .null .parseError s!"lean-fmt could not read a message: {detail}"
    workLoop session queue
  | some (Work.analyze uri version) =>
    try
      analyzeAndPublish session uri version
    catch error =>
      session.sink.log 1 s!"lean-fmt: {error}"
    workLoop session queue
  | some (Work.message json) =>
    let stop ←
      try
        dispatch session json
      catch error =>
        match idOf? json with
        | some id =>
          session.sink.fail id .internalError s!"{error}";
          pure false
        | none =>
          session.sink.log 1 s!"lean-fmt: {error}";
          pure false
    if stop then
      -- `exit` before `shutdown` is a protocol violation and exits non-zero, per the
      -- specification.
      return if ← session.shuttingDown.get then 0 else 1
    workLoop session queue

/-- Start one Language Server Protocol session on stdin/stdout.

Holds one Lake workspace and one discovery for its lifetime; writes no file and opens no result
cache. `Project.loadWorkspaceOnly` rather than `Project.load` because the client, not a selection
walk, says which documents exist — and a document may be a file that has never been saved. -/
def serveLanguageServer (options : ServerOptions) : IO UInt32 := do
  let root ← IO.FS.realPath options.root
  let configPath? :=
    options.configPath?.map fun path => if path.isAbsolute then path else root / path
  let discovery ← Discovery.run root configPath?
  let project ← Project.loadWorkspaceOnly root
  let sink ← Sink.of (← IO.getStdout)
  for notice in discovery.fallback.notices do
    sink.log 3 s!"lean-fmt: {notice}"
  -- The exact capability brackets the whole session, so its temporary storage is created
  -- and removed once rather than per request.
  Application.withExactRun project (action := fun run => do
      let queue : Std.CloseableChannel.Sync Work ←
        Std.CloseableChannel.Sync.new (capacity := some maxQueuedMessages)
      let settings ← IO.mkRef options
      let session : Session :=
        {
          options,
          settings,
          root,
          project,
          run,
          sink
          discovery := ← IO.mkRef discovery
          documents := ← IO.mkRef { }
          refusals := ← IO.mkRef { }
          cancelled := ← Std.Mutex.new { }
          inFlight := ← Std.Mutex.new none
          activeAnalyzer := ← Std.Mutex.new none
          analyses := ← IO.mkRef { }
          envelopes := ← IO.mkRef { }
          -- The quiet interval is a wait, not a poll: one task per scheduled version, which
          -- enqueues either way. The worker drops a superseded analysis, because only the worker's
          -- ordering says which version is current.
          schedule := fun uri version =>
            discard <|
              IO.asTask do
                IO.sleep (← settings.get).debounceMs.toUInt32
                discard <| queue.trySend (Work.analyze uri version)
          initialized := ← IO.mkRef false
          shuttingDown := ← IO.mkRef false }
      let input ← IO.getStdin
      let reader ← IO.asTask (prio := .dedicated) (readLoop session input queue)
      let code ← workLoop session queue
      -- The reader has finished whenever the queue closed; waiting makes that certain, and
      -- stops a half-read frame from outliving the session.
      discard <| IO.wait reader
      for (_, document) in (← session.documents.get).toList do
        document.analyzer.close
      return code)

end LeanFmt.Internal.LanguageServer
