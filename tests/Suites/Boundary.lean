module

public import Test

import all LeanFmt.Basic

/-!
# The native source boundary suite

Port of `tests/boundary/run.sh`. Repo hygiene, not product behavior: lakefiles are executable
configuration, every compiled Lean source uses private-by-default modules, and no Rust workspace,
cache, build output, or generated binary is tracked. The link-closure probes at the end are the
invariant in its observable form: the proof library is globbed alone and builds with
every `lake build`, but it must never enter a link closure an integrating project pays for.
-/

open LeanFmt.Test

namespace Boundary

/-- Tracked `.lean` sources, minus lakefiles (executable configuration) and `docs/` (hand-run
evidence probes, some legacy non-`module` on purpose). -/
private def compiledSources (root : System.FilePath) : IO (Array String) := do
  let result ← expectExit 0 "git ls-files" "git" #["ls-files", "*.lean"] (cwd? := some root)
  return (result.stdout.splitOn "\n" |>.filter fun path =>
        !path.isEmpty && path != "lakefile.lean" && !(path.endsWith "/lakefile.lean") &&
          !(path.startsWith "docs/")).toArray

private def readRepoFile (root : System.FilePath) (relative : String) : IO String :=
  IO.FS.readFile (root / relative)

/-- The first token Lean itself would see: skip nestable `/- -/` blocks and `--` line comments and
whitespace, then take the run of non-whitespace. `module` must be the first *token*, not the first
line — every source here carries a copyright block above it, and the gate pins the module system,
not a comment style. -/
private partial def firstToken (chars : List Char) (depth : Nat) : String :=
  match chars with
  | [] => ""
  | c :: rest =>
    let marker (a b : Char) : Bool := c == a && rest.head? == some b
    if marker '/' '-' then firstToken (rest.drop 1) (depth + 1)
    else
      if depth > 0 && marker '-' '/' then firstToken (rest.drop 1) (depth - 1)
      else
        if depth == 0 && marker '-' '-' then firstToken (rest.dropWhile (· != '\n')) 0
        else
          if depth > 0 then firstToken rest depth
          else
            if c.isWhitespace then firstToken rest 0
            else String.ofList (c :: rest.takeWhile (!·.isWhitespace))

private def testModuleHeaders (root : System.FilePath) : IO Unit := do
  for path in ← compiledSources root do
    let token := firstToken (← readRepoFile root path).toList 0
    ensure (token == "module") s!"{path} does not begin with module (first token: {repr token})"

private def testNoTrackedArtifacts (root : System.FilePath) : IO Unit := do
  let result ← expectExit 0 "git ls-files" "git" #["ls-files"] (cwd? := some root)
  for path in result.stdout.splitOn "\n"do
    let components := path.splitOn "/"
    let forbidden :=
      components.any fun component =>
        component == "Cargo.toml" || component == "Cargo.lock" || component == "target" ||
              component == ".lake" ||
            component == ".lean-fmt-cache" ||
          component.endsWith ".rs"
    ensure (!forbidden)
        s!"tracked Rust, cache, or build artifact crossed the native source boundary: {path}"

/-- Lines whose first token is `keyword` followed by whitespace (or the whole line). -/
private def startsWithKeyword (line keyword : String) : Bool :=
  let trimmed := line.trimLeft
  trimmed.startsWith s!"{keyword} " || trimmed == keyword

private def testRootExportsNothing (root : System.FilePath) : IO Unit := do
  for line in (← readRepoFile root "LeanFmt.lean").splitOn "\n"do
    let bad :=
      ["import", "def", "structure", "inductive", "class", "abbrev"].any (startsWithKeyword line)
    ensure (!bad) "LeanFmt root unexpectedly exports or defines application state"

private def testNoPublicDeclarations (root : System.FilePath) : IO Unit := do
  let result ← expectExit 0 "git ls-files" "git" #["ls-files", "LeanFmt/*.lean"] (cwd? := some root)
  for path in result.stdout.splitOn "\n" |>.filter (!·.isEmpty)do
    for line in (← readRepoFile root path).splitOn "\n"do
      ensure (!(line.startsWith "public "))
          s!"application library contains an explicit public declaration: {path}"

/-- Files carrying a public entry point. The old suite named three files; this scans every compiled
source, which is the check the comment above it always described: only executable/test entry points
are public in the active package. `docs/` is out of scope:
hand-run probes, not package entry points. -/
private def testEntryPointSet (root : System.FilePath) : IO Unit := do
  let result ← expectExit 0 "git ls-files" "git" #["ls-files", "*.lean"] (cwd? := some root)
  let mut entries : Array String := #[]
  let inScope (path : String) : Bool :=
    !path.isEmpty && !(path.startsWith "docs/") && !(path.startsWith "experiments/")
  for path in result.stdout.splitOn "\n" |>.filter inScope do
    for line in (← readRepoFile root path).splitOn "\n"do
      if line.startsWith "public def main" || line.startsWith "public unsafe def main" then
        entries := entries.push path
  let expected :=
    #["Main.lean", "tests/Lsp/Acceptance.lean", "tests/Suites/ApplicationFormatter.lean",
      "tests/Suites/BlockFormatter.lean", "tests/Suites/Boundary.lean", "tests/Suites/Cache.lean",
      "tests/Suites/Catalog.lean", "tests/Suites/Check.lean", "tests/Suites/Ci.lean",
      "tests/Suites/CollectionFormatter.lean", "tests/Suites/CommandFormatter.lean",
      "tests/Suites/Comments.lean", "tests/Suites/Compiler.lean",
      "tests/Suites/DeclarationFormatter.lean", "tests/Suites/Discovery.lean",
      "tests/Suites/Downstream.lean", "tests/Suites/Editor.lean",
      "tests/Suites/FormatSuppression.lean", "tests/Suites/Formatter.lean",
      "tests/Suites/FormatterAdapter.lean", "tests/Suites/Imports.lean",
      "tests/Suites/Incremental.lean", "tests/Suites/Layout.lean", "tests/Suites/Lossless.lean",
      "tests/Suites/Lsp.lean", "tests/Suites/Modes.lean", "tests/Suites/ModuleFormatter.lean",
      "tests/Suites/NativeLayout.lean", "tests/Suites/Performance.lean",
      "tests/Suites/Reporting.lean", "tests/Suites/Scale.lean", "tests/Suites/SecurityBench.lean",
      "tests/Suites/Semantic.lean", "tests/Suites/Stream.lean", "tests/Suites/Style.lean",
      "tests/Suites/Suppression.lean", "tests/Suites/Syntax.lean",
      "tests/Suites/TermFormatter.lean", "tests/Suites/Validator.lean", "tests/Suites/Watch.lean",
      "tests/Test/Runner.lean", "tests/Test/Unit.lean", "tools/CheckModules.lean",
      "tools/LeanFmtArtifactExtract.lean"]
  ensureEq "active public entry-point set changed" expected.toList (entries.qsort (· < ·)).toList

private def testPluginImportBoundary (root : System.FilePath) : IO Unit := do
  -- Named rather than merely absent: while `LeanFmt.Rules` was in this set, editing one rule's
  -- message text invalidated every integrated module's Lake trace.
  let imports :=
    (← readRepoFile root "LeanFmt/CompilerPlugin.lean").splitOn "\n" |>.filterMap fun line =>
      line.dropPrefix? "import all LeanFmt." |>.map (·.toString)
  ensureEq "compiler plugin import boundary changed" ["ArtifactModel"]
      (imports.toArray.qsort (· < ·)).toList

private def testPluginGlobs (root : System.FilePath) : IO Unit := do
  -- The import graph is only half of it: a Lake library links every module it globs, so a module
  -- named here reaches the plugin `.so` whether or not anything imports it.
  let lines := (← readRepoFile root "lakefile.lean").splitOn "\n"
  let start := lines.findIdx (· == "lean_lib LeanFmtCompilerPlugin where")
  -- The block runs to the next top-level Lake declaration; the globs array's own layout is the
  -- formatter's, not this parser's.
  let block :=
    (lines.drop (start + 1)).takeWhile fun line =>
      !(line.startsWith "lean_lib " || line.startsWith "lean_exe " || line.startsWith "package ")
  for forbidden in
    ["Application", "Cache", "Cli", "Config", "Edit", "Project", "Rules", "Semantic", "Service"]do
    ensure (!(block.any (·.contains s!"LeanFmt.{forbidden}")))
        s!"compiler plugin Lake target includes rule or application modules: {forbidden}"

private def testLayerImports (root : System.FilePath) : IO Unit := do
  -- Common callers see only the deepest operation appropriate to their layer.
  let main ← readRepoFile root "Main.lean"
  ensure ((main.splitOn "\n").contains "import all LeanFmt.Cli")
      "Main.lean no longer imports exactly the CLI layer"
  let cli ← readRepoFile root "LeanFmt/Cli.lean"
  ensure ((cli.splitOn "\n").contains "import all LeanFmt.LanguageServer")
      "Cli.lean no longer imports exactly the language server layer"
  let server ← readRepoFile root "LeanFmt/LanguageServer.lean"
  ensure ((server.splitOn "\n").contains "import all LeanFmt.Application")
      "LanguageServer.lean no longer imports exactly the application layer"

private def testNoLeanServer (root : System.FilePath) : IO Unit := do
  -- `Lean.Server.Utils` converts client positions **without clamping** them, and an unclamped LSP
  -- position resolves past the end of the buffer. Scoped to this module on purpose:
  -- `LeanFmt/Analysis.lean` imports `Lean.Server.InfoUtils` and should.
  for line in (← readRepoFile root "LeanFmt/LanguageServer.lean").splitOn "\n"do
    let trimmed := line.trimLeft
    ensure
        (!(trimmed.startsWith "import Lean.Server" || trimmed.startsWith "import all Lean.Server"))
        "the language server imports Lean.Server; its position layer must clamp"

private def testNoLegacyArchitecture (root : System.FilePath) : IO Unit := do
  let forbidden :=
    ["WorkerFleet", "SourceParser", "run_project_fleet", "FleetPlan", "libleanshared",
      "lean-fmt-check-artifacts", "--pinned", "--jobs"]
  let sources :=
    ((← compiledSources root).toList.filter fun path =>
        path.startsWith "LeanFmt/" || path == "Main.lean") ++
      ["lakefile.lean"]
  for path in sources do
    let contents ← readRepoFile root path
    for token in forbidden do
      ensure (!(contents.contains token))
          s!"legacy execution architecture returned to active production: {token} in {path}"

/-- Count of `needle` lines in `nm -a` output for `image`, or `none` when the image does not exist
(the old suite skipped silently too — a missing binary is the build's problem, not this gate's). -/
private def nmCount (root : System.FilePath) (image needle : String) : IO (Option Nat) := do
  unless (← (root / image).pathExists) do
    return none
  let result ← runProc "nm" #["-a", (root / image).toString]
  return some (result.stdout.splitOn "\n" |>.filter (·.contains needle) |>.length)

private def testLinkClosure (root : System.FilePath) : IO Unit := do
  -- The decision must be in the binary: the production path calls it.
  if let some count← nmCount root ".lake/build/bin/lean-fmt" "LeanFmt_Internal_Cache_Decision" then
    ensure (count > 0)
        "the shared currency decision is not linked into the binary; the proof is about dead code"
  for image in
    [".lake/build/bin/lean-fmt", ".lake/build/lib/liblean_x2dfmt_LeanFmtCompilerPlugin.dylib"]do
    if let some count← nmCount root image "LeanFmt_Internal_Cache_Spec" then
      ensure (count == 0) s!"proof library entered the link closure of {image}"
    if let some count← nmCount root image "LeanFmt_Cache_Spec" then
      ensure (count == 0) s!"proof library entered the link closure of {image}"
  -- The positive control: genuinely linked, so a zero count here means the probe stopped looking.
  if let some count← nmCount root ".lake/build/bin/lean-fmt" "LeanFmt_Digest" then
    ensure (count > 0)
        "link-closure probe found no LeanFmt_Digest symbols; the probe itself is broken"

/-- `runProc` scrubs the host's search paths from every child, and opting back in is a
deliberate, enumerated act: a suite may re-inject a variable only where the *point* of the case
is the path itself. Any other re-injection reopens the host-contamination class that cost the
v0.2.1 arc its ubuntu release legs — so a new one fails here until it joins this list with its
reason. The scan covers every suite file, so suites not yet written are already covered. -/
private def testSpawnScrubOptIns (root : System.FilePath) : IO Unit := do
  let allowed : Array (String × String) :=
    -- Cache.lean epochRun: the epoch-change case exists to move the search path; choosing it is
    -- the assertion. Compiler.lean testExtractorExactOlean: the case proves the extractor uses
    -- the facet's exact olean against a shadowing ambient path; the path is the adversary, and
    -- the library path is how the extractor dynloads the plugin it reads the artifact through.
    #[("tests/Suites/Cache.lean", "LEAN_PATH"), ("tests/Suites/Compiler.lean", "LEAN_PATH"),
      ("tests/Suites/Compiler.lean", "LD_LIBRARY_PATH"),
      ("tests/Suites/Compiler.lean", "DYLD_LIBRARY_PATH")]
  let scrubbed := #["LEAN_PATH", "LEAN_SRC_PATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"]
  let mut offenders : Array String := #[]
  for entry in ← (root / "tests" / "Suites").readDir do
    if entry.path.extension != some "lean" then
      continue
    let some fileName := entry.path.fileName | continue
    let relative := s!"tests/Suites/{fileName}"
    for line in (← readRepoFile root relative).splitOn "\n"do
      for var in scrubbed do
        -- The pattern is built from `var` so this case's own source never matches itself.
        if line.contains (s!"\"{var}\", some") && !(allowed.contains (relative, var)) then
          offenders := offenders.push s!"{relative}: {line.trimAscii}"
  ensure offenders.isEmpty
      s!"suite children re-inject scrubbed search paths outside the enumerated opt-ins:\n  {"
\n  ".intercalate offenders.toList}"

/-- The package's identity, and every place this repository spells its own version. Lake owns the
version; the other two follow it.

`LeanFmt.version` exists because the language server reports it to the editor. The README's
`require ... @ "vX.Y.Z"` is what a reader copies to take the dependency. Nothing linked the three
before this case, and both followers drifted: the server said 0.1.0 and the README pinned v0.1.1
while the package was 0.1.3. A release bumps the lakefile, and this case names the rest. -/
private def testPackageIdentity (root : System.FilePath) : IO Unit := do
  let lakefile ← readRepoFile root "lakefile.lean"
  let lines := lakefile.splitOn "\n"
  ensure (lines.contains "package «lean-fmt» where") "the lakefile lost its package declaration"
  ensure (lines.any (·.contains "lean_exe «lean-fmt» where"))
      "the lakefile lost its executable declaration"
  let some packaged :=
    lines.findSome? fun line =>
      (line.trimLeft.dropPrefix? "version := v!\"").map fun rest =>
        (rest.toString.takeWhile (· != '"')).toString
    | throw <| IO.userError "the lakefile lost its version"
  ensureEq "the reported version drifted from the package version" packaged LeanFmt.version
  let readme ← readRepoFile root "README.md"
  let some pinned :=
    (readme.splitOn "\n").findSome? fun line =>
      match line.splitOn "/lean-fmt\" @ \"" with
      | [_, rest] => some (rest.takeWhile (· != '"')).toString
      | _ => none
    | throw <| IO.userError "the README lost its dependency pin"
  ensureEq "the README's dependency pin drifted from the package version" pinned s!"v{packaged}"
  -- The fourth place: what the binary answers when someone asks what they installed. It went
  -- unanswered until publication was imminent -- `--version` fell through to the general help and
  -- exit 2.
  let reported ←
    expectExit 0 "lean-fmt --version" (root / ".lake" / "build" / "bin" / "lean-fmt").toString
        #["--version"]
  ensureEq "the binary does not report the package version" s!"lean-fmt {packaged}\n"
      reported.stdout

private def cases (root : System.FilePath) : Array Case :=
  #[{ name := "module-headers", run := testModuleHeaders root },
    { name := "no-tracked-artifacts", run := testNoTrackedArtifacts root },
    { name := "root-exports-nothing", run := testRootExportsNothing root },
    { name := "no-public-declarations", run := testNoPublicDeclarations root },
    { name := "entry-point-set", run := testEntryPointSet root },
    { name := "plugin-import-boundary", run := testPluginImportBoundary root },
    { name := "plugin-globs", run := testPluginGlobs root },
    { name := "layer-imports", run := testLayerImports root },
    { name := "no-lean-server", run := testNoLeanServer root },
    { name := "no-legacy-architecture", run := testNoLegacyArchitecture root },
    { name := "link-closure", run := testLinkClosure root },
    { name := "spawn-scrub-opt-ins", run := testSpawnScrubOptIns root },
    { name := "package-identity", run := testPackageIdentity root }]

end Boundary

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  runCases "boundary" (Boundary.cases root) args
