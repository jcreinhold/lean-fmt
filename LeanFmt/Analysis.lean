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

/- Execute Lean's ordinary header and sequential command frontend under the exact `ModuleSetup`
owned by the target Lake workspace. The resulting projection is the same one emitted by the
compiler plugin; no accumulated environment or parser state crosses this process invocation. -/
unsafe def analyzeExact (setup : Lean.ModuleSetup) (source : String)
    (sourcePath : System.FilePath) : IO AnalysisEnvelope := do
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
  let some _commandState := Lean.Language.Lean.waitForFinalCmdState? snapshot
    | return ← broken messages
  if messages.hasErrors then
    return ← broken messages
  let (commands, terminal?) := processedCommands snapshot
  -- `mkInputContext` normalized `source` before parsing it, so every offset above indexes the
  -- normalized string. Measuring the artifact against `source` itself would mix two coordinate
  -- systems inside one artifact for any file that uses CRLF.
  let artifact := ModuleArtifact.ofParsedModule setup.name.toString
    (LosslessSource.normalize source).1 commands terminal?
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
