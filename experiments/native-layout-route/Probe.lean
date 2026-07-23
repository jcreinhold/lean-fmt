/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- The selected route probe, not production formatter code.

Lean's registered command formatter runs on the actual syntax. The public `Std.Format` tree is
rewritten directly: non-comment text leaves are aligned in order with source-covering terminals and
replaced with their original spelling. The losing eager-lowering prototype was deleted after it
produced identical output while allocating one additional node per native node. The independent
formatter oracle reparses both passes and checks token, comment-owner, structural, import, map, and
idempotence equality. -/

import Lean.PrettyPrinter
import all LeanFmt.Formatter

open Lean
open LeanFmt.Internal

namespace NativeLayoutRoute

private structure Terminal where
  syntaxSpelling : String
  sourceSpelling : String
  range : SourceRange
  deriving Inhabited

private structure Protection where
  tag : Nat
  range : SourceRange
  text : String
  tokenStart : Nat := 0
  tokenStop : Nat := 0
  indentAdjustment : Int := 0
  deriving Inhabited

private def slice (source : String) (range : SourceRange) : String :=
  (String.fromUTF8? (source.toUTF8.extract range.start range.stop)).getD ""

private def sourceRange? (stx : Syntax) : Option SourceRange := do
  let range ← stx.getRange?
  return ⟨range.start.byteIdx, range.stop.byteIdx⟩

private def isDocComment (value : String) : Bool :=
  value.startsWith "/--" || value.startsWith "/-!"

private partial def containsKind (kind : Name) (stx : Syntax) : Bool :=
  stx.isOfKind kind || match stx with
    | .node _ _ children => children.any (containsKind kind)
    | _ => false

private partial def containsPseudoAntiquot : Syntax → Bool
  | .node _ kind children =>
    kind.toString.contains ".pseudo.antiquot" || children.any containsPseudoAntiquot
  | _ => false

private def leadingSpaces (value : String) : Nat :=
  value.toList.takeWhile (· == ' ') |>.length

private def rebaseIsland (value : String) : String :=
  match value.splitOn "\n" with
  | [] => value
  | first :: rest =>
    let nonempty := rest.filter (!·.trimAscii.isEmpty)
    let indent := nonempty.foldl (init := none) fun current line =>
      let spaces := leadingSpaces line
      some <| current.map (min · spaces) |>.getD spaces
    let indent := indent.getD 0
    String.intercalate "\n" <| first :: rest.map (·.drop indent |>.copy)

private partial def protectUnsafeSequences (source : String) (stx : Syntax) :
    Syntax × Array Protection :=
  match stx with
  | .node info kind children =>
    if kind == ``Lean.Parser.Term.byTactic then
      match sourceRange? stx with
      | some range =>
        let tag := source.utf8ByteSize + range.start + 1
        let text := rebaseIsland (slice source range)
        (.node info kind children, #[{ tag, range, text }])
      | none => (stx, #[])
    else if kind == ``Lean.Parser.Term.doSeqIndent &&
        containsKind ``Lean.Parser.Term.doLetElse stx then
      match sourceRange? stx with
      | some range =>
        let tag := source.utf8ByteSize + range.start + 1
        let text := rebaseIsland (slice source range)
        (.node info kind children, #[{ tag, range, text, indentAdjustment := -2 }])
      | none => (stx, #[])
    else
      let (children, protections) := children.foldl (init := (#[], #[]))
        fun (rewritten, protections) child =>
          let (child, nested) := protectUnsafeSequences source child
          (rewritten.push child, protections ++ nested)
      (.node info kind children, protections)
  | _ => (stx, #[])

private partial def terminalsFrom (source : String) (stx : Syntax)
    (result : Array Terminal := #[]) : Array Terminal :=
  match stx with
  | .missing => result
  | .atom _ syntaxSpelling =>
    match sourceRange? stx with
    | some range =>
      let sourceSpelling := slice source range
      if sourceSpelling.isEmpty || isDocComment sourceSpelling then result
      else result.push { syntaxSpelling, sourceSpelling, range }
    | none => result
  | .ident _ raw _ _ =>
    match sourceRange? stx with
    | some range =>
      let sourceSpelling := slice source range
      if sourceSpelling.isEmpty then result
      else result.push { syntaxSpelling := raw.toString, sourceSpelling, range }
    | none => result
  | .node _ kind children =>
    if kind == choiceKind then
      match children[0]? with
      | some selected => terminalsFrom source selected result
      | none => result
    else children.foldl (init := result) fun tokens child => terminalsFrom source child tokens

private def commentText (value : String) : Bool :=
  let trimmed := value.trimAscii.copy
  trimmed.startsWith "--" || trimmed.startsWith "/-"

private structure TokenSpan where
  start : Nat
  stop : Nat
  deriving Inhabited, BEq

private structure ProtectedFormat where
  format : Std.Format
  span? : Option TokenSpan := none
  deriving Inhabited

private structure ProtectState where
  tokenIndex : Nat := 0
  applied : Array Nat := #[]

private def mergeSpan : Option TokenSpan → Option TokenSpan → Option TokenSpan
  | none, right => right
  | left, none => left
  | some left, some right => some ⟨min left.start right.start, max left.stop right.stop⟩

private def finishProtection (protections : Array Protection) (result : ProtectedFormat) :
    StateM ProtectState ProtectedFormat := do
  let state ← get
  match result.span?.bind fun span => protections.find? fun protection =>
      protection.tokenStart == span.start && protection.tokenStop == span.stop &&
        !state.applied.contains protection.tag with
  | some protection =>
    set { state with applied := state.applied.push protection.tag }
    return { result with format := .tag protection.tag (.text protection.text) }
  | none => return result

private partial def protectFormat (protections : Array Protection) : Std.Format →
    StateM ProtectState ProtectedFormat
  | .nil => finishProtection protections { format := .nil }
  | .line => finishProtection protections { format := .line }
  | .align force => finishProtection protections { format := .align force }
  | .text value => do
    if value.trimAscii.isEmpty || commentText value then
      finishProtection protections { format := .text value }
    else
      let state ← get
      set { state with tokenIndex := state.tokenIndex + 1 }
      finishProtection protections {
        format := .text value
        span? := some ⟨state.tokenIndex, state.tokenIndex + 1⟩ }
  | .nest indent inner => do
    let inner ← protectFormat protections inner
    finishProtection protections { inner with format := .nest indent inner.format }
  | .append left right => do
    let left ← protectFormat protections left
    let right ← protectFormat protections right
    finishProtection protections {
      format := .append left.format right.format
      span? := mergeSpan left.span? right.span? }
  | .group inner behavior => do
    let inner ← protectFormat protections inner
    finishProtection protections { inner with format := .group inner.format behavior }
  | .tag value inner => do
    let inner ← protectFormat protections inner
    finishProtection protections { inner with format := .tag value inner.format }

private structure RewriteState where
  terminals : Array Terminal
  protections : Array Protection
  terminalIndex : Nat := 0
  nativeNodes : Nat := 0
  tokenLeaves : Nat := 0
  commentLeaves : Nat := 0
  normalizedTokens : Nat := 0
  exactIslands : Nat := 0
  exactIslandBytes : Nat := 0
  deriving Inhabited

private def replacePayload (value payload : String) : String :=
  let trimmed := value.trimAscii.copy
  if trimmed.isEmpty then value else value.replace trimmed payload

private def rewriteText (value : String) : StateT RewriteState (Except String) String := do
  modify fun state => { state with nativeNodes := state.nativeNodes + 1 }
  if value.trimAscii.isEmpty then return value
  if commentText value then
    modify fun state => { state with commentLeaves := state.commentLeaves + 1 }
    return value
  let state ← get
  let some terminal := state.terminals[state.terminalIndex]?
    | throw s!"native formatter emitted extra text leaf {repr value} after {state.terminalIndex} terminals"
  let nativePayload := value.trimAscii.copy
  let normalized := nativePayload != terminal.syntaxSpelling &&
    nativePayload != terminal.sourceSpelling
  set { state with
    terminalIndex := state.terminalIndex + 1
    tokenLeaves := state.tokenLeaves + 1
    normalizedTokens := state.normalizedTokens + if normalized then 1 else 0 }
  return replacePayload value terminal.sourceSpelling

private partial def rewriteNative : Std.Format → StateT RewriteState (Except String) Std.Format
  | .nil => do
    modify fun state => { state with nativeNodes := state.nativeNodes + 1 }
    return .nil
  | .line => do
    modify fun state => { state with nativeNodes := state.nativeNodes + 1 }
    return .line
  | .align force => do
    modify fun state => { state with nativeNodes := state.nativeNodes + 1 }
    return .align force
  | .text value => return .text (← rewriteText value)
  | .nest indent inner => do
    modify fun state => { state with nativeNodes := state.nativeNodes + 1 }
    return .nest indent (← rewriteNative inner)
  | .append left right => do
    modify fun state => { state with nativeNodes := state.nativeNodes + 1 }
    return .append (← rewriteNative left) (← rewriteNative right)
  | .group inner behavior => do
    modify fun state => { state with nativeNodes := state.nativeNodes + 1 }
    return .group (← rewriteNative inner) behavior
  | .tag tag inner => do
    let state ← get
    match state.protections.find? (·.tag == tag) with
    | some protection =>
      let mut terminalIndex := state.terminalIndex
      while terminalIndex < state.terminals.size &&
          state.terminals[terminalIndex]!.range.start < protection.range.stop do
        unless protection.range.start <= state.terminals[terminalIndex]!.range.start &&
            state.terminals[terminalIndex]!.range.stop <= protection.range.stop do
          throw "protected offside island does not cover complete terminals"
        terminalIndex := terminalIndex + 1
      set { state with
        terminalIndex
        nativeNodes := state.nativeNodes + 1
        exactIslands := state.exactIslands + 1
        exactIslandBytes := state.exactIslandBytes + protection.text.utf8ByteSize }
      return .tag tag (.nest protection.indentAdjustment (.text protection.text))
    | none =>
      modify fun state => { state with nativeNodes := state.nativeNodes + 1 }
      return .tag tag (← rewriteNative inner)

private structure RenderState where
  output : String := ""
  column : Nat := 0
  events : Nat := 0
  deriving Inhabited

private instance : Std.Format.MonadPrettyFormat (StateM RenderState) where
  pushOutput value := modify fun state =>
    let column := if value.contains '\n' then
        (value.splitOn "\n").getLast?.map (·.length) |>.getD 0
      else state.column + value.length
    { state with
      output := state.output ++ value
      column
      events := state.events + 1 }
  pushNewline indent := modify fun state =>
    { state with
      output := state.output ++ "\n" ++ "".pushn ' ' indent
      column := indent
      events := state.events + 1 }
  currColumn := return (← get).column
  startTag _ := modify fun state => { state with events := state.events + 1 }
  endTags count := modify fun state => { state with events := state.events + count }

private def render (format : Std.Format) (width : Nat) : RenderState :=
  (Std.Format.prettyM format width : StateM RenderState Unit).run {} |>.2

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
  let input := Parser.mkInputContext source "NativeLayoutRouteInput.lean"
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
  nativeNodes : Nat := 0
  tokenLeaves : Nat := 0
  commentLeaves : Nat := 0
  normalizedTokens : Nat := 0
  exactIslands : Nat := 0
  exactIslandBytes : Nat := 0
  renderEvents : Nat := 0
  alignmentFailures : Nat := 0
  failureKinds : Array String := #[]
  deriving Inhabited

private def rewrite (terminals : Array Terminal) (protections : Array Protection)
    (native : Std.Format) :
    Except String (Std.Format × RewriteState) := do
  let initial : RewriteState := { terminals, protections }
  let prepared := (protectFormat protections native).run {} |>.1
  let (format, state) ← (rewriteNative prepared.format).run initial
  if state.terminalIndex != terminals.size then
    throw s!"native formatter consumed {state.terminalIndex}/{terminals.size} terminals"
  return (format, state)

private def commandFormat (env : Environment) (options : Options)
    (source : String) (stx : Syntax) : IO (Except String (Std.Format × RewriteState)) := do
  let stripped := Formatter.withoutBoundaryTrivia stx
  let terminals := terminalsFrom source stripped
  let (tagged, protections) := protectUnsafeSequences source stripped
  let protections := protections.map fun protection =>
    let tokenStart := terminals.findIdx? (protection.range.start <= ·.range.start) |>.getD terminals.size
    let tokenStop := terminals.findIdx? (protection.range.stop <= ·.range.start) |>.getD terminals.size
    { protection with tokenStart, tokenStop }
  if containsPseudoAntiquot stripped || terminals.any (·.sourceSpelling.contains '\n') then
    let range := sourceRange? stripped |>.getD ⟨0, 0⟩
    let exact := slice source range
    return .ok (.text exact, {
      terminals
      protections := #[]
      terminalIndex := terminals.size
      exactIslands := 1
      exactIslandBytes := exact.utf8ByteSize })
  let nativeResult : Except String Std.Format ← Core.CoreM.toIO'
    (try
      return Except.ok (← PrettyPrinter.formatCommand tagged)
    catch exception =>
      return Except.error (← exception.toMessageData.toString))
    { fileName := "NativeLayoutRouteInput.lean", fileMap := FileMap.ofString source, options }
    { env }
  return nativeResult.bind (rewrite terminals protections)

private unsafe def formatSource (width : Nat) (mainModuleName : Name)
    (source : String) : IO (String × Metrics) := do
  let snapshot ← processSource mainModuleName source
  let some finalState := Language.Lean.waitForFinalCmdState? snapshot
    | throw <| IO.userError "frontend produced no final command state"
  let options := finalState.scopes.head!.opts
  let mut output := ""
  let mut cursor : String.Pos.Raw := 0
  let mut metrics : Metrics := {}
  let mut emittedCommand := false
  for command in commandSnapshots snapshot do
    let stx := command.stx
    if Parser.isTerminalCommand stx then
      output := output ++ String.Pos.Raw.extract source cursor source.rawEndPos
      cursor := source.rawEndPos
      break
    let some start := stx.getPos? | continue
    let some stop := stx.getTailPos? | continue
    if start < cursor || source.rawEndPos < stop then
      throw <| IO.userError "command source ranges are not ordered"
    let boundary := String.Pos.Raw.extract source cursor start
    if emittedCommand && boundary.trimAscii.isEmpty then
      output := output.trimAsciiEnd.copy ++ "\n\n"
    else
      output := output ++ boundary
    let original := String.Pos.Raw.extract source start stop
    metrics := { metrics with commands := metrics.commands + 1 }
    match ← commandFormat finalState.env options source stx with
    | .error detail =>
      metrics := { metrics with
        alignmentFailures := metrics.alignmentFailures + 1
        failureKinds := metrics.failureKinds.push s!"{stx.getKind}: {detail}" }
      output := output ++ original
    | .ok (format, rewriteMetrics) =>
      let rendered := render format width
      output := output ++ rendered.output
      metrics := { metrics with
        changedCommands := metrics.changedCommands + if rendered.output == original then 0 else 1
        nativeNodes := metrics.nativeNodes + rewriteMetrics.nativeNodes
        tokenLeaves := metrics.tokenLeaves + rewriteMetrics.tokenLeaves
        commentLeaves := metrics.commentLeaves + rewriteMetrics.commentLeaves
        normalizedTokens := metrics.normalizedTokens + rewriteMetrics.normalizedTokens
        exactIslands := metrics.exactIslands + rewriteMetrics.exactIslands
        exactIslandBytes := metrics.exactIslandBytes + rewriteMetrics.exactIslandBytes
        renderEvents := metrics.renderEvents + rendered.events }
    cursor := stop
    emittedCommand := true
  if cursor < source.rawEndPos then
    let tail := String.Pos.Raw.extract source cursor source.rawEndPos
    if tail.trimAscii.isEmpty then
      output := output.trimAsciiEnd.copy ++ if source.endsWith "\n" then "\n" else ""
    else
      output := output ++ tail
  return (output, metrics)

private def metricsJson (metrics : Metrics) : Json := Json.mkObj [
  ("commands", metrics.commands),
  ("changedCommands", metrics.changedCommands),
  ("nativeNodes", metrics.nativeNodes),
  ("tokenLeaves", metrics.tokenLeaves),
  ("commentLeaves", metrics.commentLeaves),
  ("normalizedTokens", metrics.normalizedTokens),
  ("exactIslands", metrics.exactIslands),
  ("exactIslandBytes", metrics.exactIslandBytes),
  ("renderEvents", metrics.renderEvents),
  ("alignmentFailures", metrics.alignmentFailures),
  ("failureKinds", Json.arr <| metrics.failureKinds.map Json.str)
]

unsafe def run (widthText moduleName : String) : IO UInt32 := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let some width := widthText.toNat?
    | throw <| IO.userError "width must be a natural number"
  let source ← (← IO.getStdin).readToEnd
  let (formatted, metrics) ← formatSource width moduleName.toName source
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
    ("unsupported", if metrics.alignmentFailures == 0 then Json.arr #[] else
      Json.arr <| metrics.failureKinds.map Json.str),
    ("metrics", metricsJson metrics)
  ]).compress
  return 0

end NativeLayoutRoute

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | [width] => NativeLayoutRoute.run width "NativeLayoutRoute.Input"
  | [width, moduleName] => NativeLayoutRoute.run width moduleName
  | _ =>
    IO.eprintln "usage: Probe.lean WIDTH [MODULE]"
    return 2
