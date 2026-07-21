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
linked into every compilation of every module of any project that integrates the formatter, so
whatever is in its import closure is in the target project's build graph. While the rules were in
here, editing one rule's message text invalidated every module's Lake trace and changed the compiled
bytes of any module that had a finding — measured, `notes/01-rule-facts.md` §3. A rule's prose does
not belong in an `.olean`.

What belongs here is what a later reader cannot recompute: the exact frontend's projection. Whoever
holds these facts computes the findings outside. -/

/- A module linter receives the non-terminal command stream and runs at the terminal command, which
is `getRef` here. The terminal is what ends the parsed region — `eoi` ordinarily, `#exit` for a file
with an unparsed tail — so the projection needs it and the command stream does not contain it.

`fileMap.source` is the string the parser saw, already normalized by `Parser.mkInputContext`. This
position cannot observe the file's bytes, which is why artifact identity is normalized identity. -/
private def produceArtifact (commands : Array Syntax) : CommandElabM Unit := do
  let environment ← getEnv
  if environment.mainModule.isAnonymous then
    return
  let fileMap ← getFileMap
  let terminal ← getRef
  let artifact := ModuleArtifact.ofParsedModule environment.mainModule.toString fileMap.source
    commands (some terminal)
  logAt terminal
    (.tagged artifactLinter <| .tagged Lean.Linter.linterMessageTag <|
      m!"{Lean.toJson artifact |>.compress}")
    (severity := .information) (isSilent := true)

initialize addModuleLinter { name := `leanFmtSemanticArtifact, run := produceArtifact }

end LeanFmt.Internal.CompilerPlugin
