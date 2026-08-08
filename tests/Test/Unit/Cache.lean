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
import all Test.Unit.Fixtures

import Lean.Data.Lsp

-- Imported for its build, not its declarations: `testInterfaceHash` loads `LocalSyntax.olean`
-- at runtime, and only a real import guarantees Lake builds the plugin-built fixture before any
-- executable that runs this module — `extraDepTargets` accepted the same declaration and never
-- built it (CI on v0.2.0: fresh checkout, unit tier, "unknown module prefix 'LocalSyntax'").
import LocalSyntax

open LeanFmt LeanFmt.Internal
open LeanFmt.Test.Unit.Fixtures

namespace LeanFmt.Test.Unit.Cache

/-! ## Cache

The identity half of the result cache, exercised without a workspace: which field changes flip a
digest, what an artifact store accepts and rejects, and — in `testLakeTraceCharacterization` — what
Lake's own trace files actually contain. That last one reads this repository's build output, so it
fails when the tree's Lake traces are stale rather than when the code is wrong. -/

private def testCacheIdentity : IO Unit := do
  let base : CacheIdentity :=
    { source := Digest.ofString "source"
      toolchain := "toolchain"
      environment := Digest.ofString "environment"
      formatter := Digest.ofString "formatter"
      configuration := Digest.ofString "configuration"
      closure := Digest.ofString "closure" }
  let original := cacheIdentityDigest base
  let changes :=
    #[cacheIdentityDigest { base with source := Digest.ofString "other-source" },
      cacheIdentityDigest { base with toolchain := "other-toolchain" },
      cacheIdentityDigest { base with environment := Digest.ofString "other-environment" },
      cacheIdentityDigest { base with formatter := Digest.ofString "other-formatter" },
      cacheIdentityDigest { base with configuration := Digest.ofString "other-configuration" },
      -- The grammar a module was parsed under is an identity component, so a
      -- change in the import closure's artifacts must move the key on its own. Without this row the
      -- suite would pass under the naive fix that rekeys on nothing but the module's own bytes.
      cacheIdentityDigest { base with closure := Digest.ofString "other-closure" }]
  ensure (changes.all (· != original))
      "a semantic cache identity component did not invalidate the key"
  ensure (changes.toList.Pairwise (· != ·))
      "distinct cache identity components collided in the test fixture"

/- Characterization of the Lake module trace facts.

This test exists because the currency design rests on a reading of Lake's trace format that is not
documented and was, in the first draft, **wrong**. That draft compared `B`'s recorded
`["A transitive imports (all)", h]` against `A`'s current value. Measurement refuted that: editing `A`
so its `.olean` changed left every `"A transitive imports (all)"` entry in `A`'s own dependents
untouched, because that key hashes the closure of `A`'s *imports* and excludes `A` itself. The key
that carries `A`'s own artifacts is the sibling `["A:importAllArts", h]`.

`Lake/Build/Module.lean` `computeExportInfo` defines it as

    allArtsTrace := BuildTrace.nil "{mod.name}:importAllArts"
      |>.mix olean |>.mix oleanServer |>.mix oleanPrivate |>.mix irSig |>.mix ir

with `BuildTrace.nil`'s hash being `Hash.nil` and the caption not entering the hash. Each mixed value
is the content hash Lake also writes as the leading 16 hex digits of the corresponding entry in that
module's own `outputs`. So a dependent's recorded expectation for `A` is recomputable from `A`'s own
trace file alone — no import resolution and no closure walk.

The assertion runs over every (importer, importee) pair the build tree actually contains, so it does
not encode one hard-coded pair that a refactor would silently drop. If Lake changes the mix, its
order, or the `outputs` shape, this fails here rather than as a stale hit in the cache. -/
private structure TraceFacts where
  moduleName : String
  /-- Content hashes of this module's own artifacts, in Lake's mix order: `o…`, then `rs`, then `r`. -/
  artifactHashes : Array Lake.Hash
  /-- Recorded `"X:importAllArts"` expectations, one per direct in-workspace import. -/
  importAllArts : Array (String × Lake.Hash)
  deriving Inhabited

private def parseTraceFacts? (json : Lean.Json) : Option TraceFacts := do
  let outputs ← (json.getObjVal? "outputs").toOption
  let hashOf (value : Lean.Json) : Option Lake.Hash := do
    let text ← value.getStr?.toOption
    Lake.Hash.ofString? (text.take 16).toString
  let mut artifactHashes := #[]
  -- `o` is `[olean]` for a legacy module and `[olean, olean.server, olean.private]` under the module
  -- system; `rs`/`r` are absent in the legacy case. Folding whatever is present, in this order,
  -- reproduces both branches of `computeExportInfo`.
  if let some oleans := (outputs.getObjVal? "o").toOption then
    let some entries := oleans.getArr?.toOption | none
    for entry in entries do
      artifactHashes := artifactHashes.push (← hashOf entry)
  for key in ["rs", "r"]do
    if let some value := (outputs.getObjVal? key).toOption then
      artifactHashes := artifactHashes.push (← hashOf value)
  let some inputs := (json.getObjVal? "inputs").toOption | none
  let some inputEntries := inputs.getArr?.toOption | none
  let mut moduleName := ""
  let mut importAllArts := #[]
  for input in inputEntries do
    let some pair := input.getArr?.toOption | none
    unless pair.size == 2 do
      continue
    let some key := pair[0]!.getStr?.toOption | none
    if let some suffix := key.dropPrefix? "Module.name: " then
      moduleName := suffix.toString
    if key == "deps" then
      -- `deps` is a list of named groups; `imports` is an array of pairs when the module has
      -- in-workspace imports and the scalar nil hash when it has none. Both shapes occur in this
      -- repository (`LeanFmt.Digest` has no project import), so a consumer must tolerate both.
      let some groups := pair[1]!.getArr?.toOption | none
      for group in groups do
        let some groupPair := group.getArr?.toOption | none
        unless groupPair.size == 2 do
          continue
        unless (groupPair[0]!.getStr?.toOption) == some "imports" do
          continue
        let some recorded := groupPair[1]!.getArr?.toOption | continue
        for entry in recorded do
          let some entryPair := entry.getArr?.toOption | none
          unless entryPair.size == 2 do
            continue
          let some entryKey := entryPair[0]!.getStr?.toOption | none
          let some importee := entryKey.dropSuffix? ":importAllArts" | continue
          let some text := entryPair[1]!.getStr?.toOption | none
          let some hash := Lake.Hash.ofString? text | none
          importAllArts := importAllArts.push (importee.toString, hash)
  guard <| !moduleName.isEmpty
  return { moduleName, artifactHashes, importAllArts }

private def recomputeImportAllArts (facts : TraceFacts) : Lake.Hash :=
  facts.artifactHashes.foldl (init := Lake.Hash.nil) Lake.Hash.mix

/-- The one freshness question a trace pair can answer: did the importee's build finish after the
importer's trace was written? Lake writes a module's outputs and then its trace in the same job,
so the trace's mtime stands for the outputs'. An importee rebuilt after its importer makes the
importer's recorded `importAllArts` expectation stale — the recompute comparison would fail for
a reason that has nothing to do with Lake's trace shape. -/
private def traceNewer (importee importer : System.FilePath) : IO Bool := do
  let importeeTime := (← importee.metadata).modified
  let importerTime := (← importer.metadata).modified
  return importeeTime.sec > importerTime.sec ||
      (importeeTime.sec == importerTime.sec && importeeTime.nsec > importerTime.nsec)

/-- Characterize Lake's trace shape over every `.trace` under `root`: each importer's recorded
`importAllArts` for an in-workspace importee must reproduce from the importee's own trace
outputs, in `computeExportInfo`'s mix order.

The walk reads whatever the build tree contains — including modules no default target refreshes
(the compiler plugin, the facet extractor, suite libraries, anything ever built ad hoc). A stale
trace there is not evidence about Lake, so a pair whose importee rebuilt after its importer is
**skipped**, and only fresh pairs are asserted on. Failure comes in exactly two shapes: a fresh
pair whose mix does not reproduce (the trace shape changed — the cache's currency derivation
must change with it), or no fresh pairs at all (staleness swallowed the sample — the error names
the build that repairs it, computed from the stale importers rather than guessed). -/
public def characterizeLakeTraces (root : System.FilePath) : IO Unit := do
  let traces := (← root.walkDir).filter (·.extension == some "trace")
  let mut byName : Std.HashMap String (System.FilePath × TraceFacts) := { }
  for path in traces do
    let contents ← IO.FS.readFile path
    let .ok json := Lean.Json.parse contents | continue
    let some facts := parseTraceFacts? json | continue
    byName := byName.insert facts.moduleName (path, facts)
  ensure (byName.size > 1)
      "no module traces parsed; the Lake trace shape the cache consumes may have changed"
  let mut checked := 0
  let mut staleImporters : Array String := #[]
  for (_, (importerPath, importer)) in byName do
    for (importee, recorded) in importer.importAllArts do
      -- Only in-workspace modules get a trace here; toolchain imports (`Lake.*`, `Lean.*`) are absent
      -- from `deps.imports` entirely and are covered by the separate `"Lean <version>, commit …"`
      -- input instead. That absence is itself part of what this pins down.
      let some (importeePath, importeeFacts) := byName[importee]? | continue
      ensure (!importeeFacts.artifactHashes.isEmpty)
          s!"{importee} recorded no artifact hashes in its own trace outputs"
      if ← traceNewer importeePath importerPath then
        unless staleImporters.contains importer.moduleName do
          staleImporters := staleImporters.push importer.moduleName
        continue
      ensure (recomputeImportAllArts importeeFacts == recorded)
          s!"Lake's importAllArts mix no longer reproduces from the importee's own trace outputs: \
          {importer.moduleName} records {recorded} for {importee}, recomputed \
          {recomputeImportAllArts importeeFacts}. The importee's trace predates the importer's, \
          so this is not staleness: the trace shape changed, and the cache's currency derivation \
          must change with it."
      checked := checked + 1
  unless checked > 0 do
    let targets := " ".intercalate (staleImporters.qsort (· < ·)).toList
    throw <|
        IO.userError
          s!"no fresh (importer, importee) trace pairs under {root}: every pair's \
      importee rebuilt after its importer. Run `lake build {targets}` and retry — rebuilding the \
      importers refreshes their recorded expectations."

private def testLakeTraceCharacterization : IO Unit := do
  let root : System.FilePath := ".lake" / "build" / "lib" / "lean"
  unless ← root.isDir do
    throw <|
        IO.userError
          s!"characterization needs a built tree; run `lake build` from the repository \
      root before `lake exe lean-fmt-tests` (missing {root})"
  characterizeLakeTraces root

/-- An unresolved closure and an empty one are different answers, and currency must not confuse
them.

`Project.graph` returns the honest `Option`, and its two consumers degrade it in opposite
directions: FMT004 takes `.getD #[]`, because losing a closure there loses at most one report-only
redundancy; currency keeps the `none` and misses, because an empty closure reads as "nothing to
check" — a *permissive* answer, and a stale hit is the one direction currency must never degrade
toward. Two producers used to enforce that by existing separately; one producer plus this case is
the stronger statement, because a future caller now has to write `.getD #[]` where a reviewer sees
it.

Nothing pinned this before. Folding `none` to `#[]` inside `closureDigest?` passes every other
cache case in this file.

The fold walks edges now, so the unresolved closure is a module the edge map does not mention and
the empty one is a module it maps to no imports. -/
private def testClosureDegradationDirection : IO Unit := do
  let memo ← IO.mkRef ({ } : Std.HashMap String MemberFact)
  let nodes ← IO.mkRef ({ } : Std.HashMap Lean.Name (Option Digest))
  let workspace ← Project.loadWorkspace (← IO.currentDir)
  let name := `LeanFmt.Digest
  let unresolved ← closureDigest? workspace .artifacts memo nodes { } name
  ensure unresolved.isNone
      "an unresolved import closure produced a digest; currency would hit on unknown grammar"
  let nodes ← IO.mkRef ({ } : Std.HashMap Lean.Name (Option Digest))
  let empty ←
    closureDigest? workspace .artifacts memo nodes
        (Std.HashMap.emptyWithCapacity 1 |>.insert name #[]) name
  ensure empty.isSome
      "an empty import closure produced no digest; a module importing nothing cannot be cached"

private def testStore : IO Unit := do
  let artifact := fixtureArtifact
  ensure (structurallyValid artifact) "valid module artifact was rejected"
  ensure (!(structurallyValid { artifact with schema := "other-schema" }))
      "schema change did not reject the artifact"
  -- A `v1` payload left in an `.olean` describes the superseded command-kind projection.
  ensure (!(structurallyValid { artifact with schema := "lean-fmt.module-artifact.v1" }))
      "a stale v1 artifact was accepted by the current reader"
  -- An artifact is now nothing but its schema and its projection, so this is the only remaining way
  -- for one to be structurally wrong. The check that used to live here bounded every finding's range
  -- by `normalizedBytes`; there are no findings to bound.
  ensure
      (!(structurallyValid
          { artifact with
            syntaxData :=
              { artifact.syntaxData with terminal := artifact.syntaxData.entries.size + 1 } }))
      "an artifact whose projection is itself invalid was accepted"
  ensure (!(artifact.validFor `Other fixtureSourceText)) "a wrong-module artifact was accepted"
  ensure (!(artifact.validFor `Test "other source")) "a wrong-source artifact was accepted"
  ensure (artifact.validFor `Test fixtureSourceText) "a valid artifact was rejected for its source"
  let decoded : Except String ModuleArtifact := Lean.fromJson? (Lean.toJson artifact)
  match decoded with
  | .ok actual =>
    ensure (actual == artifact) "module-artifact JSON round trip failed"
  | .error message =>
    throw <| IO.userError s!"module-artifact JSON decode failed: {message}"
  let directory ← IO.FS.createTempDir
  let path := directory / "nested" / "Test.json"
  try
    writeArtifactAtomic path artifact
    let hash ← Lake.computeFileHash path (text := true)
    let facet : Lake.Artifact :=
      { descr := Lake.artifactWithExt hash "json"
        path
        mtime := 0 }
    ensure ((← readFacet? facet `Test fixtureSourceText) == some artifact)
        "trusted facet artifact round trip failed"
    ensure (← readFacet? facet `Test "other source").isNone
        "source mismatch did not reject the facet artifact"
    ensure (← readFacet? facet `Other fixtureSourceText).isNone
        "module mismatch did not reject the facet artifact"
    IO.FS.writeFile path (Lean.toJson { artifact with schema := "other-schema" }).compress
    ensure (← readFacet? facet `Test fixtureSourceText).isNone
        "tampered facet artifact did not fail its content hash"
    writeArtifactAtomic path artifact
    IO.FS.writeFile (directory / "nested" / "Test.json.tmp-interrupted") "partial"
    ensure ((← readFacet? facet `Test fixtureSourceText) == some artifact)
        "an interrupted temporary write damaged the committed artifact"
    IO.FS.removeFile path
    ensure (← readFacet? facet `Test fixtureSourceText).isNone
        "missing facet artifact was not an ordinary miss"
  finally
    IO.FS.removeDirAll directory

/-- The merge that makes cache writes monotone: which capability combinations survive a rewrite
under one identity key, and the broken/unbuilt boundary of what may be stored at all. -/
private def testMergeAnalysis : IO Unit := do
  let canonical : CanonicalLayout := default
  let withCanonical (analysis : SemanticAnalysis) : SemanticAnalysis :=
    { analysis with
      result? := analysis.result?.map fun result => { result with canonical? := some canonical } }
  let rich := withCanonical (SemanticAnalysis.success "src" #[] .semantic { } ⟨true⟩)
  let poor := SemanticAnalysis.success "src" #[] .«syntax»
  let broken : SemanticAnalysis := { result? := none, diagnostics := #["elaboration failed"] }
  let provided (analysis : SemanticAnalysis) : Cache.Decision.Provided := providedOf analysis
  -- A poorer rewrite of the same bytes keeps the richer entry's capabilities, in both orders.
  for merged in [mergeAnalysis rich poor, mergeAnalysis poor rich]do
    ensure (provided merged == .success .semantic ⟨true⟩ true)
        "poorer rewrite displaced a capability the richer entry carried"
  -- Canonical text grafts onto a fresh analysis that did not render it.
  let rendered := withCanonical poor
  let merged := mergeAnalysis rendered poor
  ensure ((merged.result?.map (·.canonical?.isSome)) == some true)
      "canonical text did not graft onto the fresher analysis"
  ensure (provided merged == .success .«syntax» { } true) "graft changed the entry's tier or caps"
  -- Broken records never displace a success; a success always displaces a broken record.
  ensure (provided (mergeAnalysis poor broken) == provided poor)
      "a broken record displaced a success"
  ensure (provided (mergeAnalysis broken poor) == provided poor)
      "a success did not displace a broken record"
  ensure ((mergeAnalysis broken broken).result?.isNone) "two broken records did not stay broken"
  -- The incomparable-pair escape hatch keeps the fresher analysis (degrades to a miss, never a
  -- stale claim): semantic-without-occurrences vs syntax-with-occurrences.
  let highTier := SemanticAnalysis.success "src" #[] .semantic
  let highCaps := SemanticAnalysis.success "src" #[] .«syntax» { } ⟨true⟩
  ensure (provided (mergeAnalysis highTier highCaps) == .success .«syntax» ⟨true⟩ false)
      "incomparable merge did not keep the fresher analysis"
  -- Unbuilt outcomes are never stored; broken and successful ones are.
  let unbuilt : SemanticAnalysis :=
    { result? := none
      diagnostics :=
        #["Mathlib/Foo.lean:1:0: error: failed to open file 'Mathlib.Foo.olean': No such file or directory"] }
  ensure (!storableAnalysis unbuilt) "an unbuilt outcome was storable"
  ensure (storableAnalysis broken) "a broken outcome was not storable"
  ensure (storableAnalysis poor) "a successful outcome was not storable"

/-- The live set and the organizer compute candidates with one definition: a rejection verdict's
key stays live exactly while the on-disk header still organizes to the stored candidate. -/
private def testOrganizeCandidateAgreement : IO Unit := do
  let disordered := "module\n\nimport B\nimport A\n\ndef x := 1\n"
  let canonical := "module\n\nimport A\nimport B\n\ndef x := 1\n"
  ensure ((← Imports.organizeCandidate? disordered) == some canonical)
      "organizeCandidate? disagreed with the organizer on a disordered header"
  ensure ((← Imports.organizeCandidate? canonical) == none)
      "organizeCandidate? rewrote a canonical header"
  ensure ((← Imports.organizeCandidate? "def x := 1\n").isNone)
      "organizeCandidate? rewrote a headerless source"

/-- The interface-hash inputs of `[cache] closure = "interface"`: deterministic over one
environment, and absent — never degenerate — for a module the environment does not index. The
facet artifact's carried value is the direct computation over the same environment, so the
sidecar and the extractor cannot drift apart. `LocalSyntax` is the integration library the
compiler suite builds with the plugin, so its `.olean` is on this binary's search path under
`lake exe`. -/
private unsafe def testInterfaceHash : IO Unit := do
  Lean.enableInitializersExecution
  Lean.initSearchPath (← Lean.findSysroot)
  let environment ←
    Lean.importModules #[{ module := `LocalSyntax }] { } (trustLevel := 1024) (loadExts := true)
        (level := .exported)
  let some first :=
    moduleInterfaceHash? environment
      `LocalSyntax | throw <| IO.userError "an integrated module's interface hash was not computed"
  ensure (moduleInterfaceHash? environment `LocalSyntax == some first)
      "interface hash was not deterministic over one environment"
  ensure (moduleInterfaceHash? environment `No.Such.Module).isNone
      "an unindexed module produced an interface hash"
  let some artifact :=
    fromEnvironment? environment
      `LocalSyntax | throw <| IO.userError "module has no matching lean-fmt payload in its `.olean`"
  ensure (artifact.interfaceHash == some first)
      "the facet artifact's interface hash disagrees with the direct computation"

/-- The cases this module contributes to the unit runner, in run order. -/
public def cases : Array Case :=
  #[{ name := "testCacheIdentity", run := testCacheIdentity },
    { name := "testLakeTraceCharacterization", run := testLakeTraceCharacterization },
    { name := "testClosureDegradationDirection", run := testClosureDegradationDirection },
    { name := "testStore", run := testStore },
    { name := "testMergeAnalysis", run := testMergeAnalysis },
    { name := "testOrganizeCandidateAgreement", run := testOrganizeCandidateAgreement },
    { name := "testInterfaceHash", run := unsafe testInterfaceHash }]

end LeanFmt.Test.Unit.Cache
