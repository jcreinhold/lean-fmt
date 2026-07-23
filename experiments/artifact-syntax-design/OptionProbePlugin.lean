module

import Lean.Elab.Command
import Lean.Server.InfoUtils
import Std.Sync.Mutex

open Lean Elab Command

private builtin_initialize carrierRef : Std.Mutex (Std.HashMap String String) ← Std.Mutex.new {}

private def rangeKey? (stx : Syntax) : Option (Nat × Nat) := do
  let range ← stx.getRange?
  return (range.start.byteIdx, range.stop.byteIdx)

private def optionCount (options : Options) : Nat := Id.run do
  let mut count := 0
  for _ in options do
    count := count + 1
  return count

private def captureOptions (commands : Array Syntax) : CommandElabM Unit := do
  let infoState ← getInfoState
  let rows := infoState.trees.toArray.foldl (init := #[]) fun rows tree =>
    tree.foldInfo (init := rows) fun context info rows =>
      match info with
      | .ofCommandInfo command =>
        match rangeKey? command.stx with
        | some range => rows.push (range, context.options)
        | none => rows
      | _ => rows
  let commandRows := commands.map fun command =>
    let range := rangeKey? command
    let options? := range.bind fun key => rows.findSome? fun (candidate, options) =>
      if candidate == key then some options else none
    (range, options?.map optionCount)
  let matched := commandRows.countP (·.2.isSome)
  let distinct := commandRows.foldl (init := #[]) fun states row =>
    match row.2 with
    | some count => if states.contains count then states else states.push count
    | none => states
  let carriers : Std.HashMap String String ← carrierRef.atomically do
    let carriers ← get
    set ({} : Std.HashMap String String)
    return carriers
  logInfo s!"option-probe commands={commands.size} matched={matched} distinct-counts={distinct} \
    carriers={carriers.size} command-ranges={commands.map rangeKey?} \
    info-ranges={rows.map (some ·.1)}"

private def captureCommandOption (stx : Syntax) : CommandElabM Unit := do
  let infoState ← getInfoState
  let rows := infoState.trees.toArray.foldl (init := #[]) fun rows tree =>
    tree.foldInfo (init := rows) fun context info rows =>
      match info with
      | .ofCommandInfo command =>
        rows.push (rangeKey? command.stx, optionCount context.options, toString context.options)
      | _ => rows
  let post ← getOptions
  let key := toString (rangeKey? stx)
  carrierRef.atomically do
    modify fun (carriers : Std.HashMap String String) => carriers.insert key (toString rows)
  logInfo s!"option-command range={rangeKey? stx} pre={rows} \
    post={(optionCount post, toString post)}"

initialize addLinter { name := `artifactSyntaxCommandOptionProbe, run := captureCommandOption }
initialize addModuleLinter { name := `artifactSyntaxOptionProbe, run := captureOptions }
