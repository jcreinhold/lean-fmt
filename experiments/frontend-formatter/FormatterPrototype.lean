/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import PrototypeSyntax

open Lean

namespace FormatterPrototype

/-! Shape A materializes the complete registered formatter result in an extensible document. The
prototype's richer `line` can carry arbitrary flat text even though Lean's current registry only
produces the ordinary space form. Tags remain typed source boundaries throughout both traversals. -/

private inductive RichDoc where
  | nil
  | line (flat : String)
  | align (force : Bool)
  | text (value : String)
  | nest (indent : Int) (inner : RichDoc)
  | append (left right : RichDoc)
  | group (inner : RichDoc) (behavior : Std.Format.FlattenBehavior)
  | tag (sourceOffset : Nat) (inner : RichDoc)
  deriving Inhabited

private partial def RichDoc.ofFormat : Std.Format → RichDoc
  | .nil => .nil
  | .line => .line " "
  | .align force => .align force
  | .text value => .text value
  | .nest indent inner => .nest indent (ofFormat inner)
  | .append left right => .append (ofFormat left) (ofFormat right)
  | .group inner behavior => .group (ofFormat inner) behavior
  | .tag sourceOffset inner => .tag sourceOffset (ofFormat inner)

private partial def RichDoc.toFormat : RichDoc → Std.Format
  | .nil => .nil
  | .line " " => .line
  | .line flat => .text flat
  | .align force => .align force
  | .text value => .text value
  | .nest indent inner => .nest indent (toFormat inner)
  | .append left right => .append (toFormat left) (toFormat right)
  | .group inner behavior => .group (toFormat inner) behavior
  | .tag sourceOffset inner => .tag sourceOffset (toFormat inner)

private partial def RichDoc.size : RichDoc → Nat
  | .nil | .line _ | .align _ | .text _ => 1
  | .nest _ inner | .group inner _ | .tag _ inner => inner.size + 1
  | .append left right => left.size + right.size + 1

private structure Boundary where
  sourceOffset : Nat
  outputStart : Nat
  outputStop : Nat
  deriving Inhabited

private structure RenderState where
  output : String := ""
  column : Nat := 0
  steps : Nat := 0
  active : List (Nat × Nat) := []
  boundaries : Array Boundary := #[]
  deriving Inhabited

private instance : Std.Format.MonadPrettyFormat (StateM RenderState) where
  pushOutput value := modify fun state => {
    state with
    output := state.output ++ value
    column := state.column + value.length
    steps := state.steps + 1 }
  pushNewline indent := modify fun state => {
    state with
    output := state.output ++ "\n" ++ "".pushn ' ' indent
    column := indent
    steps := state.steps + 1 }
  currColumn := return (← get).column
  startTag sourceOffset := modify fun state => {
    state with
    active := (sourceOffset, state.output.utf8ByteSize) :: state.active
    steps := state.steps + 1 }
  endTags count := modify fun state => Id.run do
    let mut active := state.active
    let mut boundaries := state.boundaries
    for _ in [0:count] do
      if let (sourceOffset, outputStart) :: rest := active then
        boundaries := boundaries.push {
          sourceOffset, outputStart, outputStop := state.output.utf8ByteSize }
        active := rest
    return { state with active, boundaries, steps := state.steps + count }

private def render (format : Std.Format) (width : Nat) : RenderState :=
  (Std.Format.prettyM format width : StateM RenderState Unit).run {} |>.2

private inductive Shape where
  | converted
  | opaque
  deriving BEq

private structure CommandDocument where
  format : Std.Format
  nodes : Nat
  convertedNodes : Nat
  coreOverride : Bool := false
  registryDocument : Bool := false

private def shapeA (format : Std.Format) : CommandDocument :=
  let rich := RichDoc.ofFormat format
  {
    format := rich.toFormat
    nodes := rich.size
    convertedNodes := rich.size
    registryDocument := true }

/-! Shape B leaves registry documents opaque. Its only custom construction is a closed core rule,
which composes the registered formatter for the actual nested term node without reconstructing or
parsing the term's spelling. Its fixed flat separator is intentionally unlike `ppCommand`'s
unconditional declaration-body break. -/

private inductive HybridDoc where
  | custom (document : RichDoc)
  | opaque (registered : Std.Format)
  | append (left right : HybridDoc)
  deriving Inhabited

private partial def HybridDoc.toFormat : HybridDoc → Std.Format
  | .custom document => document.toFormat
  | .opaque registered => registered
  | .append left right => left.toFormat ++ right.toFormat

private partial def HybridDoc.size : HybridDoc → Nat
  | .custom document => document.size + 1
  | .opaque _ => 1
  | .append left right => left.size + right.size + 1

private def shapeB (stx : Syntax) : CoreM CommandDocument := do
  match stx with
  | `(command| def $name:ident := $value:term) =>
    let valueFormat ← PrettyPrinter.ppTerm value
    let nameText := name.getId.toString
    let document := HybridDoc.append
      (.custom (.text s!"def {nameText} := "))
      (.opaque valueFormat)
    return {
      format := document.toFormat
      nodes := document.size
      convertedNodes := 0
      coreOverride := true }
  | _ =>
    let format ← PrettyPrinter.ppCommand ⟨stx⟩
    let document := HybridDoc.opaque format
    return {
      format := document.toFormat
      nodes := document.size
      convertedNodes := 0
      registryDocument := true }

private partial def collectCommands
    (snapshot : Language.Lean.CommandParsedSnapshot)
    (commands : Array Language.Lean.CommandParsedSnapshot := #[]) :
    Array Language.Lean.CommandParsedSnapshot :=
  let commands := commands.push snapshot
  match snapshot.nextCmdSnap? with
  | some next => collectCommands next.get commands
  | none => commands

private def commandSnapshots (snapshot : Language.Lean.InitialSnapshot) :
    Array Language.Lean.CommandParsedSnapshot :=
  match snapshot.result? with
  | none => #[]
  | some parsed =>
    match parsed.processedSnap.get.result? with
    | none => #[]
    | some processed => collectCommands processed.firstCmdSnap.get

private def setupImports (mainModuleName : Name) (header : Elab.HeaderSyntax) :
    Language.ProcessingT IO
      (Except Language.Lean.HeaderProcessedSnapshot Language.Lean.SetupImportsResult) := do
  return Except.ok {
    mainModuleName
    isModule := header.isModule
    imports := header.imports
    opts := ({} : Options)
    trustLevel := 0
    plugins := #[] }

private unsafe def processSource (mainModuleName : Name) (source : String) :
    IO Language.Lean.InitialSnapshot := do
  let input := Parser.mkInputContext source "FormatterPrototypeInput.lean"
  let context : Language.ProcessingContext := { input with }
  let snapshot ← Language.Lean.process (setupImports mainModuleName) none context
  let some _ := Language.Lean.waitForFinalCmdState? snapshot
    | let tree := Language.toSnapshotTree snapshot
      let messages := tree.getAll.map (·.diagnostics.msgLog) |>.foldl
        (init := ({} : MessageLog)) (· ++ ·)
      let rendered ← messages.toArray.mapM (·.toString true)
      throw <| IO.userError s!"frontend rejected input:\n{String.intercalate "\n" rendered.toList}"
  return snapshot

private structure Metrics where
  commands : Nat := 0
  changedCommands : Nat := 0
  commentOwnedCommands : Nat := 0
  commentAdjacentCommands : Nat := 0
  headerAdjacentCommands : Nat := 0
  coreOverrides : Nat := 0
  registryDocuments : Nat := 0
  documentNodes : Nat := 0
  convertedNodes : Nat := 0
  renderSteps : Nat := 0
  tagBoundaries : Nat := 0
  formatterFailures : Nat := 0
  failureKinds : Array String := #[]
  deriving Inhabited

private def triviaHasComment : Substring.Raw → Bool := fun trivia =>
  let value := trivia.toString
  value.contains "--" || value.contains "/-"

private def infoHasComment : SourceInfo → Bool
  | .original leading _ trailing _ => triviaHasComment leading || triviaHasComment trailing
  | _ => false

private partial def syntaxHasOwnedComment : Syntax → Bool
  | .missing => false
  | .node info _ args => infoHasComment info || args.any syntaxHasOwnedComment
  | .atom info value => infoHasComment info || value.startsWith "/--"
  | .ident info _ _ _ => infoHasComment info

private def commandDocument (shape : Shape) (env : Environment) (options : Options)
    (stx : Syntax) : IO CommandDocument :=
  Core.CoreM.toIO'
    (match shape with
      | .converted => shapeA <$> PrettyPrinter.ppCommand ⟨stx⟩
      | .opaque => shapeB stx)
    { fileName := "FormatterPrototypeInput.lean", fileMap := default, options }
    { env }

private unsafe def formatSource (shape : Shape) (width : Nat) (mainModuleName : Name)
    (source : String) : IO (String × Metrics) := do
  let snapshot ← processSource mainModuleName source
  let some finalState := Language.Lean.waitForFinalCmdState? snapshot
    | throw <| IO.userError "frontend produced no final command state"
  let options := finalState.scopes.head!.opts
  let mut output := ""
  let mut cursor : String.Pos.Raw := 0
  let mut metrics : Metrics := {}
  let mut preserveNext := false
  let mut firstCommand := true
  for command in commandSnapshots snapshot do
    let stx := command.stx
    if Parser.isTerminalCommand stx then
      output := output ++ String.Pos.Raw.extract source cursor source.rawEndPos
      cursor := source.rawEndPos
      break
    let some start := stx.getPos? | continue
    let some stop := stx.getTailPos? | continue
    let trailingStop := stx.getTrailingTailPos?.getD stop
    if start < cursor || source.rawEndPos < trailingStop then
      throw <| IO.userError "command source ranges are not ordered"
    output := output ++ String.Pos.Raw.extract source cursor start
    let original := String.Pos.Raw.extract source start stop
    let originalWithTrivia := String.Pos.Raw.extract source start trailingStop
    let ownsComment := syntaxHasOwnedComment stx
    metrics := { metrics with commands := metrics.commands + 1 }
    if ownsComment || preserveNext || firstCommand then
      output := output ++ originalWithTrivia
      metrics := {
        metrics with
        commentOwnedCommands := metrics.commentOwnedCommands + if ownsComment then 1 else 0
        commentAdjacentCommands := metrics.commentAdjacentCommands +
          if preserveNext && !ownsComment then 1 else 0
        headerAdjacentCommands := metrics.headerAdjacentCommands + if firstCommand then 1 else 0 }
      cursor := trailingStop
    else
      try
        let document ← commandDocument shape finalState.env options stx
        let rendered := render document.format width
        output := output ++ rendered.output
        metrics := {
          metrics with
          changedCommands := metrics.changedCommands + if rendered.output == original then 0 else 1
          coreOverrides := metrics.coreOverrides + if document.coreOverride then 1 else 0
          registryDocuments := metrics.registryDocuments + if document.registryDocument then 1 else 0
          documentNodes := metrics.documentNodes + document.nodes
          convertedNodes := metrics.convertedNodes + document.convertedNodes
          renderSteps := metrics.renderSteps + rendered.steps
          tagBoundaries := metrics.tagBoundaries + rendered.boundaries.size }
      catch _ =>
        output := output ++ original
        metrics := {
          metrics with
          formatterFailures := metrics.formatterFailures + 1
          failureKinds := metrics.failureKinds.push stx.getKind.toString }
      cursor := stop
    preserveNext := ownsComment
    firstCommand := false
  if cursor < source.rawEndPos then
    output := output ++ String.Pos.Raw.extract source cursor source.rawEndPos
  return (output, metrics)

private def metricsJson (metrics : Metrics) : Json := Json.mkObj [
  ("commands", metrics.commands),
  ("changedCommands", metrics.changedCommands),
  ("commentOwnedCommands", metrics.commentOwnedCommands),
  ("commentAdjacentCommands", metrics.commentAdjacentCommands),
  ("headerAdjacentCommands", metrics.headerAdjacentCommands),
  ("coreOverrides", metrics.coreOverrides),
  ("registryDocuments", metrics.registryDocuments),
  ("documentNodes", metrics.documentNodes),
  ("convertedNodes", metrics.convertedNodes),
  ("renderSteps", metrics.renderSteps),
  ("tagBoundaries", metrics.tagBoundaries),
  ("formatterFailures", metrics.formatterFailures),
  ("failureKinds", Json.arr <| metrics.failureKinds.map Json.str),
  ("allocationsAvailable", false)
]

private def parseShape : String → Option Shape
  | "converted" => some .converted
  | "opaque" => some .opaque
  | _ => none

unsafe def run (shapeName widthText moduleName : String) : IO UInt32 := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let some shape := parseShape shapeName
    | throw <| IO.userError "shape must be `converted` or `opaque`"
  let some width := widthText.toNat?
    | throw <| IO.userError "width must be a natural number"
  let source ← (← IO.getStdin).readToEnd
  let (formatted, metrics) ← formatSource shape width moduleName.toName source
  let sourceDigest := (← IO.getEnv "LEAN_FMT_EXPECTED_SOURCE_DIGEST").getD ""
  let setupDigest := (← IO.getEnv "LEAN_FMT_EXPECTED_SETUP_DIGEST").getD ""
  let sourceBytes := source.utf8ByteSize
  let outputBytes := formatted.utf8ByteSize
  IO.println <| (Json.mkObj [
    ("formatted", formatted),
    ("sourceMap", Json.arr #[Json.mkObj [
      ("source", Json.mkObj [("start", 0), ("stop", sourceBytes)]),
      ("output", Json.mkObj [("start", 0), ("stop", outputBytes)])]]),
    ("sourceDigest", sourceDigest),
    ("setupDigest", setupDigest),
    ("cancelled", false),
    ("unsupported", Json.arr #[]),
    ("metrics", metricsJson metrics)
  ]).compress
  return 0

end FormatterPrototype

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | [shape, width] => FormatterPrototype.run shape width "FormatterPrototype.Input"
  | [shape, width, moduleName] => FormatterPrototype.run shape width moduleName
  | _ =>
    IO.eprintln "usage: frontend-formatter (converted|opaque) WIDTH [MODULE]"
    return 2
