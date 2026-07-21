module

import all LeanFmt.ArtifactStore
import all LeanFmt.Rules
import Lean.Elab.Frontend
import Lean.Server.InfoUtils
import Lean.Linter.Deprecated

namespace LeanFmt.Internal

/- The process response is deliberately semantic. It contains neither setup paths nor execution
strategy, so the parent cannot accidentally key reporting on how it obtained the analysis. -/
structure AnalysisEnvelope where
  artifact? : Option ModuleArtifact
  diagnostics : Array String := #[]
  deriving Lean.ToJson, Lean.FromJson

/- Silent messages are carriers, not diagnostics. The compiler plugin writes the module artifact into
the persistent lint log as a silent `.information` message, so an integrated project's own frontend run
sees it in the log alongside real errors. Reporting it would print the whole serialized projection as
a broken-source diagnostic. Found by `tests/downstream/run.sh`: it needs a plugin-enabled project *and*
a file that elaborates far enough for the module linter to run, which is why no in-repo broken fixture
caught it — `MalformedHeader` and `UnresolvedImport` both fail before the linter fires. -/
private def messageStrings (messages : Lean.MessageLog) : IO (Array String) :=
  messages.toArray.filter (!·.isSilent) |>.mapM (·.toString true)

private def broken (messages : Lean.MessageLog) : IO AnalysisEnvelope := do
  return { artifact? := none, diagnostics := ← messageStrings messages }

/- Split the snapshot chain the way a module linter sees it: the ordinary command stream, and the
terminal command that ended the file. The terminal is `eoi`, or `#exit` when a file stops early and
leaves an unparsed tail; dropping it would silently discard both the tail and the end of the parsed
region. `isTerminalCommand` also admits `import`, which cannot occur here because the header is
processed before `firstCmdSnap`. -/
private partial def collectCommands
    (snapshot : Lean.Language.Lean.CommandParsedSnapshot)
    (commands : Array Lean.Syntax := #[])
    (terminal? : Option Lean.Syntax := none) : Array Lean.Syntax × Option Lean.Syntax :=
  let isTerminal := Lean.Parser.isTerminalCommand snapshot.stx
  let commands := if isTerminal then commands else commands.push snapshot.stx
  let terminal? := if isTerminal then terminal? <|> some snapshot.stx else terminal?
  match snapshot.nextCmdSnap? with
  | some next => collectCommands next.get commands terminal?
  | none => (commands, terminal?)

private def processedCommands
    (snapshot : Lean.Language.Lean.InitialSnapshot) : Array Lean.Syntax × Option Lean.Syntax :=
  match snapshot.result? with
  | none => (#[], none)
  | some parsed =>
    match parsed.processedSnap.get.result? with
    | none => (#[], none)
    | some processed => collectCommands processed.firstCmdSnap.get

private def isApplicationRuntimePlugin (plugin : Lean.Plugin) : Bool :=
  plugin.path.fileName.any fun name => name.startsWith "libLake"

/- The distinct syntax node kinds appearing anywhere in `stx`. Design B (`ruff-05b`
`notes/01-semantic-facts.md`) captures one spacing template per distinct kind, so the module is
deduplicated here rather than once per occurrence. -/
private partial def collectKinds (stx : Lean.Syntax) (acc : Lean.NameSet) : Lean.NameSet :=
  match stx with
  | .node _ kind args =>
    let acc := if kind.isAnonymous then acc else acc.insert kind
    args.foldl (init := acc) fun acc arg => collectKinds arg acc
  | _ => acc

/- Recover a notation's declared atom strings — untrimmed, in source order — by walking its
`ParserDescr`. This is the pretty-printing hint the parser trims away (`Init/Prelude.lean:5389`,
`Lean/Parser/Basic.lean:1114`); it survives only in the descriptor. Matches `symbol` /
`nonReservedSymbol` / `unicodeSymbol` (the operator atoms `RLF-NOTATION` needs) and recurses through
the structural combinators (`unary`/`binary`/`node`/`trailingNode`/`nodeWithAntiquot`, and into a
`sepBy` separator sub-parser). `const`/`cat`/`parser` leaves contribute nothing and degrade to
conservative source bytes. No formatter runs and no `Environment` escapes. -/
private partial def descrAtoms : Lean.ParserDescr → Array String → Array String
  | .symbol s, acc => acc.push s
  | .nonReservedSymbol s _, acc => acc.push s
  | .unicodeSymbol s _ _, acc => acc.push s
  | .unary _ p, acc => descrAtoms p acc
  | .binary _ p₁ p₂, acc => descrAtoms p₂ (descrAtoms p₁ acc)
  | .node _ _ p, acc => descrAtoms p acc
  | .trailingNode _ _ _ p, acc => descrAtoms p acc
  | .nodeWithAntiquot _ _ p, acc => descrAtoms p acc
  | .sepBy p _ psep _, acc => descrAtoms psep (descrAtoms p acc)
  | .sepBy1 p _ psep _, acc => descrAtoms psep (descrAtoms p acc)
  | _, acc => acc

/- The declared notation spacing for every notation kind present in `commands`. Each present kind's
`ParserDescr` is read via `evalConst` — the compiled *meta* IR the parser and pretty printer already
interpret (`Lean/PrettyPrinter/Basic.lean` `runForNodeKind`), which the module system **retains** for
imported constants (unlike `ConstantInfo.value?`, the kernel `Expr`, which it strips — the defect this
replaced). The type is guarded to `ParserDescr`/`TrailingParserDescr` before eval, exactly as
`runForNodeKind` does, so `infixl`/`infixr` trailing notations are captured too. A kind that is not a
descriptor, or whose eval fails, is omitted — never invented. `unsafe` because `evalConst` runs
compiled code; `analyzeExact` (its only caller) already is. -/
private unsafe def captureNotationSpacing (env : Lean.Environment) (options : Lean.Options)
    (commands : Array Lean.Syntax) : SemanticProjection :=
  let kinds := commands.foldl (init := Lean.NameSet.empty) fun acc c => collectKinds c acc
  let notations := kinds.toList.foldl (init := #[]) fun acc kind =>
    match env.find? kind with
    | some ci =>
      if ci.type.isConstOf ``Lean.ParserDescr || ci.type.isConstOf ``Lean.TrailingParserDescr then
        match env.evalConst Lean.ParserDescr options kind with
        | .ok descr =>
          let atoms := descrAtoms descr #[]
          if atoms.isEmpty then acc else acc.push { kind := kind.toString, atoms }
        | .error _ => acc
      else acc
    | none => acc
  { notations }

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
  -- the compiler's own FMT014 diagnostic still reports it. Backstopped by the re-elaboration validator
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
    (captureOccurrences : Bool := false) : IO AnalysisEnvelope := do
  Lean.initSearchPath (← Lean.findSysroot)
  Lean.enableInitializersExecution
  let input := Lean.Parser.mkInputContext source sourcePath.toString
  let options := Lean.Elab.async.setIfNotSet setup.options.toOptions true
  let setupImports (header : Lean.Elab.HeaderSyntax) := do
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
  let (commands, terminal?) := processedCommands snapshot
  -- The semantic projection is captured only under demand (`captureSemantic`, set by a run that
  -- renders canonical text *or* selects a `.semantic` rule). The two cheap sub-facts — `notations` and
  -- `diagnostics` — are captured together (`ruff-11` `notes/01-authority.md` §6); the one expensive
  -- sub-fact, the whole-file info-tree occurrence fold, is captured only under the *separate*
  -- `captureOccurrences` capability (`ruff-11b` Design B, `notes/01-model.md` §4), so a plain `format`
  -- or a `check --select FMT015` never pays the walk. `occurrences? := none` records *not captured* (a
  -- fixable demand must miss the cache); `some` records captured-possibly-empty. `commandState.env` is
  -- the module's final environment; `messages` is the whole-file diagnostic log; `input.fileMap` is
  -- normalized-coordinate; `tree` is the same snapshot tree walked for `messages`. The always-on plugin
  -- producer sets no capability, keeping integrated builds on the syntax-only path.
  let normalizedSource := (LosslessSource.normalize source).1
  let semantic ← if captureSemantic then do
      let diagnostics ← captureDiagnostics input.fileMap normalizedSource.utf8ByteSize messages
      let occurrences? := if captureOccurrences then
          some (captureDeprecatedOccurrences tree normalizedSource normalizedSource.utf8ByteSize)
        else none
      pure (some { captureNotationSpacing commandState.env options commands with
        diagnostics, occurrences? })
    else pure none
  -- `mkInputContext` normalized `source` before parsing it, so every offset above indexes the
  -- normalized string. Measuring the artifact against `source` itself would mix two coordinate
  -- systems inside one artifact for any file that uses CRLF.
  let artifact := ModuleArtifact.ofParsedModule setup.name.toString
    normalizedSource commands terminal? semantic
  return { artifact? := some artifact }

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
