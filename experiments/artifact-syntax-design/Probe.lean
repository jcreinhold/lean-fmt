module

import all LeanFmt.ArtifactModel

import Lean.Elab.Frontend
import Lean.PrettyPrinter

open Lean
open LeanFmt.Internal

private structure LiveCommand where
  stx : Syntax
  env : Environment
  options : Options

private partial def collectLiveCommands (snapshot : Language.Lean.CommandParsedSnapshot)
    (state : Elab.Command.State) (commands : Array LiveCommand := #[])
    (terminal? : Option Syntax := none) : Array LiveCommand × Option Syntax :=
  let terminal := Parser.isTerminalCommand snapshot.stx
  let commands := if terminal then commands else commands.push {
    stx := snapshot.stx
    env := state.env
    options := state.scopes.head!.opts }
  let terminal? := if terminal then terminal? <|> some snapshot.stx else terminal?
  let nextState := snapshot.elabSnap.resultSnap.get.cmdState
  match snapshot.nextCmdSnap? with
  | some next => collectLiveCommands next.get nextState commands terminal?
  | none => (commands, terminal?)

private def processedLiveCommands (snapshot : Language.Lean.InitialSnapshot) :
    Array LiveCommand × Option Syntax :=
  match snapshot.result? with
  | none => (#[], none)
  | some parsed =>
    match parsed.processedSnap.get.result? with
    | none => (#[], none)
    | some processed => collectLiveCommands processed.firstCmdSnap.get processed.cmdState

private structure CodecState where
  kinds : Array Name := #[]
  kindIndex : Std.HashMap Name Nat := {}
  entries : Array Json := #[]
  nodes : Nat := 0
  leaves : Nat := 0
  choices : Nat := 0
  synthetic : Nat := 0
  missing : Nat := 0
  preresolved : Nat := 0

private def CodecState.intern (state : CodecState) (kind : Name) : Nat × CodecState :=
  match state.kindIndex[kind]? with
  | some index => (index, state)
  | none =>
    let index := state.kinds.size
    (index, { state with
      kinds := state.kinds.push kind
      kindIndex := state.kindIndex.insert kind index })

private def infoJson : SourceInfo → Json
  | .none => .num 0
  | .original leading pos trailing endPos => .arr #[
      .num 1, .num leading.startPos.byteIdx, .num pos.byteIdx,
      .num endPos.byteIdx, .num trailing.stopPos.byteIdx]
  | .synthetic pos endPos canonical => .arr #[
      .num 2, .num pos.byteIdx, .num endPos.byteIdx, .bool canonical]

private def preresolvedJson : Syntax.Preresolved → Json
  | .namespace name => .arr #[.num 0, Lean.toJson name]
  | .decl name fields => .arr #[.num 1, Lean.toJson name, Lean.toJson fields]

private partial def encodeSyntax (stx : Syntax) (state : CodecState) : CodecState :=
  match stx with
  | .missing => { state with
      entries := state.entries.push (.arr #[.num 0])
      missing := state.missing + 1 }
  | .node info kind children =>
    let (kindIndex, state) := state.intern kind
    let state := { state with
      entries := state.entries.push (.arr #[
        .num 1, infoJson info, .num kindIndex, .num children.size])
      nodes := state.nodes + 1
      choices := state.choices + if kind == choiceKind then 1 else 0 }
    children.foldl (init := state) fun state child => encodeSyntax child state
  | .atom info value =>
    let value? := match info with
      | .original .. => Json.null
      | _ => .str value
    { state with
      entries := state.entries.push (.arr #[.num 2, infoJson info, value?])
      leaves := state.leaves + 1
      synthetic := state.synthetic + if info matches .synthetic .. then 1 else 0 }
  | .ident info raw value preresolved =>
    let raw? := match info with
      | .original .. => Json.null
      | _ => .str raw.toString
    { state with
      entries := state.entries.push (.arr #[.num 3, infoJson info, raw?, Lean.toJson value,
        .arr (preresolved.toArray.map preresolvedJson)])
      leaves := state.leaves + 1
      synthetic := state.synthetic + if info matches .synthetic .. then 1 else 0
      preresolved := state.preresolved + preresolved.length }

private def nat (json : Json) : Except String Nat := Lean.fromJson? json

private def array (json : Json) : Except String (Array Json) := json.getArr?

private def field (fields : Array Json) (index : Nat) : Except String Json :=
  match fields[index]? with
  | some value => .ok value
  | none => .error s!"missing field {index}"

private def rawPos (offset : Nat) : String.Pos.Raw := ⟨offset⟩

private def rawSlice (source : String) (start stop : Nat) : Substring.Raw :=
  Substring.Raw.mk source (rawPos start) (rawPos stop)

private def decodeInfo (source : String) (json : Json) : Except String SourceInfo := do
  if let .num 0 := json then
    return .none
  let fields ← array json
  match ← nat (← field fields 0) with
  | 1 =>
    let leadingStart ← nat (← field fields 1)
    let position ← nat (← field fields 2)
    let endPosition ← nat (← field fields 3)
    let trailingStop ← nat (← field fields 4)
    return .original (rawSlice source leadingStart position) (rawPos position)
      (rawSlice source endPosition trailingStop) (rawPos endPosition)
  | 2 =>
    let position ← nat (← field fields 1)
    let endPosition ← nat (← field fields 2)
    let canonical ← Lean.fromJson? (← field fields 3)
    return .synthetic (rawPos position) (rawPos endPosition) canonical
  | tag => throw s!"unknown source-info tag {tag}"

private def infoRange (info : SourceInfo) : Option (Nat × Nat) :=
  match info with
  | .original _ pos _ endPos => some (pos.byteIdx, endPos.byteIdx)
  | .synthetic pos endPos _ => some (pos.byteIdx, endPos.byteIdx)
  | .none => none

private def sourceText (source : String) (info : SourceInfo) : Except String String := do
  let some (start, stop) := infoRange info
    | throw "source-backed leaf has no range"
  let bytes := source.toUTF8
  unless start <= stop && stop <= bytes.size do
    throw s!"leaf range {start}:{stop} is outside {bytes.size} source bytes"
  return String.fromUTF8! (bytes.extract start stop)

private def decodePreresolved (json : Json) : Except String Syntax.Preresolved := do
  let fields ← array json
  match ← nat (← field fields 0) with
  | 0 => return .namespace (← Lean.fromJson? (← field fields 1))
  | 1 =>
    let name ← Lean.fromJson? (← field fields 1)
    let fields ← Lean.fromJson? (← field fields 2)
    return .decl name fields
  | tag => throw s!"unknown preresolved tag {tag}"

private partial def decodeSyntax (source : String) (kinds entries : Array Json)
    (index : Nat) : Except String (Syntax × Nat) := do
  let entry ← field entries index
  let fields ← array entry
  match ← nat (← field fields 0) with
  | 0 => return (.missing, index + 1)
  | 1 =>
    let info ← decodeInfo source (← field fields 1)
    let kindIndex ← nat (← field fields 2)
    let kind : Name ← Lean.fromJson? (← field kinds kindIndex)
    let childCount ← nat (← field fields 3)
    let mut children := #[]
    let mut cursor := index + 1
    for _ in [0:childCount] do
      let (child, next) ← decodeSyntax source kinds entries cursor
      children := children.push child
      cursor := next
    return (.node info kind children, cursor)
  | 2 =>
    let info ← decodeInfo source (← field fields 1)
    let valueJson ← field fields 2
    let value ← match valueJson with
      | .null => sourceText source info
      | _ => Lean.fromJson? valueJson
    return (.atom info value, index + 1)
  | 3 =>
    let info ← decodeInfo source (← field fields 1)
    let rawJson ← field fields 2
    let value : Name ← Lean.fromJson? (← field fields 3)
    let preresolvedFields ← array (← field fields 4)
    let preresolved ← preresolvedFields.toList.mapM decodePreresolved
    let raw ← match rawJson with
      | .null =>
        let some (start, stop) := infoRange info
          | throw "source-backed identifier has no range"
        pure (rawSlice source start stop)
      | _ =>
        let raw : String ← Lean.fromJson? rawJson
        pure raw.toRawSubstring
    return (.ident info raw value preresolved, index + 1)
  | tag => throw s!"unknown syntax tag {tag}"

private structure Encoded where
  json : Json
  state : CodecState

private def encodeRoots (roots : Array Syntax) : Encoded :=
  let state := roots.foldl (init := {}) fun state root => encodeSyntax root state
  let json := Json.mkObj [
    ("schema", .str "lean-fmt.syntax-cst.prototype.v1"),
    ("kinds", .arr (state.kinds.map Lean.toJson)),
    ("roots", .num roots.size),
    ("entries", .arr state.entries)]
  { json, state }

private def decodeRoots (source : String) (json : Json) : Except String (Array Syntax) := do
  let .ok schema := json.getObjValAs? String "schema" | throw "missing schema"
  unless schema == "lean-fmt.syntax-cst.prototype.v1" do
    throw s!"unsupported schema {schema}"
  let kinds ← array (← json.getObjVal? "kinds")
  let rootCount ← nat (← json.getObjVal? "roots")
  let entries ← array (← json.getObjVal? "entries")
  let mut roots := #[]
  let mut cursor := 0
  for _ in [0:rootCount] do
    let (root, next) ← decodeSyntax source kinds entries cursor
    roots := roots.push root
    cursor := next
  unless cursor == entries.size do
    throw s!"decoded {cursor} of {entries.size} entries"
  return roots

private def dataValueJson : DataValue → Json
  | .ofString value => .arr #[.num 0, Lean.toJson value]
  | .ofBool value => .arr #[.num 1, Lean.toJson value]
  | .ofName value => .arr #[.num 2, Lean.toJson value]
  | .ofNat value => .arr #[.num 3, Lean.toJson value]
  | .ofInt value => .arr #[.num 4, Lean.toJson value]
  | .ofSyntax value => .arr #[.num 5, (encodeRoots #[value]).json]

private def optionsJson (options : Options) : Json := Id.run do
  let mut entries := #[]
  for (name, value) in options do
    entries := entries.push (.arr #[Lean.toJson name, dataValueJson value])
  return .arr entries

private partial def decodeDataValue (source : String) (json : Json) : Except String DataValue := do
  let fields ← array json
  match ← nat (← field fields 0) with
  | 0 => return .ofString (← Lean.fromJson? (← field fields 1))
  | 1 => return .ofBool (← Lean.fromJson? (← field fields 1))
  | 2 => return .ofName (← Lean.fromJson? (← field fields 1))
  | 3 => return .ofNat (← Lean.fromJson? (← field fields 1))
  | 4 => return .ofInt (← Lean.fromJson? (← field fields 1))
  | 5 =>
    let roots ← decodeRoots source (← field fields 1)
    let some value := roots[0]? | throw "syntax option has no root"
    return .ofSyntax value
  | tag => throw s!"unknown option value tag {tag}"

private def decodeOptions (source : String) (json : Json) : Except String Options := do
  let entries ← array json
  let mut options : Options := {}
  for entry in entries do
    let fields ← array entry
    let name : Name ← Lean.fromJson? (← field fields 0)
    let value ← decodeDataValue source (← field fields 1)
    options := options.insert name value
  return options

private def formatCommand (environment : Environment) (options : Options) (stx : Syntax)
    (width : Nat) : IO (Except String String) := do
  try
    let document ← Core.CoreM.toIO' (PrettyPrinter.formatCategory `command stx)
      { fileName := "ArtifactSyntaxProbe.lean", fileMap := default, options }
      { env := environment }
    return .ok (document.pretty width)
  catch exception =>
    return .error (toString exception)

private def sameFormat : Except String String → Except String String → Bool
  | .ok left, .ok right => left == right
  | .error left, .error right => left == right
  | _, _ => false

private def messages (snapshot : Language.Lean.InitialSnapshot) : IO (Array String) := do
  let tree := Language.toSnapshotTree snapshot
  let log := tree.getAll.map (·.diagnostics.msgLog) |>.foldl (· ++ ·) ({} : MessageLog)
  log.toArray.filter (!·.isSilent) |>.mapM (·.toString true)

private unsafe def run (setupPath sourcePath displayPath : System.FilePath) : IO UInt32 := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let .ok setupJson := Json.parse (← IO.FS.readFile setupPath)
    | throw <| IO.userError "invalid ModuleSetup JSON"
  let .ok (setup : ModuleSetup) := Lean.fromJson? setupJson
    | throw <| IO.userError "invalid ModuleSetup payload"
  let raw ← IO.FS.readFile sourcePath
  let normalized := raw.crlfToLf
  let input := Parser.mkInputContext raw displayPath.toString
  let options := Elab.async.setIfNotSet setup.options.toOptions true
  let setupImports (header : Elab.HeaderSyntax) := do
    liftM <| setup.dynlibs.forM loadDynlib
    return .ok {
      mainModuleName := setup.name
      package? := setup.package?
      isModule := setup.isModule || header.isModule
      imports := setup.imports?.getD header.imports
      opts := options
      trustLevel := 0
      importArts := setup.importArts
      plugins := setup.plugins }
  let snapshot ← Language.Lean.process setupImports none ({ input with } : Language.ProcessingContext)
  let some finalState := Language.Lean.waitForFinalCmdState? snapshot
    | throw <| IO.userError s!"frontend did not finish:\n{String.intercalate "\n" (← messages snapshot).toList}"
  let (commands, terminal?) := processedLiveCommands snapshot
  let (reparsedHeader, _, headerMessages) ← Parser.parseHeader input
  unless !headerMessages.hasErrors && snapshot.stx.eqWithInfo reparsedHeader.raw do
    throw <| IO.userError "fixed header parser did not reconstruct the frontend header"
  let roots := commands.map (·.stx) ++ terminal?.toArray
  let optionStates := commands.foldl (init := #[]) fun states command =>
    if states.any (· == command.options) then states else states.push command.options
  let optionIndices := commands.map fun command =>
    (optionStates.findIdx? (· == command.options)).getD 0
  let encodeStarted ← IO.monoNanosNow
  let encoded ← IO.lazyPure fun _ => encodeRoots roots
  let wire ← IO.lazyPure fun _ => encoded.json.compress
  let optionsWire ← IO.lazyPure fun _ =>
    (.arr (optionStates.map optionsJson) : Json).compress
  if wire.utf8ByteSize == 0 then
    throw <| IO.userError "codec emitted an empty payload"
  let encodeFinished ← IO.monoNanosNow
  let decodeStarted ← IO.monoNanosNow
  let .ok reparsedJson := Json.parse wire | throw <| IO.userError "codec emitted invalid JSON"
  let decoded ← match decodeRoots normalized reparsedJson with
    | .ok decoded => pure decoded
    | .error error => throw <| IO.userError error
  unless roots.size == decoded.size && (roots.zip decoded).all fun (left, right) =>
      left.eqWithInfo right do
    throw <| IO.userError "syntax round trip changed structure or source info"
  let .ok parsedOptionsJson := Json.parse optionsWire
    | throw <| IO.userError "option codec emitted invalid JSON"
  let optionFields ← match array parsedOptionsJson with
    | .ok fields => pure fields
    | .error error => throw <| IO.userError error
  let decodedOptions ← optionFields.mapM fun json =>
    match decodeOptions normalized json with
    | .ok options => pure options
    | .error error => throw <| IO.userError error
  unless optionStates.size == decodedOptions.size &&
      (optionStates.zip decodedOptions).all fun (left, right) => left == right do
    throw <| IO.userError "option round trip changed an effective command option state"
  let decodeFinished ← IO.monoNanosNow
  let decodedCommands := decoded.extract 0 commands.size
  let mut liveFormatMatches : Nat := 0
  let mut finalEnvironmentMatches : Nat := 0
  let mut formatterRefusals : Nat := 0
  for index in [0:commands.size] do
    let some command := commands[index]?
      | throw <| IO.userError s!"missing live command {index}"
    let decoded := decodedCommands[index]!
    let decodedOptions := decodedOptions[optionIndices[index]!]!
    let original40 ← formatCommand command.env command.options command.stx 40
    let decoded40 ← formatCommand command.env decodedOptions decoded 40
    let original100 ← formatCommand command.env command.options command.stx 100
    let decoded100 ← formatCommand command.env decodedOptions decoded 100
    if original40 matches .error _ then
      formatterRefusals := formatterRefusals + 1
    if sameFormat original40 decoded40 && sameFormat original100 decoded100 then
      liveFormatMatches := liveFormatMatches + 1
    let final40 ← formatCommand finalState.env decodedOptions decoded 40
    let final100 ← formatCommand finalState.env decodedOptions decoded 100
    if sameFormat original40 final40 && sameFormat original100 final100 then
      finalEnvironmentMatches := finalEnvironmentMatches + 1
  let current := ModuleArtifact.ofParsedModule setup.name.toString normalized
    (commands.map (·.stx)) terminal?
  let currentBytes := (Lean.toJson current).compress.utf8ByteSize
  let optionEntries : Nat := commands.foldl (init := 0) fun count command => Id.run do
    let mut next := count
    for _ in command.options do
      next := next + 1
    return next
  let fragmentedSyntaxBytes : Nat := roots.foldl (init := 0) fun bytes root =>
    bytes + (encodeRoots #[root]).json.compress.utf8ByteSize
  let fragmentedOptionsBytes : Nat := commands.foldl (init := 0) fun bytes command =>
    bytes + (optionsJson command.options).compress.utf8ByteSize
  let encodeUs : Nat := (encodeFinished - encodeStarted) / 1000
  let decodeUs : Nat := (decodeFinished - decodeStarted) / 1000
  IO.println <| (Json.mkObj [
    ("path", .str displayPath.toString),
    ("sourceBytes", .num normalized.utf8ByteSize),
    ("commands", .num commands.size),
    ("terminal", .bool terminal?.isSome),
    ("headerMatches", .bool true),
    ("entries", .num encoded.state.entries.size),
    ("nodes", .num encoded.state.nodes),
    ("leaves", .num encoded.state.leaves),
    ("kinds", .num encoded.state.kinds.size),
    ("choices", .num encoded.state.choices),
    ("synthetic", .num encoded.state.synthetic),
    ("missing", .num encoded.state.missing),
    ("preresolved", .num encoded.state.preresolved),
    ("syntaxWireBytes", .num wire.utf8ByteSize),
    ("optionsWireBytes", .num optionsWire.utf8ByteSize),
    ("wireBytes", .num (wire.utf8ByteSize + optionsWire.utf8ByteSize)),
    ("fragmentedSyntaxBytes", .num fragmentedSyntaxBytes),
    ("fragmentedOptionsBytes", .num fragmentedOptionsBytes),
    ("fragmentedWireBytes", .num (fragmentedSyntaxBytes + fragmentedOptionsBytes)),
    ("encodeUs", .num encodeUs),
    ("decodeUs", .num decodeUs),
    ("currentArtifactBytes", .num currentBytes),
    ("liveFormatMatches", .num liveFormatMatches),
    ("finalEnvironmentMatches", .num finalEnvironmentMatches),
    ("formatterRefusals", .num formatterRefusals),
    ("optionStates", .num optionStates.size),
    ("optionEntries", .num optionEntries)]).compress
  return 0

private unsafe def registryProbe (moduleFile : System.FilePath) (loadExtensions : Bool) : IO UInt32 := do
  initSearchPath (← findSysroot)
  if loadExtensions then
    enableInitializersExecution
  let moduleName := `AdapterSyntax
  let (moduleData, region) ← readModuleData moduleFile
  let level := if moduleData.isModule then OLeanLevel.exported else .private
  region.free
  let artifacts : NameMap ImportArtifacts :=
    ({} : NameMap ImportArtifacts).insert moduleName (.ofArrays #[#[moduleFile]])
  let environment ← importModules #[{ module := moduleName }] {}
    (trustLevel := 1024) (loadExts := loadExtensions) (level := level) (arts := artifacts)
  let descriptor := Parser.runParserCategory environment `command
    "descriptor_command descriptorFromOlean := 1"
  let explicit := Parser.runParserCategory environment `command
    "explicit_command explicitFromOlean"
  let descriptorResult ← match descriptor with
    | .ok stx => formatCommand environment {} stx 40
    | .error error => pure (.error error)
  let explicitResult ← match explicit with
    | .ok stx => formatCommand environment {} stx 40
    | .error error => pure (.error error)
  let explicitRegistrations := PrettyPrinter.formatterAttribute.getValues environment
    `AdapterSyntax.explicitCommand |>.length
  let resultString : Except String String → String
    | .ok value => value
    | .error error => s!"error:{error}"
  IO.println <| (Json.mkObj [
    ("module", .str moduleName.toString),
    ("moduleFile", .str moduleFile.toString),
    ("loadExts", .bool loadExtensions),
    ("descriptorKind", .str (match descriptor with | .ok stx => stx.getKind.toString | _ => "")),
    ("explicitKind", .str (match explicit with | .ok stx => stx.getKind.toString | _ => "")),
    ("explicitRegistrations", .num explicitRegistrations),
    ("descriptorOutput", .str (resultString descriptorResult)),
    ("explicitOutput", .str (resultString explicitResult))]).compress
  return 0

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | ["--registry", moduleFile] => registryProbe moduleFile true
  | ["--registry-no-exts", moduleFile] => registryProbe moduleFile false
  | [setup, source, display] => run setup source display
  | _ =>
    IO.eprintln "usage: artifactSyntaxProbe SETUP SOURCE DISPLAY"
    return 2
