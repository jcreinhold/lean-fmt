/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Attribution probe for the six pinned layout defects, not production formatter code.

Each of D1-D6 is either a shape Lean's own registered formatter produces -- in which case repairing it
means adding a mechanism to the adapter -- or a shape the adapter introduces on top of a correct
native document. `tests/native-layout/run.sh` §7 pins the *adapter's* output and cannot tell those two
apart, so this prints the native document with nothing between it and `Std.Format.pretty`.

Two renderings per command:

  native   `PrettyPrinter.formatCommand` on the trivia-stripped syntax, pretty-printed directly. This
           is what the adapter starts from. Comments are absent because trivia is stripped, which is
           exactly why D1, D3, and D6 cannot be read off it.
  struct   the same `Std.Format` as a tree, so a `line` can be told from a `text " "` and a group
           boundary is visible. D5 is a question about which of those `:=` is followed by.

Run it through `run.sh`, which supplies the toolchain and reads a source on stdin. -/

import Lean.PrettyPrinter
import all LeanFmt.Formatter

open Lean
open LeanFmt.Internal

namespace NativeLayoutDefects

private partial def collectCommands (snap : Language.Lean.CommandParsedSnapshot)
    (result : Array Language.Lean.CommandParsedSnapshot := #[]) :
    Array Language.Lean.CommandParsedSnapshot :=
  let result := result.push snap
  match snap.nextCmdSnap? with
  | some next => collectCommands next.get result
  | none => result

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
  let input := Parser.mkInputContext source "NativeLayoutDefectsInput.lean"
  let context : Language.ProcessingContext := { input with }
  let snapshot ← Language.Lean.process (setupImports mainModuleName) none context
  let some _ := Language.Lean.waitForFinalCmdState? snapshot
    | let tree := Language.toSnapshotTree snapshot
      let messages := tree.getAll.map (·.diagnostics.msgLog) |>.foldl
        (init := ({} : MessageLog)) (· ++ ·)
      let rendered ← messages.toArray.mapM (·.toString true)
      throw <| IO.userError s!"frontend rejected input:\n{String.intercalate "\n" rendered.toList}"
  return snapshot

/- `Std.Format` has no `Repr` that distinguishes a soft `line` from the space it usually renders as,
which is the one distinction D5 turns on. This walks the constructors by hand. `Format.text " "` and
`Format.line` print identically at any width that fits and differently at any width that does not, so
naming them apart is the whole point of the dump. -/
private partial def structure? : Std.Format → String
  | .nil => "nil"
  | .line => "line"
  | .align force => s!"align({force})"
  | .text value => s!"text{repr value}"
  | .nest indent inner => s!"nest{indent}[{structure? inner}]"
  | .append left right => s!"{structure? left} {structure? right}"
  | .group inner behavior =>
    let tag := match behavior with
      | .fill => "fill"
      | .allOrNone => "grp"
    s!"{tag}[{structure? inner}]"
  | .tag tag inner => s!"tag{tag}[{structure? inner}]"

private unsafe def run (widthText moduleName : String) : IO UInt32 := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let some width := widthText.toNat?
    | throw <| IO.userError "width must be a natural number"
  let source ← (← IO.getStdin).readToEnd
  let snapshot ← processSource moduleName.toName source
  let some finalState := Language.Lean.waitForFinalCmdState? snapshot
    | throw <| IO.userError "frontend produced no final command state"
  let options := finalState.scopes.head!.opts
  for command in commandSnapshots snapshot do
    let stx := command.stx
    if Parser.isTerminalCommand stx then break
    let some start := stx.getPos? | continue
    let some stop := stx.getTailPos? | continue
    let stripped := Formatter.withoutBoundaryTrivia stx
    let result : Except String Std.Format ← Core.CoreM.toIO'
      (do
        try
          return .ok (← PrettyPrinter.formatCommand stripped)
        catch exception =>
          return .error (← exception.toMessageData.toString))
      { fileName := "NativeLayoutDefectsInput.lean"
        fileMap := FileMap.ofString source, options }
      { env := finalState.env }
    IO.println s!"=== {stx.getKind} {start.byteIdx}:{stop.byteIdx} ==="
    IO.println "--- source ---"
    IO.println (String.Pos.Raw.extract source start stop)
    match result with
    | .error detail => IO.println s!"--- native FAILED: {detail}"
    | .ok format =>
      IO.println "--- native ---"
      IO.println (Std.Format.pretty format (width := width))
      IO.println "--- struct ---"
      IO.println (structure? format)
  return 0

end NativeLayoutDefects

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | [width] => NativeLayoutDefects.run width "NativeLayoutDefectsInput"
  | [width, moduleName] => NativeLayoutDefects.run width moduleName
  | _ =>
    IO.eprintln "usage: Probe.lean WIDTH [MODULE]"
    return 2
