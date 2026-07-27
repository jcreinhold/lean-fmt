/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.ArtifactModel

import Lean.Linter.PersistentLintLog

open Lean Elab Command

namespace LeanFmt.Internal.CompilerPlugin

/- **This plugin projects; it does not lint.** It does not import `LeanFmt.Rules` and must not: it is
linked into every compilation of every module of any project integrating the formatter, so its whole
import closure enters the target project's build graph. While the rules were in here, editing one
rule's message text invalidated every module's Lake trace and changed the compiled bytes of any
module with a finding — measured. A rule's prose does not belong in an `.olean`.

What belongs here is what a later reader cannot recompute: the exact frontend's projection. Whoever
holds these facts computes the findings outside. -/

private partial def findCommandOptions? (target : Syntax) (tree : InfoTree) : Option Options :=
  go none tree
where
  go (context? : Option ContextInfo) : InfoTree → Option Options
    | .context context tree => go (context.mergeIntoOuter? context?) tree
    | .node info children =>
      let found := match context?, info with
        | some context, .ofCommandInfo command =>
          if command.stx.eqWithInfo target then some context.options else none
        | _, _ => none
      found <|> children.findSome? (go (info.updateContext? context?))
    | .hole _ => none

private def commandOptions? (target : Syntax) : CommandElabM (Option Options) := do
  let infoState ← getInfoState
  return infoState.trees.toArray.findSome? (findCommandOptions? target)

/- Each command owns one independently persistent record. Async command elaboration may complete in
any order, so aggregating inside the compiler is unsound; the facet extractor validates, sorts, and
compacts the records after the successful `.olean` exists. -/
private def produceCommandRecord (stx : Syntax) : CommandElabM Unit := do
  let environment ← getEnv
  if environment.mainModule.isAnonymous then
    return
  let fileMap ← getFileMap
  let options ← match ← commandOptions? stx with
    | some options => pure options
    | none => getOptions
  let record := CommandArtifactRecord.ofSyntax environment.mainModule.toString fileMap.source
    (Parser.isTerminalCommand stx) stx options
  logAt stx
    (.tagged commandArtifactLinter <| .tagged Lean.Linter.linterMessageTag <|
      m!"{Lean.toJson record |>.compress}")
    (severity := .information) (isSilent := true)

initialize addLinter { name := `leanFmtCommandSyntaxArtifact, run := produceCommandRecord }

end LeanFmt.Internal.CompilerPlugin
