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
import all LeanFmt.Formatter.CoreSurface
import all LeanFmt.Formatter.Trivia
import all LeanFmt.Rules
import all LeanFmt.Suppression
import all LeanFmt.Validator

import Lean.Elab.Frontend
import Lean.Linter.Deprecated
import Lean.Server.InfoUtils

namespace LeanFmt.Internal

/- The process response is deliberately semantic. It contains neither setup paths nor execution
strategy, so the parent cannot accidentally key reporting on how it obtained the analysis. -/
structure AnalysisEnvelope where
  artifact? : Option ModuleArtifact
  surfaceSummary? : Option SurfaceSummary := none
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

/- Silent messages are carriers, not diagnostics. The compiler plugin writes command records into
the persistent lint log as a silent `.information` message, so an integrated project's own frontend run
sees it in the log alongside real errors. Reporting it would print the whole serialized projection as
a broken-source diagnostic. Found by `tests/downstream/run.sh`: it needs a plugin-enabled project *and*
a file that elaborates far enough for a command linter to run, which is why no in-repo broken fixture
caught it — `MalformedHeader` and `UnresolvedImport` both fail before the linter fires. -/
private def messageStrings (messages : Lean.MessageLog) : IO (Array String) :=
  messages.toArray.filter (!·.isSilent) |>.mapM (·.toString true)

private def broken (messages : Lean.MessageLog) : IO AnalysisEnvelope := do
  return { artifact? := none, diagnostics := ← messageStrings messages }

/-- An actual parsed command paired with the frontend state immediately before elaborating it. The
pre-state supplies precisely the options and formatter registrations under which the parser accepted
that command; persistent environments share their unchanged structure across these short-lived rows. -/
private structure LiveCommand where
  stx : Lean.Syntax
  env : Lean.Environment
  options : Lean.Options

private partial def collectLiveCommands (snapshot : Lean.Language.Lean.CommandParsedSnapshot)
    (state : Lean.Elab.Command.State) (commands : Array LiveCommand := #[])
    (terminal? : Option Lean.Syntax := none) : Array LiveCommand × Option Lean.Syntax :=
  let isTerminal := Lean.Parser.isTerminalCommand snapshot.stx
  let commands := if isTerminal then commands else commands.push {
    stx := snapshot.stx
    env := state.env
    options := state.scopes.head!.opts }
  let terminal? := if isTerminal then terminal? <|> some snapshot.stx else terminal?
  let nextState := snapshot.elabSnap.resultSnap.get.cmdState
  match snapshot.nextCmdSnap? with
  | some next => collectLiveCommands next.get nextState commands terminal?
  | none => (commands, terminal?)

private def processedLiveCommands (snapshot : Lean.Language.Lean.InitialSnapshot) :
    Array LiveCommand × Option Lean.Syntax :=
  match snapshot.result? with
  | none => (#[], none)
  | some parsed =>
    match parsed.processedSnap.get.result? with
    | none => (#[], none)
    | some processed =>
      collectLiveCommands processed.firstCmdSnap.get processed.cmdState

private def normalizedSlice (bytes : ByteArray) (range : SourceRange) : String :=
  String.fromUTF8! <| bytes.extract range.start range.stop

private def appendDocument (document? : Option Doc) (next : Doc) : Option Doc :=
  some <| match document? with
  | some document => document ++ next
  | none => next

private partial def containsKind (kind : Lean.Name) (stx : Lean.Syntax) : Bool :=
  if stx.getKind == kind then true
  else if stx.getKind == Lean.choiceKind then
    stx.getArgs[0]?.any (containsKind kind)
  else stx.getArgs.any (containsKind kind)

private def buildFormatDraft (normalized : String) (source : LosslessSource)
    (sourcePath : System.FilePath) (fileMap : Lean.FileMap) (ownership : CommentOwnership)
    (header : Lean.Syntax) (headerEnv : Lean.Environment) (headerOptions : Lean.Options)
    (commands : Array LiveCommand) (width : Nat) : IO (Except FormatterFailure FormatDraft) := do
  let bytes := normalized.toUTF8
  let headerRange : SourceRange := ⟨0, source.headerStop⟩
  let mut document? : Option Doc := none
  let mut coreDocuments := 0
  let mut registryDocuments := 0
  let mut structuralDocuments := 0
  let mut coreRegistryDocuments := 0
  let mut extensionRegistryDocuments := 0
  let mut registryNodes := 0
  let mut explicitDocuments := 0
  let mut descriptorDocuments := 0
  let fileDangling := Formatter.Trivia.fileDangling ownership
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
    coreDocuments := coreDocuments + 1
    match formatted.mechanism with
    | .structural => structuralDocuments := structuralDocuments + 1
    | .registry => coreRegistryDocuments := coreRegistryDocuments + 1
  let mut sequence := Formatter.Command.sequence
  for h : index in [0:commands.size] do
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
      coreDocuments := coreDocuments + 1
      structuralDocuments := structuralDocuments + 1
      continue
    let result ← Lean.Core.CoreM.toIO' (Formatter.Command.command ownership command.stx)
      { fileName := sourcePath.toString, fileMap, options := command.options }
      { env := command.env }
    let formatted ← match result with
      | .ok formatted => pure formatted
      | .error failure => return .error failure
    registryNodes := registryNodes + formatted.document.size
    match formatted.trace.resolution with
    | .explicit _ => explicitDocuments := explicitDocuments + 1
    | .descriptor => descriptorDocuments := descriptorDocuments + 1
    match formatted.owner with
    | .core => coreDocuments := coreDocuments + 1
    | .registry => registryDocuments := registryDocuments + 1
    match formatted.mechanism with
    | .structural => structuralDocuments := structuralDocuments + 1
    | .registry =>
      match formatted.trace.surfaceOwner with
      | .extension => extensionRegistryDocuments := extensionRegistryDocuments + 1
      | _ => coreRegistryDocuments := coreRegistryDocuments + 1
    let indentation := Doc.text ("".pushn ' ' placement.indent)
    -- Docstrings are command syntax even though Lean stores their opening token in `SourceInfo` and
    -- comment ownership classifies that token as `doc`. Their structural command document is the
    -- sole emitter; treating the opening as outer trivia duplicates `/--` or `/-!` and makes the
    -- candidate an unterminated nested comment.
    let ownsDocSyntax := command.stx.isOfKind ``Lean.Parser.Command.moduleDoc ||
      containsKind ``Lean.Parser.Command.docComment command.stx
    -- Command-boundary trivia belongs to whole-module composition. Registered command syntax is
    -- boundary-stripped before delegation, so the ownership layer remains its sole outer emitter.
    let leadingTrivia := if ownsDocSyntax then Doc.empty else
      match Formatter.Trivia.leading ownership command.stx with
      | some comments => comments ++ Doc.hard
      | none => Doc.empty
    let trailingTrivia := if formatted.mechanism == .registry then
        match Formatter.Trivia.trailing ownership command.stx stop with
        | some comments => comments
        | none => Doc.empty
      else Doc.empty
    let commandDocument := Doc.nest placement.indent
      (indentation ++ leadingTrivia ++ formatted.document ++ trailingTrivia)
    document? := appendDocument document? <|
      Doc.mark ⟨start, stop⟩ (leading ++ commandDocument ++ boundaryTail ++ separator)
  let tailRange : SourceRange := ⟨source.terminalStop, source.normalizedBytes⟩
  if tailRange.start < tailRange.stop then
    document? := appendDocument document? <|
      Doc.mark tailRange (Doc.verbatim (normalizedSlice bytes tailRange))
    coreDocuments := coreDocuments + 1
    structuralDocuments := structuralDocuments + 1
  let document := document?.getD Doc.empty
  let rendered := renderDetailed width document
  return .ok {
    text := rendered.text
    sourceMap := rendered.sourceMap
    headerContract := Formatter.Command.headerContract header
    commentContract := Comments.contract normalized ownership
    metrics := {
      frontendRuns := 1
      commands := commands.size
      coreDocuments
      registryDocuments
      structuralDocuments
      coreRegistryDocuments
      extensionRegistryDocuments
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
  plugin.path.fileName.any fun name => name.startsWith "libLake"

private def ofMessageSeverity : Lean.MessageSeverity → Severity
  | .information => .information
  | .warning => .warning
  | .error => .error

/- Normalize the compiler diagnostics the exact frontend emitted into immutable rule facts. Only the
`kind`s the semantic rules surface (`surfacedDiagnosticKinds`) are kept — one source of truth shared
with the rules — so the artifact never carries a diagnostic no rule reads. `msg.kind` is the pure
top-level tag; only matching messages are serialized (`msg.serialize`, which renders `data` and needs
`BaseIO`). Each message's `Position` is converted to a normalized-source byte offset through the
frontend's `FileMap` — `mkInputContext` built it on `crlfToLf`-normalized source, so it shares the
projection's coordinate system — and the range is clamped to `[0, sourceBytes]`, dropping any position
that a macro reattribution placed outside this module's own bytes (`ruff-11` `notes/01-authority.md`
§§4-5,12). No `Environment`, `Position`, or `FileMap` crosses into a rule; only this data. -/
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

/- The user-facing display of a resolved constant: the module-private mangling (`_private.M.0.foo`)
stripped to what the source writes (`foo`, or a qualified `Foo.bar`). Pure on `Name` — no `Environment`
— so it is a fact the rule reads as a plain string, never a `Name`. -/
private def occurrenceDisplay (n : Lean.Name) : String := (Lean.privateToUserName n).toString

/- Re-derive the owned deprecation-occurrence facts from the whole-file info trees. This is the fold
`ruff-11b` `ROS-SPEC` proved reachable through the same snapshot tree `analyzeExact` already walks for
the message log (`notes/01-model.md` §2, `evidence/infotree_probe.lean`): every command's info tree
lives on its `Snapshot.infoTree?`, so `tree.getAll.filterMap (·.infoTree?)` — a *consumer-side* fold,
not a producer change — surfaces the whole file, avoiding the per-command info reset that would limit
`waitForFinalCmdState?` to the last command.

For each `TermInfo` whose elaborated `expr` *is* a constant (`.constName?` is `some` — which already
excludes an applied receiver, whose term is an `.app`, and dot-notation, whose term is the application)
that carries `@[deprecated]`, and which is a use rather than the declaration binder (`isBinder`), one
occurrence is recorded. Ranges come straight from `Info.range?` — already normalized-source byte
offsets (the parser positions index the string `mkInputContext` normalized), so unlike a diagnostic's
`Position` they need no `FileMap` round-trip — clamped to the module's byte span. Each use-site emits
its `TermInfo` more than once, so this deduplicates by range. `fixable` is decided here
(`notes/01-model.md` §5): a `newName?` must exist and the occurrence must spell a single bare
identifier token, the conservative predicate a textual rename preserves; everything else is
report-only and the output re-elaboration validator backstops the rest. -/
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
  -- The occurrence is fixable only when its source spelling is *exactly* the resolved constant's own
  -- full display name (`notes/01-model.md` §5.3-5.4): then replacing that whole span with the
  -- replacement's full display re-resolves unambiguously to the new constant, independent of `open`/dot
  -- context. A spelling that differs from the full name — an `open`-shadowed short name (`oldNs`
  -- resolving to `N.oldNs`), a dot-notation projection head (`x.foo` resolving to `T.foo`), an applied
  -- receiver with the constant implicit — is *not* a rename we can prove, so it stays report-only and
  -- the compiler's own FMT012 diagnostic still reports it. Backstopped by the re-elaboration validator
  -- (§6): even an accepted spelling that fails to resolve is caught before publish, never on disk.
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

/- Execute Lean's ordinary header and sequential command frontend under the exact `ModuleSetup`
owned by the target Lake workspace. The resulting projection is the same one emitted by the
compiler plugin; no accumulated environment or parser state crosses this process invocation. -/
unsafe def analyzeExact (setup : Lean.ModuleSetup) (source : String)
    (sourcePath : System.FilePath) (captureSemantic : Bool := false)
    (captureOccurrences : Bool := false) (captureComments : Bool := false)
    (captureFormatDraft : Bool := false) (validateFormatDraft : Bool := false)
    (formatWidth : Nat := 100) (loadDynlibs : Bool := true) : IO AnalysisEnvelope := do
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
      -- This executable already imports and links Lake. Reloading the setup's Lake support plugin
      -- attempts to initialize the same runtime module twice; retain only target-specific plugins.
      plugins := setup.plugins.filter (!isApplicationRuntimePlugin ·)
    }
  let context : Lean.Language.ProcessingContext := { input with }
  let snapshot ← Lean.Language.Lean.process setupImports none context
  let tree := Lean.Language.toSnapshotTree snapshot
  let messages := tree.getAll.map (·.diagnostics.msgLog) |>.foldl (· ++ ·) {}
  let some commandState := Lean.Language.Lean.waitForFinalCmdState? snapshot
    | return ← broken messages
  if messages.hasErrors then
    return ← broken messages
  let (liveCommands, terminal?) := processedLiveCommands snapshot
  let commands := liveCommands.map (·.stx)
  let surfaceSummary := CoreSurface.summarize <|
    liveCommands.foldl (init := #[]) fun observations command =>
      observations ++ CoreSurface.observe command.env .command command.stx
  -- Semantic rule facts are captured only under rule demand. The whole-file occurrence fold remains
  -- separately gated, so report-only semantic checks do not pay for fix ownership.
  let normalizedSource := (LosslessSource.normalize source).1
  let semantic ← if captureSemantic then do
      let diagnostics ← captureDiagnostics input.fileMap normalizedSource.utf8ByteSize messages
      let occurrences? := if captureOccurrences then
          some (captureDeprecatedOccurrences tree normalizedSource normalizedSource.utf8ByteSize)
        else none
      pure (some { diagnostics, occurrences? })
    else pure none
  -- `mkInputContext` normalized `source` before parsing it, so every offset above indexes the
  -- normalized string. Measuring the artifact against `source` itself would mix two coordinate
  -- systems inside one artifact for any file that uses CRLF.
  let some terminal := terminal?
    | throw <| IO.userError "successful frontend produced no terminal command"
  let commandOptions := liveCommands.map fun command => (command.stx, command.options)
  let artifact ← match ModuleArtifact.ofParsedModule setup.name.toString normalizedSource
      commandOptions terminal commandState.scopes.head!.opts semantic with
    | .ok artifact => pure artifact
    | .error error => throw <| IO.userError s!"could not encode syntax artifact: {error}"
  let projection := LosslessSource.ofSource setup.name.toString normalizedSource commands terminal?
  let needsDraft := captureFormatDraft || validateFormatDraft
  let ownership? := if captureComments || needsDraft then
      let suppressed := (Suppression.collect projection normalizedSource).directives.map (·.scopeRange)
      some <| Comments.build normalizedSource snapshot.stx commands terminal? suppressed
    else none
  let commentSummary? := if captureComments then
      ownership?.map (Comments.summary normalizedSource)
    else none
  let (firstDraft?, formatFailure?) ← if needsDraft then do
      let some ownership := ownership?
        | throw <| IO.userError "format draft has no comment ownership"
      match ← buildFormatDraft normalizedSource projection sourcePath input.fileMap ownership
          snapshot.stx commandState.env options liveCommands formatWidth with
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
      let candidate ← analyzeExact setup first.text sourcePath
        (captureFormatDraft := true) (formatWidth := formatWidth) (loadDynlibs := false)
      if !candidate.diagnostics.isEmpty then
        pure (none, some {
          gate := .diagnostics
          detail := String.intercalate "\n" candidate.diagnostics.toList })
      else match candidate.artifact?, candidate.formatDraft?, candidate.formatFailure? with
        | some candidateArtifact, some second, none =>
          match candidateArtifact.materialize first.text with
          | .error error => pure (none, some { gate := .structure, detail := error })
          | .ok candidateMaterialized =>
            match Validator.admit normalizedSource projection first candidateMaterialized.source second with
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
    surfaceSummary? := some surfaceSummary
    commentSummary? := commentSummary?
    formatDraft? := formatDraft?
    formatFailure? := formatFailure?
    canonical? := canonical?
    validationFailure? := validationFailure? }

/-- Test-only admission of externally supplied candidate bytes through the same production
comparator and second formatting pass. Product formatting never accepts candidate bytes from a
caller; this operation exists so mutation fixtures can exercise the real gates. -/
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
      match Validator.admit normalizedSource beforeMaterialized.source first afterMaterialized.source second with
      | .ok canonical => return { canonical? := some canonical }
      | .error failure => return { failure? := some failure }
    | .error error, _ | _, .error error => return candidateFailure .structure error
  | _, _, _, _, some failure =>
    return candidateFailure .formatter failure.detail
  | _, _, _, _, _ =>
    return candidateFailure .structure
      "candidate validation did not produce both frontend projections"

/- Render from a compiler-owned syntax artifact under the environment serialized in the matching
target `.olean`. The original source is not elaborated. Only the produced candidate takes the exact
frontend, which preserves the same structural and idempotence admission gates as `analyzeExact`. -/
unsafe def analyzeArtifact (setup : Lean.ModuleSetup) (moduleFile : System.FilePath)
    (artifact : ModuleArtifact) (source : String) (sourcePath : System.FilePath)
    (formatWidth : Nat := 100) : IO AnalysisEnvelope := do
  Lean.initSearchPath (← Lean.findSysroot)
  Lean.enableInitializersExecution
  setup.dynlibs.forM Lean.loadDynlib
  let normalized := (LosslessSource.normalize source).1
  let materialized ← match artifact.materialize source with
    | .ok materialized => pure materialized
    | .error error => throw <| IO.userError s!"invalid syntax artifact: {error}"
  let input := Lean.Parser.mkInputContext source sourcePath.toString
  let (header, _, headerMessages) ← Lean.Parser.parseHeader input
  if headerMessages.hasErrors then
    return ← broken headerMessages
  let (moduleData, _region) ← Lean.readModuleData moduleFile
  let level := if moduleData.isModule then Lean.OLeanLevel.exported else .private
  let artifacts : Lean.NameMap Lean.ImportArtifacts :=
    ({} : Lean.NameMap Lean.ImportArtifacts).insert setup.name (.ofArrays #[#[moduleFile]])
  let environment ← Lean.importModules #[{ module := setup.name }] setup.options.toOptions
    (trustLevel := 1024) (loadExts := true) (level := level) (arts := artifacts)
  let commands := materialized.commands.zip materialized.options |>.map fun (stx, options) =>
    { stx, env := environment, options : LiveCommand }
  let suppressed := (Suppression.collect materialized.source normalized).directives.map (·.scopeRange)
  let ownership := Comments.build normalized header.raw materialized.commands
    (some materialized.terminal) suppressed
  let draft ← match ← buildFormatDraft normalized materialized.source sourcePath input.fileMap
      ownership header.raw environment (materialized.options[0]?.getD setup.options.toOptions)
      commands formatWidth with
    | .ok draft => pure draft
    | .error failure => return {
        artifact? := some artifact
        formatFailure? := some failure
        validationFailure? := some { gate := .formatter, detail := failure.detail } }
  let candidate ← analyzeExact setup draft.text sourcePath
    (captureFormatDraft := true) (formatWidth := formatWidth) (loadDynlibs := false)
  if !candidate.diagnostics.isEmpty then
    return {
      artifact? := some artifact
      validationFailure? := some {
        gate := .diagnostics
        detail := String.intercalate "\n" candidate.diagnostics.toList }
    }
  match candidate.artifact?, candidate.formatDraft?, candidate.formatFailure? with
  | some candidateArtifact, some second, none =>
    match candidateArtifact.materialize draft.text with
    | .error error => return {
        artifact? := some artifact
        validationFailure? := some { gate := .structure, detail := error } }
    | .ok candidateMaterialized =>
      match Validator.admit normalized materialized.source draft candidateMaterialized.source second with
      | .ok canonical => return { artifact? := some artifact, canonical? := some canonical }
      | .error failure => return { artifact? := some artifact, validationFailure? := some failure }
  | _, _, some failure => return {
      artifact? := some artifact
      validationFailure? := some { gate := .formatter, detail := failure.detail } }
  | _, _, _ => return {
      artifact? := some artifact
      validationFailure? := some {
        gate := .structure
        detail := "candidate frontend returned no artifact or second draft" } }

/- Extract the compiler-owned payload from one exact module artifact. Process exit remains the
reclamation boundary; the returned value is compact and contains no environment-owned reference. -/
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
