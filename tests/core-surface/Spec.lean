module

import all LeanFmt.Formatter.CoreSurface

open Lean LeanFmt.Internal

private def expect (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

public unsafe def main (_ : List String) : IO UInt32 := do
  initSearchPath (← findSysroot)
  let env ← importModules #[{ module := `Lean }] {}
  expect
    (CoreSurface.owner env .command ``Parser.Command.declaration == .structural .command)
    "command parser kind was not structurally classified"
  expect
    (CoreSurface.owner env .term ``Parser.Term.doReturn == .structural .term)
    "do-return parser kind was not structurally classified"
  expect
    (CoreSurface.owner env .tactic ``Parser.Tactic.tacticSeq == .structural .tactic)
    "tactic sequence was not structurally classified"
  expect (CoreSurface.owner env .term `ident == .lexical)
    "shared identifier leaf was not lexically classified"
  expect (CoreSurface.owner env .term `choice == .transparent)
    "choice wrapper was not transparently classified"
  expect (CoreSurface.owner env .command `Project.Custom.command == .extension)
    "unknown project kind silently entered the core surface"
  expect (!CoreSurface.registryAllowed env .term ``Parser.Term.doReturn)
    "registry was allowed for a closed core term"
  expect (CoreSurface.registryAllowed env .command `Project.Custom.command)
    "registry was refused for an open project root"
  IO.println "core-surface classifier: ok"
  return 0
