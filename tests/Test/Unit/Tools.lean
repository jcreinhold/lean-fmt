module

public import LeanFmt.Analysis
public import LeanFmt.Application
public import LeanFmt.ArtifactStore
public import LeanFmt.Cache
public import LeanFmt.Cli
public import LeanFmt.Comments
public import LeanFmt.Config
public import LeanFmt.Discovery
public import LeanFmt.Doc
public import LeanFmt.Edit
public import LeanFmt.Formatter.NativeLayout
public import LeanFmt.Imports
public import LeanFmt.LanguageServer
public import LeanFmt.Rules
public import LeanFmt.Suppression
public import Test

import all LeanFmt.Analysis
import all LeanFmt.Application
import all LeanFmt.ArtifactStore
import all LeanFmt.Cache
import all LeanFmt.Cli
import all LeanFmt.Comments
import all LeanFmt.Config
import all LeanFmt.Discovery
import all LeanFmt.Doc
import all LeanFmt.Edit
import all LeanFmt.Formatter.NativeLayout
import all LeanFmt.Imports
import all LeanFmt.LanguageServer
import all LeanFmt.Rules
import all LeanFmt.Suppression
import all Test.Unit.Layout

import Lake
import Lean.Data.Lsp

open LeanFmt LeanFmt.Internal

open LeanFmt.Test.Unit.Layout

namespace LeanFmt.Test.Unit.Tools

private def sliceOf (source : String) (start stop : Nat) : String :=
  String.Pos.Raw.extract source ⟨start⟩ ⟨stop⟩

/- Check a projection against the real parser output it claims to describe.

`structurallyValid` proves the spans tile; that is cheap and content-blind. What it cannot see is
whether the recorded spans mean what they say. So this walks the projection independently, slices
the source at every recorded boundary, and reads the bytes back:

- reconstruction concatenates header, every token with its trivia, and the tail, and compares the
  result to the whole file;
- each trivia run must actually contain the form its kind names.

Contiguity makes each trivia run's start the previous stop, so the walk below is the only place that
recovers those starts — if the codec ever recorded a stop that disagreed with the bytes, this is
what would catch it. -/
private def checkProjection (source : LosslessSource) (raw : String) : IO Unit := do
  let normalized := (LosslessSource.normalize raw).1
  ensure source.structurallyValid "the compiler produced a projection that does not tile"
  ensure (source.validFor raw) "the compiler projection does not match its own source"

  let triviaHolds (kind : TriviaKind) (text : String) : Bool :=
    match kind with
    | .whitespace => text.all Char.isWhitespace
    | .lineComment => text.startsWith "--" && !(text.contains '\n')
    | .blockComment => text.startsWith "/-" && text.endsWith "-/"
  let checkTrivia (runs : Array Trivia) (start : Nat) : IO Nat := do
    let mut cursor := start
    for run in runs do
      let text := sliceOf normalized cursor run.stop
      ensure (triviaHolds run.kind text)
        s!"a trivia run classified {repr run.kind} does not contain one: {repr text}"
      cursor := run.stop
    return cursor

  let mut rebuilt := sliceOf normalized 0 source.headerStop
  let mut cursor := source.headerStop
  for token in source.tokens do
    let leadingStop ← checkTrivia token.leading cursor
    ensure (leadingStop == token.start) "leading trivia does not reach its token"
    rebuilt := rebuilt ++ sliceOf normalized cursor token.trailingStop
    cursor := token.trailingStop
    let _ ← checkTrivia token.trailing token.stop
  rebuilt := rebuilt ++ sliceOf normalized source.terminalStop source.normalizedBytes
  ensure (rebuilt == normalized) "the projection does not reconstruct its source byte-for-byte"
  -- The module linter never receives the header, so `headerStop` is the one boundary the projection
  -- asserts rather than observes. Every tracked fixture opens with `module`.
  ensure ((sliceOf normalized 0 source.headerStop).startsWith "module")
    "the recorded header is not the module header"

private unsafe def verifyPluginArtifact (moduleName : Lean.Name)
    (sourcePath : System.FilePath) (sp : Lean.SearchPath := ∅) : IO Unit := do
  Lean.enableInitializersExecution
  -- `sp` prepends the caller's workspace library: under `lake exe` the ambient `LEAN_PATH` covers
  -- it, but the compiler suite runs as a plain executable and passes its root explicitly.
  Lean.initSearchPath (← Lean.findSysroot) sp
  let environment ← Lean.importModules #[{ module := moduleName }] {}
    (trustLevel := 1024) (loadExts := true) (level := .exported)
  let source ← IO.FS.readFile sourcePath
  let some artifact := fromEnvironment? environment moduleName
    | throw <| IO.userError "module has no matching lean-fmt payload in its `.olean`"
  ensure (artifact.validFor moduleName source) "plugin payload does not match the source"
  ensure (artifact.schema == artifactSchema) "plugin emitted the wrong schema"
  ensure (artifact.syntaxData.kinds.contains `commandEmit_local_command)
    "plugin lost file-local command syntax"
  -- The fixture's `{ first, second }` parses two ways over one byte range. `checkProjection` is
  -- what proves only one alternative spells those bytes; this proves the case is not vacuous.
  ensure (artifact.syntaxData.kinds.contains Lean.choiceKind)
    "the fixture's ambiguous parse produced no choice node"
  let .ok materialized := artifact.materialize source
    | throw <| IO.userError "plugin syntax artifact did not reconstruct"
  checkProjection materialized.source source
  -- The roadmap asks for a compact representation. What grows with a file is the token and node
  -- tables, so bound their cost per element; the fixed schema strings and two digests dominate a
  -- small module and say nothing about compactness (a 34-byte module measures 29x its source and
  -- is not thereby extravagant). Derived field-name JSON measured 114 bytes per token and 54 per
  -- node on this fixture, against 28 and 13 for the array wire format.
  let encoded := (Lean.toJson artifact).compress
  let elements := artifact.syntaxData.entries.size
  ensure (encoded.utf8ByteSize < 1024 + 128 * elements)
    s!"plugin artifact is not compact: {encoded.utf8ByteSize} bytes for {elements} elements"

private def verifyFacetArtifact (path sourcePath : System.FilePath)
    (expectedHash : Lake.Hash) : IO Unit := do
  let source ← IO.FS.readFile sourcePath
  let facet : Lake.Artifact := {
    descr := Lake.artifactWithExt expectedHash "json"
    path
    mtime := 0
  }
  let some artifact ← readFacet? facet `LocalSyntax source
    | throw <| IO.userError "facet artifact failed integrity or semantic validation"
  ensure (artifact.mainModule == "LocalSyntax") "facet artifact lost module identity"
  let .ok materialized := artifact.materialize source
    | throw <| IO.userError "facet syntax artifact did not reconstruct"
  checkProjection materialized.source source

/-- The registered facet, end to end, plus the agreement the product had no test for.

`RRE-SPEC` §2 proved `check` and `format` could report different findings for one unchanged file,
because each spelled the rule configuration its own way and only one path was ever tested. The
assertion this ends on is that regression: the same file, both product paths, byte-identical
findings. It is not a tautology — the two paths reach `runRules` through different `Facts`, and the
source-only shortcut in `availableAnalysis` never touches the artifact. If a future source-tier rule
ever consults the projection, or the shortcut's `normalized` ever drifts from the artifact's, this is
what notices. -/
private def verifyOfficialFacet (root sourcePath : System.FilePath) : IO Unit := do
  let root ← IO.FS.realPath root
  let discovery ← Discovery.run root none
  let project ← Project.load root discovery #[sourcePath]
  let some target := project.targets[0]?
    | throw <| IO.userError "official-facet test did not select exactly one source"
  unless project.targets.size == 1 do
    throw <| IO.userError "official-facet test did not select exactly one source"
  let artifacts ← Application.officialArtifacts project.workspace #[target]
  let some (some artifact) := artifacts[0]?
    | throw <| IO.userError "registered official facet was unavailable or invalid"
  let some semantic := SemanticAnalysis.ofArtifact? target.source (some artifact)
    | throw <| IO.userError "registered official facet did not produce a semantic result"
  let normalized := (LosslessSource.normalize target.source).1
  let .ok materialized := artifact.materialize target.source
    | throw <| IO.userError "official syntax artifact did not reconstruct"
  -- The artifact path runs the whole registry against the projection and tags the result `.syntax`,
  -- with source-suppression directives collected from the same projection. The direct construction
  -- has to spell all three or it is comparing against a differently-shaped value — the `.syntax` tier
  -- and collected `suppression` are exactly what `ofArtifact?` attaches (`Semantic.lean`).
  ensure (semantic == SemanticAnalysis.success normalized
      (runRules (.syntax (SyntaxFacts.of normalized materialized.source)))
      (tier := .syntax) (suppression := Suppression.collect materialized.source normalized))
    "registered official facet differed from direct product semantics"
  let some artifactResult := semantic.result?
    | throw <| IO.userError "registered official facet produced no result to compare"
  -- The source-only shortcut computes `runSourceRules`; the artifact path computes the whole
  -- registry. They agree on a file only when it triggers no `syntax`-tier rule, and `LocalSyntax`
  -- carries none (no duplicate attribute/deriving, `set_option`, unclosed scope, or nested paren) —
  -- so the full-registry findings still coincide with the source-only ones here. This is the
  -- cross-path agreement `RRE-SPEC` §2 demanded; the tier tag on the cache entry, not finding
  -- equality, is what keeps the paths honest when a file *does* trigger a syntax rule.
  ensure (artifactResult.findings == runSourceRules normalized)
    "the artifact path and the source-only shortcut disagree about one unchanged file"

/- Layout cost, including the zero-width shapes that exposed the former renderer's suffix-rescan
defect. `docStepCounts` is the durable assertion; `docBench` remains a non-gating local timing probe.

Construction is deliberately outside every timed region, and every timed region forces its result: a
pure `let` in Lean is not evaluated where it is written, and an unforced `render` measures 166 ns for
any `n` — which is how this benchmark first lied. -/

/-- **The adversary.** `n` sibling groups that never spend a column and never offer a break. The old
fit walk rescanned the whole tail for each group; cached work summaries now make every decision
constant-time. -/
private def zeroWidthSiblings (n : Nat) : Doc := Id.run do
  let mut d := Doc.text "x"
  for _ in [0:n] do
    d := .cat (.group (.nest 1 .empty)) d
  return d

/-- **Adversarial nesting**: `n` zero-width groups deep, complementary to sibling width. -/
private def zeroWidthNesting (n : Nat) : Doc := Id.run do
  let mut d := Doc.text "x"
  for _ in [0:n] do
    d := .group (.nest 1 d)
  return d

/-- A Lean-shaped call, `f(a0, a1, ...)`: one group, `n` arguments, every argument carrying text. This
is the shape a real printer emits, and the difference from `zeroWidthSiblings` is only that the text is
there. -/
private def callArgs (n : Nat) : Doc := Id.run do
  let mut inner := Doc.empty
  for i in [0:n] do
    let arg := Doc.text s!"a{i}"
    inner := if i == 0 then arg else .cat inner (.cat (.text ",") (.cat (.line " ") arg))
  return .group (.cat (.text "f(") (.cat (.nest 2 (.cat (.line "") inner)) (.cat (.line "") (.text ")"))))

/-- `n` nested calls, `f(f(f(...)))` — the depth axis rather than the width axis. -/
private def nestedCalls (n : Nat) : Doc := Id.run do
  let mut d := Doc.text "x"
  for _ in [0:n] do
    d := .group (.cat (.text "f(") (.cat (.nest 2 (.cat (.line "") d)) (.cat (.line "") (.text ")"))))
  return d

/-- `callArgs` with every argument marked, which is what a real printer does: one mark per token. The
cost of `mark` is the open question `RLC-IMPL` left to this prompt. -/
private def markedCallArgs (n : Nat) : Doc := Id.run do
  let mut inner := Doc.empty
  for i in [0:n] do
    let arg := Doc.mark ⟨i, i + 1⟩ (.text s!"a{i}")
    inner := if i == 0 then arg else .cat inner (.cat (.text ",") (.cat (.line " ") arg))
  return .group (.cat (.text "f(") (.cat (.nest 2 (.cat (.line "") inner)) (.cat (.line "") (.text ")"))))

private def benchOne (label : String) (n : Nat) (d : Doc) : IO Unit := do
  -- Force construction before the clock starts, so building the fixture is not in the measurement.
  if d.size == 0 then throw (IO.userError "the fixture is empty")
  let start ← IO.monoNanosNow
  let (out, marks) := render 80 d
  -- `utf8ByteSize` is O(1) and forces the render; `String.length` would walk the output and bill the
  -- walk to the renderer.
  if out.utf8ByteSize + marks.size == 999999999 then throw (IO.userError "impossible")
  let stop ← IO.monoNanosNow
  IO.println s!"{label} n={n} nodes={d.size} ms={(Float.ofNat (stop - start)) / 1000000.0} \
out_bytes={out.utf8ByteSize} marks={marks.size}"

/-- Every generated document rendered at every margin, as text.

This exists to settle equivalence claims about the renderer by diffing two builds, rather than by
arguing that a change "should not" alter output. `results/03-acceptance.md` records the one it settled. -/
private def docDump : IO UInt32 := do
  let mut seed : Nat := 20260716
  for i in [0:400] do
    let generated := genDoc 4 seed
    seed := generated.nextSeed
    for w in [0:41] do
      IO.println s!"{i} {w} {String.intercalate "⏎" ((renderText w generated.document).splitOn "\n")}"
  return 0

/-! ## Source-security microbenchmark (`RSR-FINAL`)

The two source-security scans are linear in source size: `FMT001` is one pass over the byte array,
`FMT002` one fold over the codepoints carrying a running offset. This measures that claim the way
`docBench` measures the printer — by growth *ratio* over doubling inputs, not a wall-clock budget,
because linear and quadratic differ by the size step (here 8×) and mean the same thing on any machine.
`tests/security/bench.sh` asserts the ratios.

The measured input is scan-clean — no control or bidi byte — so the shared post-scan `qsort` over
findings (`Rules.findingOrder`), which every rule pays and is O(m log m) in the finding count m rather
than anything new to these rules, contributes nothing and the number reported is the scan cost itself.
The block carries three-byte CJK scalars so the `FMT002` fold's per-character `utf8Size` offset
arithmetic is exercised across widths, not just one-byte ASCII. A separate dense input confirms the
scans still produce findings at scale. This runs in the single test process — there is no worker, no
child, and no project setup, because a source-tier rule reads only the string it is handed. -/
private def securityCleanBlock : String :=
  -- ASCII plus four 3-byte CJK scalars, no trailing whitespace, newline-terminated so the joined
  -- input is whitespace/newline-clean and the timing is the scan alone.
  "def value : Nat := 42 -- 注释 中文\n"

/-- One control byte (NUL) and one bidi mark (U+202E), inside a string literal, per short block. -/
private def securityDenseBlock : String :=
  "def x := \"a" ++ String.ofList [Char.ofNat 0x00] ++ "b" ++ String.ofList [Char.ofNat 0x202e] ++
    "c\"\n"

/-- Grow `block` to at least `targetBytes` by doubling, so construction is O(size) — a linear join of
`k` copies would be O(size²) and would swamp the scan it is meant to feed. -/
private def repeatTo (block : String) (targetBytes : Nat) : String := Id.run do
  let mut s := block
  for _ in [0:64] do
    if s.utf8ByteSize ≥ targetBytes then break
    s := s ++ s
  return s

private def securityBenchOne (label : String) (input : String) : IO Unit := do
  if input.utf8ByteSize == 0 then throw (IO.userError "the bench input is empty")
  let start ← IO.monoNanosNow
  let findings := runSourceRules input
  -- Force the scan; a size comparison walks nothing but pins the array.
  if findings.size == 999999999 then throw (IO.userError "impossible")
  let stop ← IO.monoNanosNow
  IO.println s!"{label} bytes={input.utf8ByteSize} \
ms={(Float.ofNat (stop - start)) / 1000000.0} findings={findings.size}"

private def securityBench : IO UInt32 := do
  -- A ~2 MB scan-clean base, then exact doublings to 4/8/16 MB. Each doubling is built outside the
  -- timed region, so a ~2× step in ms across a 2× step in bytes is the linear claim.
  let mut input := repeatTo securityCleanBlock 2000000
  for label in ["clean-1x", "clean-2x", "clean-4x", "clean-8x"] do
    securityBenchOne label input
    input := input ++ input
  -- Findings do scale: a dense ~256 KB input reports two per block. This is deliberately not part of
  -- the linear assertion — its cost is dominated by the engine's shared O(m log m) finding-sort
  -- (`Rules.findingOrder`), which every rule pays and is not the scan. It proves only that the scans
  -- still fire at size, worker-free.
  securityBenchOne "dense" (repeatTo securityDenseBlock 256000)
  return 0

/-! ## Frontend-native formatter contract harness

`tests/formatter/oracle.py` owns the independent comparison. This one test-only command exposes the
already-shipped lossless header parser so the oracle compares Lean's parsed ordered imports rather
than approximating the header with a regular expression. It returns facts only; the Python harness
decides whether two signatures agree. -/

private def formatterHeader (sourcePath : String) : IO UInt32 := do
  let raw ← IO.FS.readFile sourcePath
  let normalized := (LosslessSource.normalize raw).1
  let some header ← Imports.parseHeaderModel normalized
    | do
      IO.eprintln s!"header did not parse: {sourcePath}"
      return 1
  let imports := header.imports.map fun stmt => Lean.Json.mkObj [
    ("module", .str stmt.module.toString),
    ("all", stmt.importAll),
    ("meta", stmt.isMeta),
    ("public", stmt.isPublic),
    ("exported", stmt.isExported)
  ]
  IO.println <| (Lean.Json.mkObj [
    ("module", header.hasModule),
    ("prelude", header.hasPrelude),
    ("imports", .arr imports)
  ]).compress
  return 0

private def docBench : IO UInt32 := do
  for n in [1000, 2000, 4000, 8000] do
    benchOne "zero-width-siblings" n (zeroWidthSiblings n)
  for n in [1000, 2000, 4000, 8000] do
    benchOne "zero-width-nesting" n (zeroWidthNesting n)
  for n in [1000, 10000, 100000] do
    benchOne "call-args" n (callArgs n)
  -- Capped at 10,000: `nest` is unclamped by contract (§4.6), so depth `n` at unit 2 emits Θ(n²)
  -- *bytes* — 200 MB here, and 20 GB at n=100,000. That cost is the output, not the fit test, which is
  -- why the assertion in `bench.sh` is per output byte rather than per node.
  for n in [100, 1000, 10000] do
    benchOne "nested-calls" n (nestedCalls n)
  for n in [1000, 10000, 100000] do
    benchOne "marked-call-args" n (markedCallArgs n)
  return 0

/-- Machine-independent renderer work for the adversarial and Lean-shaped documents. One custom
node is visited once and each mark adds exactly one close sentinel; no fit decision walks a suffix. -/
private def docStepCounts : IO UInt32 := do
  let report (label : String) (n : Nat) (document : Doc) : IO Unit := do
    let rendered := renderDetailed 80 document
    IO.println s!"doc-steps label={label} n={n} nodes={rendered.metrics.documentNodes} \
steps={rendered.metrics.workSteps} marks={rendered.sourceMap.size} native={rendered.metrics.nativeEvents}"
  for n in [1000, 8000] do
    report "zero-width-siblings" n (zeroWidthSiblings n)
    report "zero-width-nesting" n (zeroWidthNesting n)
    report "call-args" n (callArgs n)
    report "marked-call-args" n (markedCallArgs n)
  return 0

/-! ## Report renderer scale (`ruff-15` RRF-FINAL)

`evidence/02-renderer-cost.md` measured the six renderers at 109 findings and the append pattern in
isolation, and recorded what neither covered: `Lean.Json.pretty`, SARIF's serializer, at scale. This
is that measurement. It is synthetic on purpose — the point is to vary report size by three orders of
magnitude while holding everything else fixed, which no real project offers.

The fixture is built and forced *before* the clock starts, and so is the `PositionIndex`: both belong
to `LeanFmt.Application`, and billing them to a renderer would report the wrong thing. -/

section ReportBench
open LeanFmt.Internal.Application LeanFmt.Internal.Cli

private def benchLine : String := "theorem synthetic_placeholder : True := trivial\n"

/-- `count` findings over a synthetic file whose lines are all `benchLine`, so finding `i` sits on
line `i + 1` at a known byte offset. The codes cycle through four live rules, which is what makes the
SARIF descriptor set and its `codes.contains` scan realistic rather than singular. -/
private def benchFile (index : Nat) (count : Nat) : FileReport × String := Id.run do
  let width := benchLine.utf8ByteSize
  let codes := #["FMT001", "FMT002", "FMT008", "FMT011"]
  let mut source := ""
  let mut findings : Array Finding := #[]
  for i in [0:count] do
    source := source ++ benchLine
    findings := findings.push {
      code := codes[i % codes.size]!
      severity := if i % 3 == 0 then .error else .warning
      message := s!"synthetic finding {i} in file {index}"
      range := { start := i * width, stop := i * width + 7 }
      fix? := if i % 2 == 0 then some { applicability := .safe, edits := #[] } else none }
  return ({ path := s!"synthetic/File{index}.lean", status := "findings", findings }, source)

/-- `PositionIndex.ofSource` is a one-file constructor, because the one production caller that needs it
is the single-buffer stdin surface. A multi-file synthetic report needs the union, which `import all`
makes reachable here without widening the production interface for a benchmark. -/
private def mergePositions (index : PositionIndex) (path : String) (source : String)
    (findings : Array Finding) : PositionIndex :=
  ⟨(PositionIndex.ofSource path source findings).entries.fold
    (init := index.entries) fun acc key value => acc.insert key value⟩

private def reportBench : IO UInt32 := do
  for n in [100, 1000, 10000, 100000] do
    -- ~500 findings per file, so the file loop and the per-file work scale with the report too
    -- rather than degenerating to one enormous file.
    let perFile := 500
    let fileCount := max 1 ((n + perFile - 1) / perFile)
    let mut files : Array FileReport := #[]
    let mut positions := PositionIndex.empty
    let mut emitted := 0
    for f in [0:fileCount] do
      let count := min perFile (n - emitted)
      emitted := emitted + count
      let (file, source) := benchFile f count
      files := files.push file
      positions := mergePositions positions file.path source file.findings
    let report : RunReport := {
      mode := "check", files, findings := n, changed := 0, written := 0, broken := 0, rejected := 0,
      withheldUnsafe := 0, suppressed := 0, withheldRedundant := 0, infrastructureFailures := #[] }
    -- Force the fixture and the index before any clock starts.
    if report.files.size + positions.entries.size == 999999999 then
      throw (IO.userError "impossible")
    for format in ([.text, .concise, .json, .github, .sarif, .junit] : List ReportFormat) do
      let start ← IO.monoNanosNow
      let out := formatReport format positions "file:///synthetic/" report
      -- `utf8ByteSize` is O(1) and forces the render.
      if out.utf8ByteSize == 999999999 then throw (IO.userError "impossible")
      let stop ← IO.monoNanosNow
      IO.println s!"report-bench format={format} findings={n} files={fileCount} \
ms={(Float.ofNat (stop - start)) / 1000000.0} out_bytes={out.utf8ByteSize}"
  return 0

end ReportBench

/-- `artifact-projection`: the materialized source of a recorded artifact, as JSON. The formatter
contract suite compares this against its candidate's claim. -/
public def artifactProjection (artifactPath sourcePath : String) : IO UInt32 := do
  let .ok json := Lean.Json.parse (← IO.FS.readFile artifactPath) | return 2
  let .ok (artifact : ModuleArtifact) := Lean.fromJson? json | return 2
  let source ← IO.FS.readFile sourcePath
  let .ok materialized := artifact.materialize source | return 2
  IO.println (Lean.toJson materialized.source).compress
  return 0

/-- `print-lake-hash`: Lake's content hash of one file, so suites can pin the facet's identity
without re-deriving the hash algorithm. -/
public def printLakeHash (path : String) : IO UInt32 := do
  IO.println (← Lake.computeFileHash path (text := true))
  return 0

end LeanFmt.Test.Unit.Tools
