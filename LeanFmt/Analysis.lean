module

import all LeanFmt.ArtifactStore
import all LeanFmt.Rules
import Lean.Elab.Frontend

namespace LeanFmt.Internal

/- The process response is deliberately semantic. It contains neither setup paths nor execution
strategy, so the parent cannot accidentally key reporting on how analysis was obtained. -/
structure AnalysisEnvelope where
  artifact? : Option ModuleArtifact
  diagnostics : Array String := #[]
  deriving Lean.ToJson, Lean.FromJson

private def messageStrings (messages : Lean.MessageLog) : IO (Array String) :=
  messages.toArray.mapM (·.toString true)

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

/- Execute Lean's ordinary header and sequential command frontend under the exact `ModuleSetup`
owned by the target Lake workspace. The resulting projection is the same one emitted by the
compiler plugin; no accumulated environment or parser state crosses this process invocation. -/
unsafe def analyzeExact (setup : Lean.ModuleSetup) (source : String)
    (sourcePath : System.FilePath) (captureSemantic : Bool := false) : IO AnalysisEnvelope := do
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
  -- The semantic projection is captured only under demand (`captureSemantic`, set by a `format`-tier
  -- run). `commandState.env` is the module's final environment — the parser and notation decls are
  -- live here and nowhere downstream — so the declared spacing is read into immutable data at this
  -- one seam. The always-on plugin producer never sets the flag, keeping integrated builds on the
  -- syntax-only path (`ArtifactModel.lean` `ofParsedModule`).
  let semantic := if captureSemantic then some (captureNotationSpacing commandState.env options commands) else none
  -- `mkInputContext` normalized `source` before parsing it, so every offset above indexes the
  -- normalized string. Measuring the artifact against `source` itself would mix two coordinate
  -- systems inside one artifact for any file that uses CRLF.
  let artifact := ModuleArtifact.ofParsedModule setup.name.toString
    (LosslessSource.normalize source).1 commands terminal? semantic
  return { artifact? := some artifact }

/- Extract the compiler-owned payload from one exact module artifact. Process exit remains the
reclamation boundary; the returned value is compact and contains no environment-owned reference. -/
unsafe def compilerArtifact? (moduleName : Lean.Name)
    (moduleFile : System.FilePath) : IO (Option ModuleArtifact) := do
  Lean.initSearchPath (← Lean.findSysroot)
  let (moduleData, _region) ← Lean.readModuleData moduleFile
  let level := if moduleData.isModule then Lean.OLeanLevel.exported else .private
  let artifacts : Lean.NameMap Lean.ImportArtifacts :=
    ({} : Lean.NameMap Lean.ImportArtifacts).insert moduleName (.ofArray #[moduleFile])
  let environment ← Lean.importModules #[{ module := moduleName }] {}
    (trustLevel := 1024) (loadExts := false) (level := level) (arts := artifacts)
  return fromEnvironment? environment moduleName

end LeanFmt.Internal
