/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import AuditSyntax

open Lean

namespace FrontendNativeAudit

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

private def setupImports (header : Elab.HeaderSyntax) :
    Language.ProcessingT IO
      (Except Language.Lean.HeaderProcessedSnapshot Language.Lean.SetupImportsResult) := do
  return Except.ok {
    mainModuleName := `FrontendNativeAudit.Target
    isModule := header.isModule
    imports := header.imports
    opts := ({} : Options)
    trustLevel := 0
    plugins := #[]
  }

private unsafe def processSource (source : String)
    (old? : Option Language.Lean.InitialSnapshot := none) : IO Language.Lean.InitialSnapshot := do
  enableInitializersExecution
  let input := Parser.mkInputContext source "FrontendNativeAuditTarget.lean"
  let context : Language.ProcessingContext := { input with }
  let snapshot ← Language.Lean.process setupImports old? context
  let some _ := Language.Lean.waitForFinalCmdState? snapshot
    | let tree := Language.toSnapshotTree snapshot
      let messages := tree.getAll.map (·.diagnostics.msgLog) |>.foldl
        (init := ({} : MessageLog)) (· ++ ·)
      let rendered ← messages.toArray.mapM (·.toString true)
      throw <| IO.userError s!"frontend did not produce a final command state:\n{String.intercalate "\n" rendered.toList}"
  return snapshot

private def commandFormat (env : Environment) (options : Options) (stx : Syntax) : IO Std.Format :=
  Core.CoreM.toIO' (PrettyPrinter.ppCommand ⟨stx⟩)
    { fileName := "FrontendNativeAuditTarget.lean", fileMap := default, options }
    { env }

private def formatCommand (env : Environment) (options : Options) (width : Nat)
    (stx : Syntax) : IO String := do
  let fmt ← commandFormat env options stx
  return fmt.pretty width

private structure FormatStats where
  nodes : Nat := 0
  tags : Array Nat := #[]
  deriving Inhabited

private partial def formatStats : Std.Format → FormatStats
  | .nil | .line | .align _ | .text _ => { nodes := 1 }
  | .nest _ inner | .group inner _ =>
    let stats := formatStats inner
    { stats with nodes := stats.nodes + 1 }
  | .append left right =>
    let leftStats := formatStats left
    let rightStats := formatStats right
    { nodes := leftStats.nodes + rightStats.nodes + 1, tags := leftStats.tags ++ rightStats.tags }
  | .tag tag inner =>
    let stats := formatStats inner
    { nodes := stats.nodes + 1, tags := stats.tags.push tag }

private partial def containsKind (kind : Name) : Syntax → Bool
  | .node _ k args => k == kind || args.any (containsKind kind)
  | _ => false

private def renderProbe : String :=
  r#"module

import AuditSyntax

namespace AuditTarget

/-- doc payload: keep  two spaces -/
audit_command custom := audit_term(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)

explicit_command

def notationProbe := 1 <+> 2 <+> 3 <+> 4 <+> 5 <+> 6

def tacticProbe : True := by
  -- leading tactic payload
  audit_exact True.intro -- trailing tactic payload

def commentProbe := [1, /- dangling /* nested */ payload -/ 2, 3]

def widthProbe := List.map (fun value => value + 1)
  [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]

#exit
verbatim tail that is deliberately not parsed
"#

private unsafe def runRenderProbe : IO Unit := do
  let snapshot ← processSource renderProbe
  let some commandState := Language.Lean.waitForFinalCmdState? snapshot
    | throw <| IO.userError "render probe has no command state"
  let commands := commandSnapshots snapshot
  IO.println s!"render.commands={commands.size}"
  let some terminalCommand := commands.toList.getLast?
    | throw <| IO.userError "render probe has no commands"
  IO.println s!"render.terminal={terminalCommand.stx.getKind}"
  IO.println s!"render.kinds={commands.toList.map (·.stx.getKind)}"
  IO.println s!"registry.explicit={
    PrettyPrinter.formatterAttribute.getValues commandState.env `AuditTarget.explicitCommand |>.length}"
  let requested := #[
    (`AuditTarget.auditCommand, "custom-command"),
    (`AuditTarget.auditTerm, "custom-term"),
    (`AuditTarget.auditTactic, "custom-tactic"),
    (`AuditTarget.explicitCommand, "explicit-command")
  ]
  for (kind, label) in requested do
    let count := commands.foldl (init := 0) fun n command =>
      if containsKind kind command.stx then n + 1 else n
    IO.println s!"coverage.{label}={count}"
  let mut renderedCommands := ""
  for command in commands do
    unless Parser.isTerminalCommand command.stx do
      IO.println s!"source.kind={command.stx.getKind} reprint={command.stx.reprint.getD "<none>"}"
      try
        renderedCommands := renderedCommands ++ "\n" ++
          (← formatCommand commandState.env commandState.scopes.head!.opts 80 command.stx)
      catch exception =>
        IO.println s!"format.error.kind={command.stx.getKind} detail={exception}"
  let commentPayloads := #[
    ("doc", "doc payload: keep  two spaces"),
    ("leading-tactic", "leading tactic payload"),
    ("trailing-tactic", "trailing tactic payload"),
    ("nested-block", "dangling /* nested */ payload")
  ]
  for (label, payload) in commentPayloads do
    IO.println s!"comments.{label}={renderedCommands.contains payload}"
  for command in commands do
    unless Parser.isTerminalCommand command.stx do
      let kind := command.stx.getKind
      if requested.any (fun pair => containsKind pair.1 command.stx) ||
          kind == ``Parser.Command.declaration then
        if containsKind `AuditTarget.auditCommand command.stx then
          let stats := formatStats (← commandFormat commandState.env
            commandState.scopes.head!.opts command.stx)
          IO.println s!"format.nodes={stats.nodes} format.tags={stats.tags.toList}"
        IO.println s!"--- kind={kind} width=40"
        IO.println (← formatCommand commandState.env commandState.scopes.head!.opts 40 command.stx)
        IO.println s!"--- kind={kind} width=80"
        IO.println (← formatCommand commandState.env commandState.scopes.head!.opts 80 command.stx)
        IO.println s!"--- kind={kind} width=100"
        IO.println (← formatCommand commandState.env commandState.scopes.head!.opts 100 command.stx)
  let terminal := terminalCommand.stx
  IO.println s!"terminal.reprint={terminal.reprint.getD "<none>"}"

private def incrementalBase : String :=
  r#"module

import AuditSyntax

def first := 1
def second := first + 1
set_option pp.universes false in
def optionProbe := second + 1
def middle := optionProbe + 1
def last := middle + 1
-- trailing payload
"#

private structure EditCase where
  name : String
  source : String

private unsafe def reuseVector (old new : Language.Lean.InitialSnapshot) : Array Bool :=
  let oldCommands := commandSnapshots old
  let newCommands := commandSnapshots new
  (oldCommands.toList.zip newCommands.toList).toArray.map fun pair =>
    ptrEq pair.1.elabSnap.resultSnap.task pair.2.elabSnap.resultSnap.task

private unsafe def runIncrementalProbe : IO Unit := do
  let original ← processSource incrementalBase
  let cases : Array EditCase := #[
    { name := "prefix", source := incrementalBase.replace "def first := 1" "def first := 10" },
    { name := "middle", source := incrementalBase.replace
        "def middle := optionProbe + 1" "def middle := optionProbe + 10" },
    { name := "header-comment", source := "-- changed header trivia\n" ++ incrementalBase },
    { name := "import", source := incrementalBase.replace "import Lean" "import Lean\nimport Std" },
    { name := "option", source := incrementalBase.replace
        "set_option pp.universes false in" "set_option pp.universes true in" },
    { name := "trailing-comment", source := incrementalBase.replace
        "-- trailing payload" "-- trailing payload changed" }
  ]
  for edit in cases do
    let updated ← processSource edit.source (some original)
    let vector := reuseVector original updated
    IO.println s!"reuse.{edit.name}={vector.toList}"

unsafe def run : IO Unit := do
  initSearchPath (← findSysroot)
  runRenderProbe
  runIncrementalProbe

end FrontendNativeAudit

public unsafe def main : IO Unit := FrontendNativeAudit.run
