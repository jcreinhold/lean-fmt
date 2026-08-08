module

public import Test

/-!
# The module-formatter suite

One-run whole-module drafts: region tiling, terminal/tail, normalized line endings, exact setup, and
deterministic counters. Structural admission belongs to `tests/fixtures/formatter`.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace ModuleFormatter

/-- Byte-range slice: the draft's offsets are byte offsets. -/
private def sliceOf (source : String) (start stop : Nat) : String :=
  String.Pos.Raw.extract source ⟨start⟩ ⟨stop⟩

/-- A successful draft (diagnostics asserted empty) plus its metrics invariants shared by the
terminal and plugin shapes. -/
private def draftOf (report : Lean.Json) (label : String) : IO Lean.Json := do
  let draft ← formatDraft report label
  let diagnostics := (jsonAt? report [.field "diagnostics"]).bind (·.getArr?.toOption)
  ensure (diagnostics.map (·.size) == some 0) s!"{label}: unexpected diagnostics"
  return draft

private def metricEq (draft : Lean.Json) (name : String) (expected : Nat) (label : String) :
    IO Unit :=
  ensure (natAt? draft [.field "metrics", .field name] == some expected)
    s!"{label}: metrics.{name} ≠ {expected}"

private def metricPos (draft : Lean.Json) (name : String) (label : String) : IO Nat := do
  let some value :=
    natAt? draft
      [.field "metrics", .field name] | throw <| IO.userError s!"{label}: metrics.{name} missing"
  return value

/-- The draft's own region offsets. -/
private def regionOffset (draft : Lean.Json) (name : String) (label : String) : IO Nat := do
  let some value := natAt? draft [.field name] | throw <| IO.userError s!"{label}: {name} missing"
  return value

/-- Deterministic header/command/tail draft tiles source and output. Two runs of the same module
must produce byte-identical drafts, the terminal tail must ride along verbatim, and the source map
must walk both regions without a gap. -/
private def testTerminalDraft (root : System.FilePath) (application : String)
    (work : System.FilePath) : IO Unit := do
  let terminal := work / "Terminal.lean"
  writeFile terminal
      "module\n\nimport AdapterSyntax\n\nopen AdapterSyntax\n\ndescriptor_command beforeExit := twice(1)\n\n\
    -- terminal-leading payload\n#exit\nverbatim tail λ that must not be parsed\n"
  let setup ← setupFile root work (terminal.toString)
  -- `setup-file` is given the absolute path; the analyze runs go through `lake env`, as the old
  -- script's `analyze` did.
  let runDraft : IO Lean.Json := do
    let report ←
      analyzeExact root application setup terminal.toString terminal.toString "draft:72"
          (viaLakeEnv := true)
    draftOf report "terminal"
  let left ← runDraft
  let right ← runDraft
  ensure (left == right) "draft or metrics are nondeterministic"
  metricEq left "frontendRuns" 1 "terminal"
  let commands ← metricPos left "commands" "terminal"
  ensure (natAt? left [.field "metrics", .field "nativeDocuments"] == some commands)
      "terminal: nativeDocuments ≠ commands"
  let aligned ← metricPos left "alignedTokens" "terminal"
  ensure (aligned > commands) "terminal: alignedTokens stopped dominating commands"
  metricEq left "descriptorDocuments" 1 "terminal"
  let registry ← metricPos left "registryNodes" "terminal"
  let native ← metricPos left "nativeDocuments" "terminal"
  ensure (registry >= native) "terminal: registryNodes stopped covering nativeDocuments"
  let terminalStop ← regionOffset left "terminalStop" "terminal"
  let sourceBytes ← regionOffset left "sourceBytes" "terminal"
  ensure (terminalStop < sourceBytes) "terminal: terminal stop does not precede the source end"
  let raw := (← IO.FS.readFile terminal).crlfToLf
  let tail := sliceOf raw terminalStop raw.utf8ByteSize
  let some text :=
    (left.getObjValAs? String
        "text").toOption | throw <| IO.userError "terminal: draft text missing"
  ensure (tail.startsWith "#exit" && text.endsWith tail)
      "terminal: the verbatim tail did not ride along"
  let some marks :=
    (jsonAt? left [.field "sourceMap"]).bind
      (·.getArr?.toOption) | throw <| IO.userError "terminal: source map missing"
  let mut sourceCursor := 0
  let mut outputCursor := 0
  for mark in marks do
    ensure (natAt? mark [.field "source", .field "start"] == some sourceCursor)
        "terminal: source map has a source gap"
    ensure (natAt? mark [.field "output", .field "start"] == some outputCursor)
        "terminal: source map has an output gap"
    sourceCursor := (natAt? mark [.field "source", .field "stop"]).get!
    outputCursor := (natAt? mark [.field "output", .field "stop"]).get!
  ensure (sourceCursor == raw.utf8ByteSize && sourceCursor == sourceBytes)
      "terminal: source map does not cover the whole source"
  ensure (outputCursor == text.utf8ByteSize) "terminal: source map does not cover the whole output"
  ensure (text.startsWith "module\n\nimport AdapterSyntax\n\n")
      "terminal: header lost the source's blank lines"
  -- `headerContract` is the header's node/atom spelling list; the import's identifier must be in
  -- it as an entry of its own, not as a substring of one.
  let some entries :=
    (jsonAt? left [.field "headerContract"]).bind
      (·.getArr?.toOption) | throw <| IO.userError "terminal: headerContract missing"
  ensure (entries.contains "ident:AdapterSyntax")
      s!"terminal: headerContract lost the import identifier: {entries}"

/-- A terminal-only module has a disjoint header and verbatim tail: zero commands, both stops at
the `#exit`, the text is the source, and the map has exactly the header and tail marks. -/
private def testOnlyExit (root : System.FilePath) (application : String) (work : System.FilePath)
    (borrowedSetup : System.FilePath) : IO Unit := do
  let onlyExit := work / "OnlyExit.lean"
  writeFile onlyExit "module\n\n#exit\nterminal-only tail\n"
  let report ←
    analyzeExact root application borrowedSetup onlyExit.toString onlyExit.toString "draft"
        (viaLakeEnv := true)
  let draft ← draftOf report "only-exit"
  metricEq draft "commands" 0 "only-exit"
  let source := (← IO.FS.readFile onlyExit).crlfToLf
  let exitPos := (source.splitOn "#exit").head!.utf8ByteSize
  ensure ((source.splitOn "#exit").length == 2) "only-exit: fixture lost its #exit"
  let headerStop ← regionOffset draft "headerStop" "only-exit"
  let terminalStop ← regionOffset draft "terminalStop" "only-exit"
  ensure (headerStop == exitPos && terminalStop == exitPos)
      "only-exit: header and terminal stops are not both the #exit"
  let some text :=
    (draft.getObjValAs? String
        "text").toOption | throw <| IO.userError "only-exit: draft text missing"
  ensure (text == source) "only-exit: draft text is not the source"
  let some marks :=
    (jsonAt? draft [.field "sourceMap"]).bind
      (·.getArr?.toOption) | throw <| IO.userError "only-exit: source map missing"
  ensure (marks.size == 2) "only-exit: source map is not header+tail"

/-- The final-newline convention is preserved, and CRLF normalizes to an identical draft. -/
private def testLineEndings (root : System.FilePath) (application : String)
    (work : System.FilePath) : IO Unit := do
  let lineEnd := work / "LineEnd.lean"
  writeFile lineEnd
      "module\n\ndef finalLine := List.map (fun value => value + 1) [1, 2, 3, 4, 5, 6]\n"
  let text ← IO.FS.readFile lineEnd
  let noFinal := work / "NoFinal.lean"
  writeFile noFinal (text.dropEndWhile (· == '\n')).toString
  let crlf := work / "CRLF.lean"
  IO.FS.writeBinFile crlf ((text.replace "\n" "\r\n").toUTF8)
  let setup ← setupFile root work lineEnd.toString
  let runDraft (name : System.FilePath) (label : String) : IO Lean.Json := do
    let report ←
      analyzeExact root application setup name.toString name.toString "draft:40" (viaLakeEnv :=
          true)
    draftOf report label
  let lf ← runDraft lineEnd "lf"
  let noFinalDraft ← runDraft noFinal "nofinal"
  let crlfDraft ← runDraft crlf "crlf"
  let lfText := (lf.getObjValAs? String "text").toOption.getD ""
  let noFinalText := (noFinalDraft.getObjValAs? String "text").toOption.getD ""
  ensure (lfText.endsWith "\n" && !(noFinalText.endsWith "\n")) "final-newline convention changed"
  ensure (lf == crlfDraft) "CRLF and LF did not produce the same normalized draft"

/-- The module belongs to a plugin-enabled Lake target and contains a real `choice` node plus
imported custom notation, doc comments, nested comments, and Unicode. -/
private def testPluginSetup (root : System.FilePath) (application : String)
    (work : System.FilePath) : IO Unit := do
  let setup ← setupFile root work "tests/fixtures/compiler/LocalSyntax.lean"
  let report ←
    analyzeExact root application setup "tests/fixtures/compiler/LocalSyntax.lean"
        "tests/fixtures/compiler/LocalSyntax.lean" "draft" (viaLakeEnv := true)
  let draft ← draftOf report "plugin"
  metricEq draft "commands" 8 "plugin"
  let commands := 8
  ensure (natAt? draft [.field "metrics", .field "nativeDocuments"] == some commands)
      "plugin: nativeDocuments ≠ commands"
  let aligned ← metricPos draft "alignedTokens" "plugin"
  ensure (aligned > commands) "plugin: alignedTokens stopped dominating commands"
  let registry ← metricPos draft "registryNodes" "plugin"
  ensure (registry >= commands) "plugin: registryNodes stopped covering commands"
  metricEq draft "commentOwners" 6 "plugin"
  let some text :=
    (draft.getObjValAs? String "text").toOption | throw <| IO.userError "plugin: draft text missing"
  ensureContains text "emit_local_command" "plugin"
  ensureContains text "an identifier with spaces" "plugin"

/-- Broken headers and unresolved imports are frontend refusals, never format drafts. -/
private def testBrokenHeaders (root : System.FilePath) (application : String)
    (work : System.FilePath) (borrowedSetup : System.FilePath) : IO Unit := do
  let malformed := work / "Malformed.lean"
  writeFile malformed "module\nimport\n"
  let unresolved := work / "Unresolved.lean"
  writeFile unresolved "module\n\nimport Definitely.Does.Not.Exist\n"
  for (path, label) in [(malformed, "malformed"), (unresolved, "unresolved")]do
    let report ←
      analyzeExact root application borrowedSetup path.toString path.toString "draft" (viaLakeEnv :=
          true)
    ensure (jsonAt? report [.field "formatDraft"] |>.all (· == Lean.Json.null))
        s!"{label}: a broken module produced a draft"
    ensure (jsonAt? report [.field "artifact"] |>.all (· == Lean.Json.null))
        s!"{label}: a broken module produced an artifact"
    let diagnostics := (jsonAt? report [.field "diagnostics"]).bind (·.getArr?.toOption)
    ensure ((diagnostics.map (·.size)).getD 0 > 0) s!"{label}: no diagnostics for a broken module"

/-- Header blank lines are the organizer's structure, not the formatter's to remove: a blank after
the `module` marker and between import groups survives formatting, and a run of blanks collapses
to one. -/
private def testHeaderBlankLines (root : System.FilePath) (application : String)
    (work : System.FilePath) (borrowedSetup : System.FilePath) : IO Unit := do
  let grouped := work / "Grouped.lean"
  let groupedHeader := "module\n\nimport AdapterSyntax\n\nimport Lean.Data.Json\n\n"
  writeFile grouped (groupedHeader ++ "def groupedValue : Nat := 1\n")
  let collapsed := work / "Collapsed.lean"
  writeFile collapsed "module\n\n\n\nimport AdapterSyntax\n\ndef collapsedValue : Nat := 1\n"
  for (path, label, expected) in
    [(grouped, "grouped", groupedHeader),
      (collapsed, "collapsed", "module\n\nimport AdapterSyntax\n\n")]do
    let report ←
      analyzeExact root application borrowedSetup path.toString path.toString "draft" (viaLakeEnv :=
          true)
    let draft ← draftOf report label
    let some text :=
      (draft.getObjValAs? String
          "text").toOption | throw <| IO.userError s!"{label}: draft text missing"
    ensure (text.startsWith expected) s!"{label}: header blank lines changed"

end ModuleFormatter

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  discard <|
      expectExit 0 "fixture library build" "lake"
        #["build", "lean-fmt", "FormatterAdapterFixtures", "CompilerFixtures"] (cwd? := some root)
        (env := #[("LEAN_NUM_THREADS", some "1")])
  withScratchDir "module-formatter" fun work => do
      let borrowedSetup ← setupFile root work "tests/fixtures/check/Clean.lean"
      let cases : Array Case :=
        #[{ name := "terminal-draft",
            run := ModuleFormatter.testTerminalDraft root application work },
          { name := "only-exit",
            run := ModuleFormatter.testOnlyExit root application work borrowedSetup },
          { name := "line-endings", run := ModuleFormatter.testLineEndings root application work },
          { name := "plugin-setup", run := ModuleFormatter.testPluginSetup root application work },
          { name := "broken-headers",
            run := ModuleFormatter.testBrokenHeaders root application work borrowedSetup },
          { name := "header-blank-lines",
            run := ModuleFormatter.testHeaderBlankLines root application work borrowedSetup }]
      runCases "module-formatter" cases args
