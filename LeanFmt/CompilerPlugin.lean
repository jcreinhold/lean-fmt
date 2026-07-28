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
holds these facts computes the findings outside.

**Nor does it render the canonical layout.** Recording each module's formatted bytes at build time
would make `format --check` free, and it was considered directly and refuted on six counts. Written
down so nobody proposes it again from the outside.

1. *The hook is not in the pinned toolchain.* Rendering a command needs the scope in force **before**
   it elaborated; `addLinter` hands the linter the scope after. `registerStatefulLinter` is the only
   route to a prior state and it does not exist in `v4.33.0-rc1` — `Lean/Elab/Command.lean` has
   `addLinter`, `lintersRef`, `runLinters`, and `runLintersAsync`, and nothing stateful. It landed
   in Lean master on 2026-07-20, still unreleased. Because this plugin loads into the *consumer's*
   compiler and toolchains must match exactly (`docs/ci.md`), adopting it would raise the floor to
   v4.34 for every integrating project, not just for us.
2. *Linters do not run on `#guard_msgs`.* `Command.lean:663` skips `runLintersAsync` for any command
   containing one, silently. A command-to-command chain would have invisible gaps, and this
   repository has live `#guard_msgs` fixtures.
3. *It taxes every consumer's build.* This dylib's content hash is a direct trace input of every
   integrated module — `tests/downstream/project`'s `Consumer/Basic.trace` carries
   `["module plugins", [["…liblean_x2dfmt_LeanFmtCompilerPlugin.dylib", "…"]]]`. Over this
   repository's last 200 commits, 10 (5.0%) touched the current plugin glob set and 69 (34.5%) would
   touch a render-extended one: a 6.9× increase in how often an ordinary lean-fmt commit forces a
   full rebuild of every integrating project. The paragraph above records this defect being measured
   and fixed once already.
4. *The render is a whole-file fold, not a stream.* `Comments.build` and `Suppression.collect` take
   every command and the whole source, so nothing can run at command *i*. Deferring to the end means
   retaining every command's environment for the module.
5. *It bakes in one line width*, which the build does not know and which is per-file configuration;
   and `LeanFmt.Rules` re-enters this link closure through `Suppression`, undoing count 3's fix.
6. *The payoff is one run.* `format` writing a file makes its own `.olean` stale, so the next run
   cannot read build output anyway, and the result cache already covers repeats. -/

/- Each command owns one independently persistent record. Async command elaboration may complete in
any order, so aggregating inside the compiler is unsound; the facet extractor validates, sorts, and
compacts the records after the successful `.olean` exists. -/
private def produceCommandRecord (stx : Syntax) : CommandElabM Unit := do
  let environment ← getEnv
  if environment.mainModule.isAnonymous then
    return
  let fileMap ← getFileMap
  let record := CommandArtifactRecord.ofSyntax environment.mainModule.toString fileMap.source
    (Parser.isTerminalCommand stx) stx
  logAt stx
    (.tagged commandArtifactLinter <| .tagged Lean.Linter.linterMessageTag <|
      m!"{Lean.toJson record |>.compress}")
    (severity := .information) (isSilent := true)

initialize addLinter { name := `leanFmtCommandSyntaxArtifact, run := produceCommandRecord }

end LeanFmt.Internal.CompilerPlugin
