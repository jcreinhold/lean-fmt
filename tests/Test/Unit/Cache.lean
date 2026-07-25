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

open LeanFmt LeanFmt.Internal

open LeanFmt.Test.Unit.Fixtures

namespace LeanFmt.Test.Unit.Cache

private def testCacheIdentity : IO Unit := do
  let base : CacheIdentity := {
    source := Digest.ofString "source"
    toolchain := "toolchain"
    environment := Digest.ofString "environment"
    formatter := Digest.ofString "formatter"
    configuration := Digest.ofString "configuration"
    closure := Digest.ofString "closure"
  }
  let original := cacheIdentityDigest base
  let changes := #[
    cacheIdentityDigest { base with source := Digest.ofString "other-source" },
    cacheIdentityDigest { base with toolchain := "other-toolchain" },
    cacheIdentityDigest { base with environment := Digest.ofString "other-environment" },
    cacheIdentityDigest { base with formatter := Digest.ofString "other-formatter" },
    cacheIdentityDigest { base with configuration := Digest.ofString "other-configuration" },
    -- `ruff-16b` `RCI-IMPL`: the grammar a module was parsed under is an identity component, so a
    -- change in the import closure's artifacts must move the key on its own. Without this row the
    -- suite would pass under the naive fix that rekeys on nothing but the module's own bytes.
    cacheIdentityDigest { base with closure := Digest.ofString "other-closure" }
  ]
  ensure (changes.all (· != original))
    "a semantic cache identity component did not invalidate the key"
  ensure (changes.toList.Pairwise (· != ·))
    "distinct cache identity components collided in the test fixture"

/- Characterization of the Lake module trace facts `ruff-16b` `RCI-IMPL` will consume.

This test exists because the currency design rests on a reading of Lake's trace format that is not
documented and was, in this stack's first draft, **wrong**. The roadmap and
`notes/01-what-is-provable.md` both described the check as comparing `B`'s recorded
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
trace file alone — no import resolution and no closure walk, which is what this stack's stop rules
forbid.

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
  for key in ["rs", "r"] do
    if let some value := (outputs.getObjVal? key).toOption then
      artifactHashes := artifactHashes.push (← hashOf value)
  let some inputs := (json.getObjVal? "inputs").toOption | none
  let some inputEntries := inputs.getArr?.toOption | none
  let mut moduleName := ""
  let mut importAllArts := #[]
  for input in inputEntries do
    let some pair := input.getArr?.toOption | none
    unless pair.size == 2 do continue
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
        unless groupPair.size == 2 do continue
        unless (groupPair[0]!.getStr?.toOption) == some "imports" do continue
        let some recorded := groupPair[1]!.getArr?.toOption | continue
        for entry in recorded do
          let some entryPair := entry.getArr?.toOption | none
          unless entryPair.size == 2 do continue
          let some entryKey := entryPair[0]!.getStr?.toOption | none
          let some importee := entryKey.dropSuffix? ":importAllArts" | continue
          let some text := entryPair[1]!.getStr?.toOption | none
          let some hash := Lake.Hash.ofString? text | none
          importAllArts := importAllArts.push (importee.toString, hash)
  guard <| !moduleName.isEmpty
  return { moduleName, artifactHashes, importAllArts }

private def recomputeImportAllArts (facts : TraceFacts) : Lake.Hash :=
  facts.artifactHashes.foldl (init := Lake.Hash.nil) Lake.Hash.mix

private def testLakeTraceCharacterization : IO Unit := do
  let root : System.FilePath := ".lake" / "build" / "lib" / "lean"
  unless ← root.isDir do
    throw <| IO.userError s!"characterization needs a built tree; run `lake build` from the repository \
      root before `lake exe lean-fmt-tests` (missing {root})"
  let traces := (← root.walkDir).filter (·.extension == some "trace")
  let mut byName : Std.HashMap String TraceFacts := {}
  for path in traces do
    let contents ← IO.FS.readFile path
    let .ok json := Lean.Json.parse contents | continue
    let some facts := parseTraceFacts? json | continue
    byName := byName.insert facts.moduleName facts
  ensure (byName.size > 1)
    "no module traces parsed; the Lake trace shape this stack consumes may have changed"
  let mut checked := 0
  for (_, importer) in byName do
    for (importee, recorded) in importer.importAllArts do
      -- Only in-workspace modules get a trace here; toolchain imports (`Lake.*`, `Lean.*`) are absent
      -- from `deps.imports` entirely and are covered by the separate `"Lean <version>, commit …"`
      -- input instead. That absence is itself part of what this test pins down.
      let some importeeFacts := byName[importee]? | continue
      ensure (!importeeFacts.artifactHashes.isEmpty)
        s!"{importee} recorded no artifact hashes in its own trace outputs"
      ensure (recomputeImportAllArts importeeFacts == recorded)
        s!"Lake's importAllArts mix no longer reproduces from the importee's own trace outputs: \
          {importer.moduleName} records {recorded} for {importee}, recomputed \
          {recomputeImportAllArts importeeFacts}. A **stale trace** says this too: `lake build` \
          skips non-default targets, so editing a module that `check-modules` imports leaves its \
          old trace on disk and this walk reads it. Run `lake build check-modules` and retry before \
          concluding Lake's trace shape changed."
      checked := checked + 1
  ensure (checked > 0)
    "no (importer, importee) pair was checked; the deps.imports shape may have changed"

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
  ensure (!(structurallyValid { artifact with
      syntaxData := { artifact.syntaxData with terminal := artifact.syntaxData.entries.size + 1 } }))
    "an artifact whose projection is itself invalid was accepted"
  ensure (!(artifact.validFor `Other fixtureSourceText)) "a wrong-module artifact was accepted"
  ensure (!(artifact.validFor `Test "other source")) "a wrong-source artifact was accepted"
  ensure (artifact.validFor `Test fixtureSourceText) "a valid artifact was rejected for its source"
  let decoded : Except String ModuleArtifact := Lean.fromJson? (Lean.toJson artifact)
  match decoded with
  | .ok actual => ensure (actual == artifact) "module-artifact JSON round trip failed"
  | .error message => throw <| IO.userError s!"module-artifact JSON decode failed: {message}"
  let directory ← IO.FS.createTempDir
  let path := directory / "nested" / "Test.json"
  try
    writeArtifactAtomic path artifact
    let hash ← Lake.computeFileHash path (text := true)
    let facet : Lake.Artifact := {
      descr := Lake.artifactWithExt hash "json"
      path
      mtime := 0
    }
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

/-- The cases this module contributes to the unit runner, in run order. -/
public def cases : Array Case := #[
  { name := "testCacheIdentity", run := testCacheIdentity },
  { name := "testLakeTraceCharacterization", run := testLakeTraceCharacterization },
  { name := "testStore", run := testStore }]

end LeanFmt.Test.Unit.Cache
