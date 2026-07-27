/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.ArtifactStore
import all LeanFmt.Comments
import all LeanFmt.Formatter
import all LeanFmt.Formatter.Command
import all LeanFmt.Formatter.NativeLayout
import all LeanFmt.Formatter.Trivia
import all LeanFmt.Profile
import all LeanFmt.Rules
import all LeanFmt.Suppression
import all LeanFmt.Validator

import Lean.Elab.Frontend
import Lean.Linter.Deprecated
import Lean.Server.InfoUtils
import Std.Sync.Mutex

namespace LeanFmt.Internal

open LeanFmt.Internal.Profile (recordCount)

/- The process response is deliberately semantic. It contains neither setup paths nor
execution strategy, so the parent cannot accidentally key reporting on how it obtained the
analysis. -/
structure AnalysisEnvelope where
  artifact? : Option ModuleArtifact
  commentSummary? : Option CommentSummary := none
  formatDraft? : Option FormatDraft := none
  formatFailure? : Option FormatterFailure := none
  canonical? : Option CanonicalLayout := none
  validationFailure? : Option ValidationFailure := none
  diagnostics : Array String := #[]
  deriving Lean.ToJson, Lean.FromJson

structure CandidateValidationEnvelope where
  canonical? : Option CanonicalLayout := none
  failure? : Option ValidationFailure := none
  deriving Lean.ToJson, Lean.FromJson

private def candidateFailure (gate : ValidationGate) (detail : String) :
    CandidateValidationEnvelope :=
  { failure? := some { gate, detail } }

/- Silent messages are carriers, not diagnostics. The compiler plugin writes command
records into the persistent lint log as a silent `.information` message, so an integrated project's
own frontend run sees it in the log alongside real errors. Reporting it would print the whole
serialized projection as a broken-source diagnostic. Found by `tests/downstream/run.sh`: it needs a
plugin-enabled project *and* a file that elaborates far enough for a command linter to run, which
is why no in-repo broken fixture caught it — `MalformedHeader` and `UnresolvedImport` both fail
before the linter fires. -/
private def messageStrings (messages : Lean.MessageLog) : IO (Array String) :=
  messages.toArray.filter (!·.isSilent) |>.mapM (·.toString true)

private def broken (messages : Lean.MessageLog) : IO AnalysisEnvelope := do
  return { artifact? := none, diagnostics := ← messageStrings messages }

/-- Everything the parser reads from the frontend state before a command: the four fields Lean
itself puts in a `ParserModuleContext` (`Lean/Language/Lean.lean`'s command loop), taken from the
same place — the head scope of the state left by the command before.

The namespace and the open declarations are here because `resolveParserNameCore` takes them
explicitly: inside a `namespace`/`open` region they decide which syntax a name refers to, so a
context missing them parses a different language from the one Lean parsed. -/
private structure ParseContext where
  env : Lean.Environment
  options : Lean.Options
  currNamespace : Lean.Name
  openDecls : List Lean.OpenDecl

private def ParseContext.ofState (state : Lean.Elab.Command.State) : ParseContext :=
  let scope := state.scopes.head!
  { env := state.env, options := scope.opts, currNamespace := scope.currNamespace,
    openDecls := scope.openDecls }

private def ParseContext.toModuleContext (context : ParseContext) :
    Lean.Parser.ParserModuleContext :=
  { env := context.env, options := context.options, currNamespace := context.currNamespace,
    openDecls := context.openDecls }

/-- An actual parsed command paired with the frontend state immediately before
elaborating it. The pre-state supplies precisely the options and formatter registrations under
which the parser accepted that command; persistent environments share their unchanged structure
across these short-lived rows. -/
private structure LiveCommand where
  stx : Lean.Syntax
  parse : ParseContext

private def LiveCommand.env (command : LiveCommand) : Lean.Environment := command.parse.env

private def LiveCommand.options (command : LiveCommand) : Lean.Options := command.parse.options

private partial def collectLiveCommands (snapshot : Lean.Language.Lean.CommandParsedSnapshot)
    (state : Lean.Elab.Command.State) (commands : Array LiveCommand := #[])
    (terminal? : Option LiveCommand := none) (checkCancelled : IO Unit := pure ()) :
    IO (Array LiveCommand × Option LiveCommand) := do
  checkCancelled
  let isTerminal := Lean.Parser.isTerminalCommand snapshot.stx
  -- The terminal carries its pre-state for the same reason every other command does: a reparse
  -- has to parse it under the context Lean parsed it under, and it is the last thing parsed.
  let live : LiveCommand := { stx := snapshot.stx, parse := ParseContext.ofState state }
  let commands := if isTerminal then commands else commands.push live
  let terminal? := if isTerminal then terminal? <|> some live else terminal?
  let nextState := snapshot.elabSnap.resultSnap.get.cmdState
  match snapshot.nextCmdSnap? with
  | some next => collectLiveCommands next.get nextState commands terminal? checkCancelled
  | none => return (commands, terminal?)

/-- A frontend run that has finished, in the shape every projection below reads.

Two operations produce one. `Lean.Language.Lean.process` parses the header and imports for itself, so
its tree already holds the header's diagnostics and `headerMessages` stays empty.
`Lean.Language.Lean.processCommands` is handed a parsed header and an imported state and starts at
the first command, so whoever parsed that header passes its diagnostics here. Nothing downstream can
tell which one ran. -/
private structure ProcessedModule where
  headerStx : Lean.Syntax
  /-- Diagnostics the tree does not carry, which for a run that skipped header handling means the
  header's own parse messages. -/
  headerMessages : Lean.MessageLog
  tree : Lean.Language.SnapshotTree
  /-- The first command and the state the header left behind, or `none` when parsing or importing
  failed and there is no elaboration to project. -/
  start? : Option (Lean.Language.Lean.CommandParsedSnapshot × Lean.Elab.Command.State)

private def ProcessedModule.messages (module : ProcessedModule) : Lean.MessageLog :=
  module.tree.getAll.map (·.diagnostics.msgLog) |>.foldl (· ++ ·) module.headerMessages

private partial def finalCmdState (snapshot : Lean.Language.Lean.CommandParsedSnapshot) :
    Lean.Elab.Command.State :=
  match snapshot.nextCmdSnap? with
  | some next => finalCmdState next.get
  | none => snapshot.elabSnap.resultSnap.get.cmdState

/-- The state after the last command, or `none` if the run never reached one. `none` is how a caller
learns the run failed before elaboration; the diagnostics say why. -/
private def ProcessedModule.finalCmdState? (module : ProcessedModule) :
    Option Lean.Elab.Command.State :=
  module.start?.map fun (first, _) => finalCmdState first

private def ProcessedModule.liveCommands (module : ProcessedModule)
    (checkCancelled : IO Unit := pure ()) : IO (Array LiveCommand × Option LiveCommand) :=
  match module.start? with
  | none => pure (#[], none)
  | some (first, headerState) =>
    collectLiveCommands first headerState (checkCancelled := checkCancelled)

private def ProcessedModule.ofInitial (snapshot : Lean.Language.Lean.InitialSnapshot) :
    ProcessedModule where
  headerStx := snapshot.stx
  headerMessages := {}
  tree := Lean.Language.toSnapshotTree snapshot
  start? := do
    let parsed ← snapshot.result?
    let processed ← parsed.processedSnap.get.result?
    return (processed.firstCmdSnap.get, processed.cmdState)

private def normalizedSlice (bytes : ByteArray) (range : SourceRange) : String :=
  String.fromUTF8! <| bytes.extract range.start range.stop

private def appendDocument (document? : Option Doc) (next : Doc) : Option Doc :=
  some <| match document? with
  | some document => document ++ next
  | none => next

private def buildFormatDraft (normalized : String) (source : LosslessSource)
    (sourcePath : System.FilePath) (fileMap : Lean.FileMap) (ownership : CommentOwnership)
    (header : Lean.Syntax) (headerEnv : Lean.Environment) (headerOptions : Lean.Options)
    (commands : Array LiveCommand) (width : Nat)
    (checkCancelled : IO Unit := pure ()) : IO (Except FormatterFailure FormatDraft) := do
  let bytes := normalized.toUTF8
  let headerRange : SourceRange := ⟨0, source.headerStop⟩
  let mut document? : Option Doc := none
  let mut registryNodes := 0
  let mut nativeDocuments := 0
  let mut alignedTokens := 0
  let mut nativeCommentLeaves := 0
  let mut normalizedTokens := 0
  let mut exactIslands := 0
  let mut exactIslandBytes := 0
  let mut offsideConstraints := 0
  let mut commentConstraints := 0
  let mut explicitDocuments := 0
  let mut descriptorDocuments := 0
  let fileDangling := Formatter.Trivia.fileDangling ownership
  checkCancelled
  if headerRange.start < headerRange.stop then
    let result ← Lean.Core.CoreM.toIO' (Formatter.Command.header ownership header)
      { fileName := sourcePath.toString, fileMap, options := headerOptions }
      { env := headerEnv }
    let formatted ← match result with
      | .ok formatted => pure formatted
      | .error failure => return .error failure
    registryNodes := registryNodes + formatted.document.size
    match formatted.trace.resolution with
    | .explicit _ => explicitDocuments := explicitDocuments + 1
    | .descriptor => descriptorDocuments := descriptorDocuments + 1
    let headerSeparator :=
      if commands.isEmpty && source.terminalStop == source.normalizedBytes then Doc.hard
      else Doc.hard ++ Doc.hard
    document? := appendDocument document? <|
      Doc.mark headerRange (formatted.document ++ headerSeparator)
  let mut sequence := Formatter.Command.sequence
  for h : index in [0:commands.size] do
    checkCancelled
    let command := commands[index]
    let (nextSequence, placement) := Formatter.Command.place sequence command.stx
    sequence := nextSequence
    let start := (LosslessSource.leadingStart? command.stx).getD source.headerStop
    let stop := match commands[index + 1]? with
      | some next => (LosslessSource.leadingStart? next.stx).getD source.terminalStop
      | none => source.terminalStop
    let hasTail := source.terminalStop < source.normalizedBytes
    let preserveFinalNewline := index + 1 == commands.size && !hasTail && normalized.endsWith "\n"
    let leading := if placement.blankBefore then Doc.hard else Doc.empty
    let separator := if index + 1 < commands.size || hasTail || preserveFinalNewline then
        Doc.hard
      else Doc.empty
    let boundaryTail := if index + 1 == commands.size then
        match fileDangling with
        | some comments => Doc.hard ++ comments
        | none => Doc.empty
      else Doc.empty
    if let some suppressed := Formatter.Trivia.formatIgnoreNext? ownership command.stx then
      document? := appendDocument document? <|
        Doc.mark ⟨start, stop⟩
          (leading ++ Doc.verbatim (normalizedSlice bytes suppressed) ++ boundaryTail ++ separator)
      continue
    let result ← Lean.Core.CoreM.toIO'
      (Formatter.NativeLayout.command normalized ownership command.stx placement.indent)
      { fileName := sourcePath.toString, fileMap, options := command.options }
      { env := command.env }
    let formatted ← match result with
      | .ok formatted => pure formatted
      | .error failure => return .error failure
    nativeDocuments := nativeDocuments + 1
    alignedTokens := alignedTokens + formatted.metrics.tokenLeaves
    nativeCommentLeaves := nativeCommentLeaves + formatted.metrics.commentLeaves
    normalizedTokens := normalizedTokens + formatted.metrics.normalizedTokens
    exactIslands := exactIslands + formatted.metrics.exactIslands
    exactIslandBytes := exactIslandBytes + formatted.metrics.exactIslandBytes
    offsideConstraints := offsideConstraints + formatted.metrics.offsideConstraints
    commentConstraints := commentConstraints + formatted.metrics.commentConstraints
    registryNodes := registryNodes + formatted.metrics.nativeNodes
    match formatted.trace.resolution with
    | .explicit _ => explicitDocuments := explicitDocuments + 1
    | .descriptor => descriptorDocuments := descriptorDocuments + 1
    let indentation := Doc.text ("".pushn ' ' placement.indent)
    -- Command-boundary trivia belongs to whole-module composition. Registered command
    -- syntax is boundary-stripped before delegation, so the ownership layer remains its sole
    -- outer emitter.
    --
    -- A docstring is command syntax even though Lean stores its opening token in the following
    -- token's `SourceInfo`, so its structural document is that opening's sole emitter. This used
    -- to be enforced here, by dropping the command's *entire* leading trivia whenever it contained
    -- doc syntax — which also dropped an ordinary line comment written above the docstring,
    -- silently. The exclusion is by comment kind now, and it lives
    -- in `Trivia.commandLeading` where the comments are selected.
    let leadingTrivia :=
      match Formatter.Trivia.leading ownership command.stx with
      | some comments =>
        -- The source's own blank line between a leading comment and its command.
        -- `Command.place` owns the boundary between commands, and this gap is inside one
        -- command's unit, so nothing else supplies it — which is why every file's copyright block
        -- ended flush against `module`.
        comments ++ Formatter.Trivia.leadingBoundary ownership command.stx
      | none => Doc.empty
    let trailingTrivia := match Formatter.Trivia.trailing ownership command.stx stop with
      | some comments => comments
      | none => Doc.empty
    let commandDocument := Doc.nest placement.indent
      (indentation ++ leadingTrivia ++ formatted.document ++ trailingTrivia)
    document? := appendDocument document? <|
      Doc.mark ⟨start, stop⟩ (leading ++ commandDocument ++ boundaryTail ++ separator)
  let tailRange : SourceRange := ⟨source.terminalStop, source.normalizedBytes⟩
  if tailRange.start < tailRange.stop then
    document? := appendDocument document? <|
      Doc.mark tailRange (Doc.verbatim (normalizedSlice bytes tailRange))
  let document := document?.getD Doc.empty
  checkCancelled
  let rendered := renderDetailed width document
  return .ok {
    text := rendered.text
    sourceMap := rendered.sourceMap
    headerContract := Formatter.Command.headerContract header
    commentContract := Comments.contract normalized ownership
    metrics := {
      frontendRuns := 1
      commands := commands.size
      nativeDocuments
      alignedTokens
      nativeCommentLeaves
      normalizedTokens
      exactIslands
      exactIslandBytes
      offsideConstraints
      commentConstraints
      registryNodes
      explicitDocuments
      descriptorDocuments
      commentOwners := Comments.all ownership |>.size
      documentNodes := rendered.metrics.documentNodes
      renderSteps := rendered.metrics.workSteps
      nativeEvents := rendered.metrics.nativeEvents }
    sourceDigest := source.normalizedDigest.hex
    sourceBytes := source.normalizedBytes
    headerStop := source.headerStop
    terminalStop := source.terminalStop }

private def isApplicationRuntimePlugin (plugin : Lean.Plugin) : Bool :=
  plugin.path.fileName.any fun name =>
    name.startsWith "libLake" || name.contains "LeanFmtCompilerPlugin"

private def ofMessageSeverity : Lean.MessageSeverity → Severity
  | .information => .information
  | .warning => .warning
  | .error => .error

/- Normalize the compiler diagnostics the exact frontend emitted into immutable rule facts.
Only the `kind`s the semantic rules surface (`surfacedDiagnosticKinds`) are kept — one source of
truth shared with the rules — so the artifact never carries a diagnostic no rule reads. `msg.kind`
is the pure top-level tag; only matching messages are serialized (`msg.serialize`, which renders
`data` and needs `BaseIO`). Each message's `Position` is converted to a normalized-source byte
offset through the frontend's `FileMap` — `mkInputContext` built it on `crlfToLf`-normalized
source, so it shares the projection's coordinate system — and the range is clamped to
`[0, sourceBytes]`, dropping any position that a macro reattribution placed outside this module's
own bytes. No `Environment`, `Position`, or `FileMap`
crosses into a rule; only this data. -/
private def captureDiagnostics (fileMap : Lean.FileMap) (sourceBytes : Nat)
    (messages : Lean.MessageLog) : IO (Array Diagnostic) := do
  let mut diagnostics := #[]
  for msg in messages.toArray do
    if surfacedDiagnosticKinds.contains msg.kind.toString then
      let start := (fileMap.ofPosition msg.pos).byteIdx
      let stop := match msg.endPos with
        | some endPos => (fileMap.ofPosition endPos).byteIdx
        | none => start
      if start ≤ sourceBytes then
        let range : SourceRange := { start := min start sourceBytes, stop := min (max start stop) sourceBytes }
        let serial ← msg.serialize
        diagnostics := diagnostics.push {
          kind := msg.kind.toString
          range
          severity := ofMessageSeverity msg.severity
          message := serial.data
        }
  return diagnostics

/- The user-facing display of a resolved constant: the module-private mangling
(`_private.M.0.foo`) stripped to what the source writes (`foo`, or a qualified `Foo.bar`). Pure on
`Name` — no `Environment` — so it is a fact the rule reads as a plain string, never a `Name`. -/
private def occurrenceDisplay (n : Lean.Name) : String := (Lean.privateToUserName n).toString

/- Re-derive the owned deprecation-occurrence facts from the whole-file info trees. This
is the fold
proved reachable through the same snapshot tree `analyzeExact`
already walks for the message log: every
command's info tree lives on its `Snapshot.infoTree?`, so `tree.getAll.filterMap (·.infoTree?)` —
a *consumer-side* fold, not a producer change — surfaces the whole file, avoiding the per-command
info reset that would limit `waitForFinalCmdState?` to the last command.

For each `TermInfo` whose elaborated `expr` *is* a constant (`.constName?` is `some` — which
already excludes an applied receiver, whose term is an `.app`, and dot-notation, whose term is the
application) that carries `@[deprecated]`, and which is a use rather than the declaration binder
(`isBinder`), one occurrence is recorded. Ranges come straight from `Info.range?` — already
normalized-source byte offsets (the parser positions index the string `mkInputContext` normalized),
so unlike a diagnostic's `Position` they need no `FileMap` round-trip — clamped to the module's
byte span. Each use-site emits its `TermInfo` more than once, so this deduplicates by range.
`fixable` is decided here: a `newName?` must exist and the occurrence must
spell a single bare identifier token, the conservative predicate a textual rename preserves;
everything else is report-only and the output re-elaboration validator backstops the rest. -/
private def occurrenceOfInfo (ci : Lean.Elab.ContextInfo) (info : Lean.Elab.Info)
    (normalized : String) (sourceBytes : Nat) : Option DeprecatedOccurrence := do
  let .ofTermInfo ti := info | none
  if ti.isBinder then none else
  let declName ← ti.expr.constName?
  let entry ← Lean.Linter.deprecatedAttr.getParam? ci.env declName
  let r ← info.range?
  let start := min r.start.byteIdx sourceBytes
  let stop := min (max r.start.byteIdx r.stop.byteIdx) sourceBytes
  let spelled := String.fromUTF8! (normalized.toUTF8.extract start stop)
  let displayName := occurrenceDisplay declName
  let newName? := entry.newName?.map occurrenceDisplay
  -- The occurrence is fixable only when its source spelling is *exactly* the resolved
  -- constant's own full display name: then replacing that whole
  -- span with the replacement's full display re-resolves unambiguously to the new constant,
  -- independent of `open`/dot context. A spelling that differs from the full name — an
  -- `open`-shadowed short name (`oldNs` resolving to `N.oldNs`), a dot-notation projection head
  -- (`x.foo` resolving to `T.foo`), an applied receiver with the constant implicit — is *not* a
  -- rename we can prove, so it stays report-only and the compiler's own FMT012 diagnostic still
  -- reports it. Backstopped by the re-elaboration validator: even an accepted spelling that
  -- fails to resolve is caught before publish, never on disk.
  let fixable := newName?.isSome && spelled == displayName
  return {
    range := { start, stop }
    declName := displayName
    newName?
    since? := entry.since?
    text? := entry.text?
    fixable
  }

private def captureDeprecatedOccurrences (tree : Lean.Language.SnapshotTree)
    (normalized : String) (sourceBytes : Nat) : Array DeprecatedOccurrence :=
  let trees := tree.getAll.filterMap (·.infoTree?)
  let raw : Array DeprecatedOccurrence := trees.foldl (init := #[]) fun acc t =>
    t.foldInfo (init := acc) fun ci info acc =>
      match occurrenceOfInfo ci info normalized sourceBytes with
      | some occ => acc.push occ
      | none => acc
  raw.foldl (init := #[]) fun acc occ =>
    if acc.any (·.range == occ.range) then acc else acc.push occ

private structure FrontendRun where
  input : Lean.Parser.InputContext
  snapshot : Lean.Language.Lean.InitialSnapshot

private unsafe def processSource (setup : Lean.ModuleSetup) (source : String)
    (sourcePath : System.FilePath) (old? : Option Lean.Language.Lean.InitialSnapshot := none)
    (loadDynlibs : Bool := true) : IO FrontendRun := do
  Lean.initSearchPath (← Lean.findSysroot)
  Lean.enableInitializersExecution
  let input := Lean.Parser.mkInputContext source sourcePath.toString
  let options := Lean.Elab.async.setIfNotSet setup.options.toOptions true
  let setupImports (header : Lean.Elab.HeaderSyntax) := do
    if loadDynlibs then
      liftM <| setup.dynlibs.forM Lean.loadDynlib
    return .ok {
      mainModuleName := setup.name
      package? := setup.package?
      isModule := setup.isModule || header.isModule
      imports := setup.imports?.getD header.imports
      opts := options
      trustLevel := 0
      importArts := setup.importArts
      -- This executable already imports and links Lake, and the formatter's own compiler
      -- plugin only records artifacts during builds. Reinitializing either in a persistent
      -- analyzer duplicates runtime state (and the compiler plugin is not loadable from a direct
      -- editor launch on macOS). Other target plugins remain: they may own syntax or elaborators
      -- the document needs.
      plugins := setup.plugins.filter (!isApplicationRuntimePlugin ·)
    }
  let context : Lean.Language.ProcessingContext := { input with }
  let snapshot ← Lean.Language.Lean.process setupImports old? context
  return { input, snapshot }

/- The comment ownership a set of commands implies over its own source. Both the original module and
a reparsed candidate derive it the same way, from their own projection, so a difference between the
two drafts' comment contracts is a difference in the commands and not in how they were read. -/
private def commentOwnership (normalized : String) (projection : LosslessSource)
    (headerStx : Lean.Syntax) (commands : Array Lean.Syntax) (terminal? : Option Lean.Syntax) :
    CommentOwnership :=
  let suppressed := (Suppression.collect projection normalized).directives.map (·.scopeRange)
  Comments.build normalized headerStx commands terminal? suppressed

/- Project a set of parsed commands over their source and lay them out: the two things, and the only
two things, a candidate is admitted on. The candidate path calls this instead of running a second
frontend and reading the same two facts back out of its envelope. -/
private def projectAndRender (mainModule : String) (normalized : String)
    (sourcePath : System.FilePath) (fileMap : Lean.FileMap) (headerStx : Lean.Syntax)
    (headerEnv : Lean.Environment) (headerOptions : Lean.Options)
    (commands : Array LiveCommand) (terminal : LiveCommand) (width : Nat)
    (checkCancelled : IO Unit := pure ()) :
    IO (LosslessSource × Except FormatterFailure FormatDraft) := do
  let stxs := commands.map (·.stx)
  let projection := LosslessSource.ofSource mainModule normalized stxs (some terminal.stx)
  let ownership := commentOwnership normalized projection headerStx stxs (some terminal.stx)
  let draft ← buildFormatDraft normalized projection sourcePath fileMap ownership headerStx
    headerEnv headerOptions commands width checkCancelled
  return (projection, draft)

/-- Parse the candidate command by command under the contexts Lean used for the original, and accept
only if every command comes back structurally identical.

This is the induction that replaces the candidate's elaboration. Command `i` is parsed under the
`ParserModuleContext` the original run parsed *its* command `i` under. If the result is `structEq` to
the original's — equal modulo source info, and so equal in everything the elaborator reads except
positions — then elaborating it leaves the state the original's elaboration left, and the recorded
context for `i + 1` is the right one. Every step checks the hypothesis the next step stands on.

`structEq`, not `Validator.compare`: `LosslessSource.collect` walks only `args[0]` of a `choice`
node, so the lossless comparison cannot tell a three-alternative `choice` from a two-alternative
one, and `choice` nodes appear in ordinary files (1 of 5 sampled mathlib modules). `structEq`
compares every child. `Validator.compare` still runs afterwards, for the gate and the detail it
reports; after this it is implied.

**What this stops catching, stated plainly.** The candidate's `.diagnostics` gate had two halves. A
parse error or a failed import is caught here, earlier and exactly. An *elaboration* error in a
candidate whose syntax is `structEq`-identical to the original's is not — that needs an elaborator
that reads source positions, such as a project's own position-reading command elaborator, or
`warningAsError` with a line-length linter. Lean's own incremental engine refuses this assumption,
reusing an elaboration only under `eqWithInfo`, positions included; what is reused here is a parser
context, not an elaboration result, which is why the weaker equality is the right one.

Every deviation is an `.error` carrying a counter tag, never a verdict. The caller then runs the real
candidate frontend, so a candidate this refuses is judged exactly as it was before.

The candidate's *own* header syntax comes back with the commands, not the original's. `structEq`
ignores source info, which is the point here and a trap next door: the original's header carries
positions into the original bytes, and comment ownership and the header render both read positions.
Handing them the original's header over the candidate's text puts two coordinate systems in one
draft. -/
private def reparseCandidate (text : String) (sourcePath : System.FilePath)
    (headerStx : Lean.Syntax) (commands : Array LiveCommand) (terminal : LiveCommand)
    (checkCancelled : IO Unit := pure ()) :
    IO (Except String (Lean.Syntax × Array LiveCommand × LiveCommand)) := do
  let input := Lean.Parser.mkInputContext text sourcePath.toString
  let (header, parserState, headerMessages) ← Lean.Parser.parseHeader input
  if headerMessages.hasErrors then return .error "header_parse"
  unless header.raw.structEq headerStx do return .error "header"
  let mut state := parserState
  let mut reparsed := #[]
  for command in commands do
    checkCancelled
    let (stx, next, messages) :=
      Lean.Parser.parseCommand input command.parse.toModuleContext state .empty
    if messages.hasErrors || next.recovering then return .error "parse"
    unless stx.structEq command.stx do
      -- A terminal here means the candidate ran out of commands early, which is a different defect
      -- from a command that changed shape, and worth its own counter.
      return .error (if Lean.Parser.isTerminalCommand stx then "short" else "structure")
    reparsed := reparsed.push { command with stx }
    state := next
  checkCancelled
  let (stx, _, messages) :=
    Lean.Parser.parseCommand input terminal.parse.toModuleContext state .empty
  if messages.hasErrors then return .error "terminal_parse"
  -- Also how a candidate with *more* commands than the original is caught: an ordinary command
  -- parsed where the terminal belongs is not `structEq` to it.
  unless stx.structEq terminal.stx do return .error "terminal"
  return .ok (header.raw, reparsed, { terminal with stx })

/-- Elaborate the candidate draft, starting from this run's imports when the draft asks for the same
ones.

`processSource` would import the draft's modules from scratch, and on a module that imports mathlib
that import costs more than the rest of the analysis put together. This run already holds the state
the header left — the environment after importing, before any of the file's own commands — and that
is where elaborating the draft begins. Lean's incremental path reuses it the same way when an edit
leaves the header alone, but it decides by comparing header syntax including source positions, and a
formatted draft moves them: it may drop a blank line above the first import. So compare what the
header asks for instead of how it is written.

Falls back to a full run when the draft would import something else, when its header does not parse,
or when the caller must be able to reach the candidate's snapshot: `processCommands` keeps its
cancellation token to itself, so a snapshot it produced cannot be cancelled afterwards. -/
private unsafe def candidateFrontend (setup : Lean.ModuleSetup) (original : ProcessedModule)
    (text : String) (sourcePath : System.FilePath)
    (trackSnapshot? : Option (Lean.Language.Lean.InitialSnapshot → IO Unit)) :
    IO (Lean.Parser.InputContext × ProcessedModule) := do
  let full : IO (Lean.Parser.InputContext × ProcessedModule) := do
    recordCount "candidate_reimport" 1
    let run ← processSource setup text sourcePath (loadDynlibs := false)
    if let some track := trackSnapshot? then track run.snapshot
    return (run.input, ProcessedModule.ofInitial run.snapshot)
  if trackSnapshot?.isSome then return ← full
  let some (_, headerState) := original.start? | return ← full
  let input := Lean.Parser.mkInputContext text sourcePath.toString
  let (header, parserState, headerMessages) ← Lean.Parser.parseHeader input
  if headerMessages.hasErrors then return ← full
  -- `setupImports` reads `setup.imports?` first and only falls back to the header, so a setup that
  -- carries imports makes both runs load the same list whatever either header says.
  let originalHeader : Lean.Elab.HeaderSyntax := ⟨original.headerStx⟩
  let candidateHeader : Lean.Elab.HeaderSyntax := header
  unless setup.imports?.isSome
      || Lean.Elab.HeaderSyntax.imports candidateHeader
        == Lean.Elab.HeaderSyntax.imports originalHeader do
    return ← full
  unless Lean.Elab.HeaderSyntax.isModule candidateHeader
      == Lean.Elab.HeaderSyntax.isModule originalHeader do
    return ← full
  recordCount "candidate_import_reuse" 1
  let first := (← Lean.Language.Lean.processCommands input parserState headerState).get
  return (input, {
    headerStx := header.raw
    headerMessages
    tree := Lean.Language.toSnapshotTree first
    start? := some (first, headerState) })

/- Convert one completed frontend run into the product's semantic envelope.
Incremental processing changes only where the run came from, never how formatter facts are
derived. -/
private unsafe def analyzeSnapshot (setup : Lean.ModuleSetup) (source : String)
    (sourcePath : System.FilePath) (input : Lean.Parser.InputContext)
    (module : ProcessedModule) (captureSemantic : Bool := false)
    (captureOccurrences : Bool := false) (captureComments : Bool := false)
    (captureFormatDraft : Bool := false) (validateFormatDraft : Bool := false)
    (formatWidth : Nat := 100)
    (trackSnapshot? : Option (Lean.Language.Lean.InitialSnapshot → IO Unit) := none)
    (checkCancelled : IO Unit := pure ()) :
    IO AnalysisEnvelope := do
  checkCancelled
  let options := Lean.Elab.async.setIfNotSet setup.options.toOptions true
  let tree := module.tree
  let messages := module.messages
  let some commandState := module.finalCmdState?
    | return ← broken messages
  if messages.hasErrors then
    return ← broken messages
  let (liveCommands, terminal?) ← module.liveCommands checkCancelled
  checkCancelled
  let commands := liveCommands.map (·.stx)
  -- Semantic rule facts are captured only under rule demand. The whole-file occurrence
  -- fold remains separately gated, so report-only semantic checks do not pay for fix ownership.
  let normalizedSource := (LosslessSource.normalize source).1
  let semantic ← if captureSemantic then do
      let diagnostics ← captureDiagnostics input.fileMap normalizedSource.utf8ByteSize messages
      let occurrences? := if captureOccurrences then
          some (captureDeprecatedOccurrences tree normalizedSource normalizedSource.utf8ByteSize)
        else none
      pure (some { diagnostics, occurrences? })
    else pure none
  -- `mkInputContext` normalized `source` before parsing it, so every offset above indexes
  -- the normalized string. Measuring the artifact against `source` itself would mix two coordinate
  -- systems inside one artifact for any file that uses CRLF.
  let some terminal := terminal?
    | throw <| IO.userError "successful frontend produced no terminal command"
  let commandOptions := liveCommands.map fun command => (command.stx, command.options)
  let artifact ← match ModuleArtifact.ofParsedModule setup.name.toString normalizedSource
      commandOptions terminal.stx commandState.scopes.head!.opts semantic with
    | .ok artifact => pure artifact
    | .error error => throw <| IO.userError s!"could not encode syntax artifact: {error}"
  let projection :=
    LosslessSource.ofSource setup.name.toString normalizedSource commands (some terminal.stx)
  let needsDraft := captureFormatDraft || validateFormatDraft
  let ownership? := if captureComments || needsDraft then
      some <| commentOwnership normalizedSource projection module.headerStx commands
        (some terminal.stx)
    else none
  let commentSummary? := if captureComments then
      ownership?.map (Comments.summary normalizedSource)
    else none
  let (firstDraft?, formatFailure?) ← if needsDraft then do
      let some ownership := ownership?
        | throw <| IO.userError "format draft has no comment ownership"
      match ← buildFormatDraft normalizedSource projection sourcePath input.fileMap ownership
          module.headerStx commandState.env options liveCommands formatWidth checkCancelled with
      | .ok draft => pure (some draft, none)
      | .error failure => pure (none, some failure)
    else pure (none, none)
  let (canonical?, validationFailure?) ← if validateFormatDraft then do
      let some first := firstDraft?
        | match formatFailure? with
          | some failure => pure (none, some {
              gate := .formatter
              detail := failure.detail })
          | none => pure (none, some {
              gate := .formatter
              detail := "format draft was not produced" })
      let candidateText := (LosslessSource.normalize first.text).1
      let reparsed ←
        if (← IO.getEnv "LEAN_FMT_DISABLE_CANDIDATE_REPARSE") == some "1" then
          pure (.error "disabled")
        else
          reparseCandidate candidateText sourcePath module.headerStx liveCommands terminal
            checkCancelled
      checkCancelled
      match reparsed with
      | .ok (candidateHeader, candidateCommands, candidateTerminal) =>
        recordCount "candidate_reparse" 1
        -- The candidate's own text decides its coordinates, so its own header, commands, and file
        -- map are what lay it out. Its final environment is the original's: that is what the
        -- induction concluded.
        let candidateInput := Lean.Parser.mkInputContext candidateText sourcePath.toString
        let (candidateProjection, second?) ← projectAndRender setup.name.toString candidateText
          sourcePath candidateInput.fileMap candidateHeader commandState.env options
          candidateCommands candidateTerminal formatWidth checkCancelled
        match second? with
        | .error failure => pure (none, some { gate := .formatter, detail := failure.detail })
        | .ok second =>
          if !candidateProjection.validFor candidateText then
            pure (none, some {
              gate := .structure
              detail := "reparsed candidate did not project losslessly over its own bytes" })
          else
            match Validator.admit normalizedSource projection first candidateProjection second
                { frontendRuns := 1, reparsedCommands := candidateCommands.size } with
            | .ok layout => pure (some layout, none)
            | .error failure => pure (none, some failure)
      | .error tag =>
        recordCount s!"candidate_miss_{tag}" 1
        let (candidateInput, candidateModule) ←
          candidateFrontend setup module first.text sourcePath trackSnapshot?
        checkCancelled
        let candidate ← analyzeSnapshot setup first.text sourcePath candidateInput
          candidateModule (captureFormatDraft := true) (formatWidth := formatWidth)
          (trackSnapshot? := trackSnapshot?) (checkCancelled := checkCancelled)
        if !candidate.diagnostics.isEmpty then
          pure (none, some {
            gate := .diagnostics
            detail := String.intercalate "\n" candidate.diagnostics.toList })
        else match candidate.artifact?, candidate.formatDraft?, candidate.formatFailure? with
          | some candidateArtifact, some second, none =>
            match candidateArtifact.materialize first.text with
            | .error error => pure (none, some { gate := .structure, detail := error })
            | .ok candidateMaterialized =>
              match Validator.admit normalizedSource projection first candidateMaterialized.source
                  second { frontendRuns := 2 } with
              | .ok layout => pure (some layout, none)
              | .error failure => pure (none, some failure)
          | _, _, some failure => pure (none, some { gate := .formatter, detail := failure.detail })
          | _, _, _ => pure (none, some {
              gate := .structure
              detail := "candidate frontend returned no artifact or second draft" })
    else pure (none, none)
  let formatDraft? := if captureFormatDraft then firstDraft? else none
  return {
    artifact? := some artifact
    commentSummary? := commentSummary?
    formatDraft? := formatDraft?
    formatFailure? := formatFailure?
    canonical? := canonical?
    validationFailure? := validationFailure? }

/- Execute Lean's frontend under the exact target setup without retaining parser or
environment state. Batch exact analysis remains deliberately one-shot. -/
unsafe def analyzeExact (setup : Lean.ModuleSetup) (source : String)
    (sourcePath : System.FilePath) (captureSemantic : Bool := false)
    (captureOccurrences : Bool := false) (captureComments : Bool := false)
    (captureFormatDraft : Bool := false) (validateFormatDraft : Bool := false)
    (formatWidth : Nat := 100) (loadDynlibs : Bool := true) : IO AnalysisEnvelope := do
  let run ← processSource setup source sourcePath (loadDynlibs := loadDynlibs)
  analyzeSnapshot setup source sourcePath run.input (ProcessedModule.ofInitial run.snapshot)
    captureSemantic captureOccurrences captureComments captureFormatDraft validateFormatDraft
    formatWidth

structure IncrementalCounters where
  updates : Nat := 0
  successful : Nat := 0
  failed : Nat := 0
  cancelled : Nat := 0
  invalidated : Nat := 0
  reusedCommands : Nat := 0
  deriving Inhabited, Repr, Lean.ToJson, Lean.FromJson

structure IncrementalResult where
  envelope : AnalysisEnvelope
  reusedCommands : Nat
  invalidated : Bool
  cancelled : Bool := false
  retainedSnapshots : Nat
  counters : IncrementalCounters
  deriving Lean.ToJson, Lean.FromJson

private structure IncrementalGood where
  setupIdentity : String
  sourcePath : String
  headerIdentity : String
  snapshot : Lean.Language.Lean.InitialSnapshot

private structure IncrementalFlight where
  snapshot? : Option Lean.Language.Lean.InitialSnapshot := none
  cancelled : IO.Ref Bool

private structure IncrementalState where
  good? : Option IncrementalGood := none
  flight? : Option IncrementalFlight := none
  counters : IncrementalCounters := {}
  closed : Bool := false

/-- A single-document frontend session. Its constructor and state are private so callers
can only use the bounded lifecycle operations below; in particular, no caller can retain snapshot
history or invoke parse/elaboration stages out of order. -/
structure IncrementalAnalyzer where
  private mk ::
    private state : Std.Mutex IncrementalState

private def setupIdentity (setup : Lean.ModuleSetup) : String :=
  toString <| Digest.ofString (Lean.toJson setup).compress

private def headerIdentity (snapshot : Lean.Language.Lean.InitialSnapshot) : String :=
  snapshot.stx.unsetTrailing.reprint.getD ""

private unsafe def cancelSnapshot (snapshot : Lean.Language.Lean.InitialSnapshot) : IO Unit :=
  (Lean.Language.toSnapshotTree snapshot).children.forM (·.cancelRec)

private unsafe def sharedCommandPrefix (old new : Lean.Language.Lean.InitialSnapshot) : IO Nat := do
  let before := (← (ProcessedModule.ofInitial old).liveCommands).1
  let after := (← (ProcessedModule.ofInitial new).liveCommands).1
  let rec loop (i : Nat) : Nat :=
    match before[i]?, after[i]? with
    | some oldCommand, some newCommand =>
      if ptrEq oldCommand.stx newCommand.stx then loop (i + 1) else i
    | _, _ => i
  return loop 0

def IncrementalAnalyzer.open : IO IncrementalAnalyzer := do
  return .mk (← Std.Mutex.new {})

private def IncrementalAnalyzer.releaseFlight (analyzer : IncrementalAnalyzer) : IO Unit :=
  analyzer.state.atomically fun ref => do
    let state ← ref.get
    ref.set { state with flight? := none }

private unsafe def IncrementalAnalyzer.run (analyzer : IncrementalAnalyzer)
    (setup : Lean.ModuleSetup) (source : String) (sourcePath : System.FilePath)
    (captureSemantic : Bool) (captureOccurrences : Bool) (captureComments : Bool)
    (captureFormatDraft : Bool) (validateFormatDraft : Bool) (formatWidth : Nat) :
    IO IncrementalResult := do
  let cancelRef ← IO.mkRef false
  let state ← analyzer.state.atomically fun ref => do
    let state ← ref.get
    if state.closed then
      throw <| IO.userError "incremental analyzer is closed"
    if state.flight?.isSome then
      throw <| IO.userError "incremental analyzer already has an update in flight"
    ref.set { state with flight? := some { cancelled := cancelRef } }
    return state
  let identity := setupIdentity setup
  let path := sourcePath.toString
  let lineageMatches := state.good?.any fun good =>
    good.setupIdentity == identity && good.sourcePath == path
  unless lineageMatches do
    state.good?.forM fun good => cancelSnapshot good.snapshot
  let old? := if lineageMatches then state.good?.map (·.snapshot) else none
  let run ← try
      processSource setup source sourcePath old? (loadDynlibs := !lineageMatches)
    catch error =>
      analyzer.releaseFlight
      throw error
  let trackSnapshot (snapshot : Lean.Language.Lean.InitialSnapshot) := do
    analyzer.state.atomically fun ref => do
      let current ← ref.get
      ref.set { current with
        flight? := current.flight?.map ({ · with snapshot? := some snapshot }) }
    if ← cancelRef.get then cancelSnapshot snapshot
  let checkCancelled : IO Unit := do
    if ← cancelRef.get then
      throw <| IO.userError "incremental analysis cancelled"
  trackSnapshot run.snapshot
  let envelope ← try
      -- When the candidate does get elaborated — a reparse miss — `candidateFrontend` gives it a
      -- full `processSource` run rather than reusing this one's imports, because only a snapshot
      -- `processSource` produced can be cancelled and the analyzer must be able to drop a
      -- superseded analysis. The reparse itself has no snapshot to cancel and stops at
      -- `checkCancelled` between commands instead.
      analyzeSnapshot setup source sourcePath run.input (ProcessedModule.ofInitial run.snapshot)
        captureSemantic captureOccurrences captureComments captureFormatDraft validateFormatDraft
        formatWidth (some trackSnapshot) checkCancelled
    catch error =>
      if ← cancelRef.get then
        pure { artifact? := none, diagnostics := #["analysis cancelled"] }
      else
        analyzer.releaseFlight
        throw error
  let wasCancelled ← cancelRef.get
  let oldHeader? := if lineageMatches then state.good?.map (·.headerIdentity) else none
  let newHeader := headerIdentity run.snapshot
  let invalidated := !lineageMatches || oldHeader?.any (· != newHeader)
  let reused ← if invalidated then pure 0 else
    match old? with
    | some old => sharedCommandPrefix old run.snapshot
    | none => pure 0
  let (good?, counters) ← analyzer.state.atomically fun ref => do
    let current ← ref.get
    let succeeded := !current.closed && !wasCancelled && envelope.artifact?.isSome
    let counters := { current.counters with
      updates := current.counters.updates + 1
      successful := current.counters.successful + if succeeded then 1 else 0
      failed := current.counters.failed + if !succeeded && !wasCancelled then 1 else 0
      cancelled := current.counters.cancelled + if wasCancelled then 1 else 0
      invalidated := current.counters.invalidated + if invalidated then 1 else 0
      reusedCommands := current.counters.reusedCommands + reused }
    let good? := if current.closed then none
      else if succeeded then some {
          setupIdentity := identity, sourcePath := path, headerIdentity := newHeader
          snapshot := run.snapshot }
        else state.good?
    ref.set { current with good?, flight? := none, counters }
    return (good?, counters)
  return {
    envelope, reusedCommands := reused, invalidated, cancelled := wasCancelled
    retainedSnapshots := if good?.isSome then 1 else 0, counters }

/-- Analyze the current document version, retaining it only when the frontend succeeds. -/
private unsafe def IncrementalAnalyzer.analyzeUnsafe (analyzer : IncrementalAnalyzer)
    (setup : Lean.ModuleSetup) (source : String) (sourcePath : System.FilePath)
    (captureSemantic : Bool := false) (captureOccurrences : Bool := false)
    (captureComments : Bool := false) : IO IncrementalResult :=
  analyzer.run setup source sourcePath captureSemantic captureOccurrences captureComments
    false false 100

@[implemented_by IncrementalAnalyzer.analyzeUnsafe]
opaque IncrementalAnalyzer.analyze (analyzer : IncrementalAnalyzer)
    (setup : Lean.ModuleSetup) (source : String) (sourcePath : System.FilePath)
    (captureSemantic : Bool := false) (captureOccurrences : Bool := false)
    (captureComments : Bool := false) : IO IncrementalResult

/-- Format the current document version through the same two-pass admission path as one-shot
exact formatting. The validated canonical layout, if any, is in `result.envelope.canonical?`. -/
private unsafe def IncrementalAnalyzer.formatUnsafe (analyzer : IncrementalAnalyzer)
    (setup : Lean.ModuleSetup) (source : String) (sourcePath : System.FilePath)
    (width : Nat := 100) (captureSemantic : Bool := false)
    (captureOccurrences : Bool := false) : IO IncrementalResult :=
  analyzer.run setup source sourcePath captureSemantic captureOccurrences false false true width

@[implemented_by IncrementalAnalyzer.formatUnsafe]
opaque IncrementalAnalyzer.format (analyzer : IncrementalAnalyzer)
    (setup : Lean.ModuleSetup) (source : String) (sourcePath : System.FilePath)
    (width : Nat := 100) (captureSemantic : Bool := false)
    (captureOccurrences : Bool := false) : IO IncrementalResult

/-- Cancel the current update, if any. Lean recursively cancels only snapshot subtrees it
has ruled out for reuse; the session marks the generation so it can never become the last-good
snapshot. -/
private unsafe def IncrementalAnalyzer.cancelUnsafe (analyzer : IncrementalAnalyzer) : IO Unit := do
  if let some flight ← analyzer.state.atomically fun ref => return (← ref.get).flight? then
    flight.cancelled.set true
    flight.snapshot?.forM cancelSnapshot

@[implemented_by IncrementalAnalyzer.cancelUnsafe]
opaque IncrementalAnalyzer.cancel (analyzer : IncrementalAnalyzer) : IO Unit

def IncrementalAnalyzer.counters (analyzer : IncrementalAnalyzer) : IO IncrementalCounters :=
  analyzer.state.atomically fun ref => return (← ref.get).counters

private def IncrementalAnalyzer.isRunning (analyzer : IncrementalAnalyzer) : IO Bool :=
  analyzer.state.atomically fun ref => return (← ref.get).flight?.isSome

/-- Release the retained snapshot and reject all later operations. Closing twice is
harmless. -/
private unsafe def IncrementalAnalyzer.closeUnsafe (analyzer : IncrementalAnalyzer) : IO Unit := do
  let state ← analyzer.state.atomically fun ref => do
    let state ← ref.get
    ref.set { state with good? := none, flight? := none, closed := true }
    return state
  state.flight?.forM fun flight => do
    flight.cancelled.set true
    flight.snapshot?.forM cancelSnapshot
  state.good?.forM fun good => cancelSnapshot good.snapshot

@[implemented_by IncrementalAnalyzer.closeUnsafe]
opaque IncrementalAnalyzer.close (analyzer : IncrementalAnalyzer) : IO Unit

/-- Test-only admission of externally supplied candidate bytes through the same
production comparator and second formatting pass. Product formatting never accepts candidate bytes
from a caller; this operation exists so mutation fixtures can exercise the real gates. -/
unsafe def validateCandidateExact (setup : Lean.ModuleSetup) (source candidate : String)
    (sourcePath : System.FilePath) (width : Nat) : IO CandidateValidationEnvelope := do
  let original ← analyzeExact setup source sourcePath (captureFormatDraft := true)
    (formatWidth := width)
  if !original.diagnostics.isEmpty then
    return candidateFailure .diagnostics (String.intercalate "\n" original.diagnostics.toList)
  let reparsed ← analyzeExact setup candidate sourcePath (captureFormatDraft := true)
    (formatWidth := width) (loadDynlibs := false)
  if !reparsed.diagnostics.isEmpty then
    return candidateFailure .diagnostics (String.intercalate "\n" reparsed.diagnostics.toList)
  match original.artifact?, original.formatDraft?, reparsed.artifact?, reparsed.formatDraft?,
      reparsed.formatFailure? with
  | some beforeArtifact, some beforeDraft, some afterArtifact, some second, none =>
    let normalizedSource := (LosslessSource.normalize source).1
    let normalizedCandidate := (LosslessSource.normalize candidate).1
    let first : FormatDraft := {
      beforeDraft with
      text := normalizedCandidate
      sourceMap := #[{
        source := ⟨0, normalizedSource.utf8ByteSize⟩
        output := ⟨0, normalizedCandidate.utf8ByteSize⟩ }] }
    match beforeArtifact.materialize source, afterArtifact.materialize candidate with
    | .ok beforeMaterialized, .ok afterMaterialized =>
      match Validator.admit normalizedSource beforeMaterialized.source first
          afterMaterialized.source second { frontendRuns := 2 } with
      | .ok canonical => return { canonical? := some canonical }
      | .error failure => return { failure? := some failure }
    | .error error, _ | _, .error error => return candidateFailure .structure error
  | _, _, _, _, some failure =>
    return candidateFailure .formatter failure.detail
  | _, _, _, _, _ =>
    return candidateFailure .structure
      "candidate validation did not produce both frontend projections"

unsafe def compilerArtifact? (moduleName : Lean.Name)
    (moduleFile : System.FilePath) : IO (Option ModuleArtifact) := do
  Lean.initSearchPath (← Lean.findSysroot)
  let (moduleData, _region) ← Lean.readModuleData moduleFile
  let level := if moduleData.isModule then Lean.OLeanLevel.exported else .private
  let artifacts : Lean.NameMap Lean.ImportArtifacts :=
    ({} : Lean.NameMap Lean.ImportArtifacts).insert moduleName (.ofArrays #[#[moduleFile]])
  let environment ← Lean.importModules #[{ module := moduleName }] {}
    (trustLevel := 1024) (loadExts := false) (level := level) (arts := artifacts)
  return fromEnvironment? environment moduleName

end LeanFmt.Internal
