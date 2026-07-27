/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.Cache.Decision
import all LeanFmt.Profile
import all LeanFmt.Project
import all LeanFmt.Semantic

import Lake.Build.Trace
import Lake.Config.Workspace

namespace LeanFmt.Internal

open LeanFmt.Internal.Profile

private structure TraceOutputs where
  o : Array String
  /-- `ir.sig` and `ir` content hashes. Optional because a legacy (non-module-system) module
  has neither, and `computeExportInfo`'s legacy branch mixes only the `.olean`. -/
  rs : Option String := none
  r : Option String := none
  deriving Lean.FromJson

private structure OleanTrace where
  schemaVersion : String
  outputs : TraceOutputs
  deriving Lean.FromJson

private structure FileTrace where
  schemaVersion : String
  outputs : String
  deriving Lean.FromJson

structure CacheIdentity where
  source : Digest
  toolchain : String
  environment : Digest
  formatter : Digest
  configuration : Digest
  /-- Currency of the grammar this module's artifact was produced under.

  `source` covers the module's own bytes. This covers the other half of what a cached analysis
  depends on: Lean's grammar is open, so a `notation` in `A` changes how `B`'s unchanged bytes
  parse, and `B`'s stored projection then describes a tree those bytes no longer denote.

  It is per entry, not per epoch. Folding every project source into `environment` used to cover it,
  far too coarsely: `environment` names the index file, so any edit invalidated the whole project
  and no entry hit. -/
  closure : Digest
  deriving BEq, Lean.ToJson, Lean.FromJson

private structure CacheEntry where
  schema : String
  identity : Digest
  payload : Digest
  /-- The module's own source digest, recorded separately from the bundled `identity`.

  `identity` is the index key: one digest over every identity field, which makes lookup a hash
  probe instead of a scan. It is not the decision. `sourceDigest` and `closureDigest` are here so
  the accept can call `Cache.Decision.Entry.identityCurrent`, the function `LeanFmt.Cache.Spec`
  proves about, rather than a bundled comparison that only stands for it under A1. -/
  sourceDigest : Digest
  /-- The grammar-currency digest of the module's import closure. See `sourceDigest`. -/
  closureDigest : Digest
  analysis : SemanticAnalysis
  deriving Lean.ToJson, Lean.FromJson

/-- What an entry's analysis can answer, in the shared decision's vocabulary.

Derived from the analysis rather than stored beside it: a stored copy could disagree with
the analysis it describes, and that disagreement is a stale hit. One source of truth per entry. -/
def providedOf (analysis : SemanticAnalysis) : Cache.Decision.Provided :=
  match analysis.result? with
  | none => .broken
  | some result =>
    .success result.tier result.caps result.canonical?.isSome

private structure CacheIndex where
  schema : String
  base : Digest
  entries : Array CacheEntry
  deriving Lean.ToJson, Lean.FromJson

/-- What one closure member's compiled output turned out to be.

The distinction `unbuilt` draws from `unreadable` is the whole point. A module Lake knows
about but has never built has no `.olean` in any form and no trace: it contributed no grammar to
anything, so it is a *fact* about the closure and belongs in the digest as one. A module whose
output exists but whose trace is absent, unparseable, or of an unrecognized schema is an *unknown*,
and which way an unknown degrades is settled — toward a miss, never a hit. -/
private inductive MemberFact where
  /-- The module's recomputed `importAllArts`. -/
  | hash (value : Lake.Hash)
  /-- No compiled output of any form on disk. -/
  | unbuilt
  /-- Output may exist; currency cannot be recomputed from it. -/
  | unreadable
  deriving Inhabited

structure ResultCache where
  private mk ::
  root : System.FilePath
  toolchain : String
  environment : Digest
  formatter : Digest
  directoryReady : IO.Ref Bool
  loadedEntries : IO.Ref (Option (Std.HashMap String CacheEntry))
  /-- Memoized conservative currency for standalone (non-workspace-module) targets: the digest
  of every artifact in the workspace's own build directory. Computed at most once per run. -/
  workspaceArtifacts : IO.Ref (Option (Option Digest))
  /-- Memoized per-module closure digests, keyed by module name.

  `readAll` and `writeAll` both need them, and resolving a closure means a no-build Lake graph
  fetch. Without this the same batch would fetch twice per run. Memoizing per *name* rather than
  per batch keeps it correct when the two calls are handed different target arrays. -/
  closureDigestsByModule : IO.Ref (Std.HashMap String (Option Digest))
  /-- Memoized `importAllArts` per module, keyed by module name.

  A closure digest reads one trace file per closure member, and closures overlap almost completely
  on a real project, so without this the same trace is read and parsed once for every module that
  transitively imports it. On mathlib modules with closures of thousands of members, those re-reads
  took nearly all of a warm run.

  Memoizing per run, not per batch, is the scope `closureDigestsByModule` already takes: a trace
  changing mid-run is A2 (observation faithfulness), a named hypothesis and false in general either
  way. -/
  artifactHashByModule : IO.Ref (Std.HashMap String MemberFact)

def resultCacheSchema : String := "lean-fmt.result-cache.v4"

private def digestParts (parts : Array String) : Digest :=
  Digest.ofString (String.intercalate "\u0000" parts.toList)

def cacheIdentityDigest (identity : CacheIdentity) : Digest :=
  digestParts #[resultCacheSchema, (Lean.toJson identity).compress]

private def outputPath? (olean : System.FilePath) (token : String) : Option System.FilePath := do
  guard <| token.length > 16
  let base ← olean.toString.dropSuffix? ".olean"
  return System.FilePath.mk (base.toString ++ (token.drop 16).toString)

private def validateOleanTrace? (root olean : System.FilePath) : IO (Option String) := do
  try
    let tracePath := olean.withExtension "trace"
    let contents ← IO.FS.readFile tracePath
    let .ok json := Lean.Json.parse contents
      | return none
    let .ok (trace : OleanTrace) := Lean.fromJson? json
      | return none
    unless trace.schemaVersion == "2025-09-10" && !trace.outputs.o.isEmpty do
      return none
    for token in trace.outputs.o do
      let some output := outputPath? olean token
        | return none
      unless ← output.pathExists do
        return none
      let actual ← Lake.computeFileHash output
      unless toString actual == (token.take 16).toString do
        return none
    let relative := Lake.relPathFrom root tracePath |>.toString
    return some s!"{relative}\u0000{Digest.ofString contents}"
  catch _ =>
    return none

private def rootTraceParts? (root : System.FilePath) : IO (Option (Array String)) := do
  unless ← root.isDir do
    return none
  let oleans := (← root.walkDir).filter (·.extension == some "olean")
    |>.qsort (·.toString < ·.toString)
  let mut parts := #[s!"root\u0000{← IO.FS.realPath root}"]
  for olean in oleans do
    let some part ← validateOleanTrace? root olean
      | return none
    parts := parts.push part
  return some parts

private def validateSharedTrace? (root library : System.FilePath) : IO (Option String) := do
  try
    let tracePath := library.addExtension "trace"
    let contents ← IO.FS.readFile tracePath
    let .ok json := Lean.Json.parse contents
      | return none
    let .ok (trace : FileTrace) := Lean.fromJson? json
      | return none
    unless trace.schemaVersion == "2025-09-10" && trace.outputs.length > 16 do
      return none
    let expected := (trace.outputs.take 16).toString
    unless toString (← Lake.computeFileHash library) == expected do
      return none
    let relative := Lake.relPathFrom root tracePath |>.toString
    return some s!"shared\u0000{relative}\u0000{Digest.ofString contents}"
  catch _ =>
    return none

private def sharedTraceParts? (root : System.FilePath) : IO (Option (Array String)) := do
  unless ← root.isDir do
    return none
  let libraries := (← root.walkDir).filter (·.extension == some Lake.sharedLibExt)
    |>.qsort (·.toString < ·.toString)
  let mut parts := #[s!"shared-root\u0000{← IO.FS.realPath root}"]
  for library in libraries do
    let some part ← validateSharedTrace? root library
      | return none
    parts := parts.push part
  return some parts

private def pathParts (label : String) (paths : List System.FilePath) : Array String :=
  paths.toArray.mapIdx fun index path => s!"{label}\u0000{index}\u0000{path}"

private def insideToolchain (toolchain path : System.FilePath) : Bool :=
  path == toolchain || path.toString.startsWith
    (toolchain.toString ++ System.FilePath.pathSeparator.toString)

/- ## Per-module currency

What used to be here was `sourceRootParts?`: a walk of every non-`.lake` `.lean` file under
every source root, digesting each one's bytes into `environment`. `environment` feeds `baseDigest`,
and `baseDigest` names the index file, so editing any one source renamed the index and orphaned
every entry in it. Measured on this repository: after appending one comment to one file, no entry
hit, and a second index file appeared that nothing ever collected.

It was standing in for a check nobody had written. `validateOleanTrace?` proves an artifact is
**intact** — its recorded outputs exist and hash to their content-addressed names — never that it
is **current**. The whole-project walk was the crude substitute: invalidate everything whenever
anything changes.

The replacement is exact and per entry. For a module `X`, Lake's `computeExportInfo` defines

    X:importAllArts = Hash.nil |>.mix olean |>.mix oleanServer |>.mix oleanPrivate
                              |>.mix irSig |>.mix ir

and each mixed value is the content hash Lake writes as the leading 16 hex digits of the
corresponding entry in `X`'s own `outputs`. So the value a dependent recorded for `X` is
recomputable from `X`'s own trace file — no import resolution and no closure walk belong in this
layer. `testLakeTraceCharacterization` pins that identity across every
(importer, importee) pair in the built tree, mutation-checked.

**Do not "simplify" this to `X transitive imports (all)`.** That key hashes the closure of `X`'s
imports and excludes `X` itself. It was tried and measurement refuted it: reading it would pass on
the stale grammar case the check exists to catch. -/

/-- Recompute Lake's `importAllArts` for one module from its own recorded trace outputs.

Order matters and matches `computeExportInfo`: the `o` array (olean, olean.server, olean.private),
then `rs`, then `r`. A legacy non-module-system module has `o = [olean]` and no `rs`/`r`, which
folds correctly under the same loop. -/
private def moduleArtifactHash? (tracePath : System.FilePath) : IO (Option Lake.Hash) := do
  try
    let contents ← IO.FS.readFile tracePath
    let .ok json := Lean.Json.parse contents
      | return none
    let .ok (trace : OleanTrace) := Lean.fromJson? json
      | return none
    unless trace.schemaVersion == "2025-09-10" && !trace.outputs.o.isEmpty do
      return none
    let mut tokens := trace.outputs.o
    for extra in [trace.outputs.rs, trace.outputs.r] do
      if let some token := extra then
        tokens := tokens.push token
    let mut hash := Lake.Hash.nil
    for token in tokens do
      let some component := Lake.Hash.ofString? (token.take 16).toString
        | return none
      hash := hash.mix component
    return some hash
  catch _ =>
    return none

/-- What Lake's recorded outputs say about one closure member.

`unreadable` is the degradation an unknown takes; `unbuilt` is not a degradation at all
but a fact, and the difference is worth a filesystem check. On mathlib, one unbuilt module in a
62-file batch used to send every closure through the whole-workspace fallback digest: 7,018 ms, 30%
of a cold `check`. -/
private def memberFact (workspace : Lake.Workspace) (name : Lean.Name) : IO MemberFact := do
  let some tracePath := Project.moduleTracePath? workspace name
    | return .unreadable
  if let some hash ← moduleArtifactHash? tracePath then
    return .hash hash
  -- The trace did not yield a hash. Absence of *every* output Lake would write is the one
  -- case that is a fact rather than an unknown, and it is checked here rather than inferred from
  -- the trace alone: an `.olean` sitting next to a missing trace is output whose currency is
  -- unknown.
  let some outputs := Project.moduleOutputPaths? workspace name
    | return .unreadable
  for output in outputs do
    if ← output.pathExists then
      return .unreadable
  return .unbuilt

/-- The grammar-currency digest for one target: its transitive import closure, each member paired
with its module artifacts as they are on disk **right now**.

`none` — meaning the entry misses — whenever currency cannot be established: the closure could
not be resolved, a member is not a workspace module, or a member's trace is absent, unparseable, or
of an unrecognized schema. This direction is fixed: currency that cannot be determined
degrades to a miss, never to a hit, and such an entry is not written either, since a placeholder
value would be indistinguishable from a real one on the next run.

This degrades **one entry**, not the cache, which is finer than `environmentDigest?`. That one
disables everything when it returns `none`, correctly, because it reports a property of the epoch
rather than of an entry. -/
private def closureDigest? (workspace : Lake.Workspace)
    (memo : IO.Ref (Std.HashMap String MemberFact))
    (closure : Option (Array Lean.Name)) : IO (Option Digest) := do
  let some members := closure
    | return none
  let ordered := members.qsort (·.toString < ·.toString)
  let mut parts := #[]
  for name in ordered do
    let key := name.toString
    let fact ← do
      if let some hit := (← memo.get)[key]? then
        pure hit
      else
        let computed ← memberFact workspace name
        memo.modify (·.insert key computed)
        pure computed
    match fact with
    | .hash hash => parts := parts.push s!"closure {name} {hash}"
    | .unbuilt => parts := parts.push s!"closure {name} unbuilt"
    | .unreadable => return none
  return some (digestParts parts)

/-- `realPath` for a configured search-path root that may not exist.

Lake puts a directory on the search path whether or not anything has built there yet, so an
absent root is ordinary rather than suspicious. `IO.FS.realPath` throws on one, and that exception
used to escape this function into `ResultCache.open?`'s catch-all and disable the cache for the
**whole project** — silently, since a disabled cache is a supported outcome. Measured on mathlib:
one absent root, and not a single entry was ever written.

Absence is recorded as its own part rather than skipped, so that the root later appearing with
artifacts moves `environment`. This does not weaken `open?`'s refusal to manufacture a partial
epoch: a directory that does not exist holds no artifacts to be partial about, and a root that
exists but whose artifacts do not validate still returns `none` for the whole cache. -/
private def realPathIfDir? (path : System.FilePath) : IO (Option System.FilePath) := do
  try
    unless ← path.isDir do
      return none
    return some (← IO.FS.realPath path)
  catch _ =>
    return none

private def environmentDigest? (workspace : Lake.Workspace) : IO (Option Digest) := do
  let toolchain ← IO.FS.realPath workspace.lakeEnv.lean.sysroot
  let roots := workspace.augmentedLeanPath
  let mut parts := #[
    s!"lean-version\u0000{Lean.versionString}",
    s!"lean-githash\u0000{workspace.lakeEnv.lean.githash}",
    s!"workspace-configuration\u0000{Project.externalConfigurationIdentity workspace}"
  ]
  parts := parts ++ pathParts "lean-path" workspace.augmentedLeanPath
  parts := parts ++ pathParts "source-path" workspace.augmentedLeanSrcPath
  parts := parts ++ pathParts "shared-path" workspace.augmentedSharedLibPath
  parts := parts ++ pathParts "binary-path" workspace.augmentedPath
  -- The workspace's own build directory is skipped here and covered per entry by
  -- `CacheIdentity.closure` instead. It was the *second* whole-project invalidator:
  -- `rootTraceParts?` folds every `.olean`'s trace contents into `environment`, `environment`
  -- names the index file, so rebuilding any one module renamed the index and orphaned every entry
  -- — the same defect as the project-source walk, one layer down, and removing only the source
  -- walk would not have fixed it.
  --
  -- Dependency package roots keep the coverage they had. Coverage here is scoped to project
  -- sources, and a dependency's artifacts are an epoch property: they
  -- change when the manifest or a dependency build changes, not when the user edits their own
  -- file.
  let ownLibDir ← try IO.FS.realPath workspace.root.leanLibDir catch _ => pure workspace.root.leanLibDir
  for rawRoot in roots do
    let some root ← realPathIfDir? rawRoot
      | parts := parts.push s!"lean-path-absent\u0000{rawRoot}"
        continue
    if insideToolchain toolchain root || root == ownLibDir then
      continue
    let some rootParts ← rootTraceParts? root
      | return none
    parts := parts ++ rootParts
  for rawRoot in workspace.augmentedSharedLibPath do
    let some root ← realPathIfDir? rawRoot
      | parts := parts.push s!"shared-path-absent\u0000{rawRoot}"
        continue
    if insideToolchain toolchain root then
      continue
    let some rootParts ← sharedTraceParts? root
      | return none
    parts := parts ++ rootParts
  -- Project source *content* deliberately does not appear here. `environment` names the
  -- index file through `baseDigest`, so folding project sources in made one edit rename the index
  -- and orphan every entry. Project-source currency is per entry now, in
  -- `CacheIdentity.closure`. The ordered *paths* above stay: search-path precedence is an epoch
  -- property and changing it changes what every module resolves to.
  return some (digestParts parts)

/-- The per-target key. `closure` is supplied by the caller rather than computed here because
it comes from one shared no-build Lake graph fetched once for the whole batch; computing it per
target would mean one graph build per file, which `LeanFmt.Project` exists to prevent. -/
private def identity (cache : ResultCache) (project : Project.Snapshot)
    (target : Project.SourceTarget) (closure : Digest) : IO CacheIdentity := do
  return {
    source := Digest.ofString target.source
    toolchain := cache.toolchain
    environment := cache.environment
    formatter := cache.formatter
    configuration := ← Project.configurationIdentity project target
    closure
  }

/-- Conservative currency for any target whose precise closure cannot be established: the digest of
every artifact in the workspace's own build directory.

Three kinds of target use it, and no header resolution happens for any of them — the cache layer
has no second import resolver:

* a **standalone file** with no Lake module at all (ungrabbed fixtures);
* an **executable root** such as `Main`, which is a real module with a real trace but is not
  reachable through `Lake.Workspace.findModule?`, since that searches libraries only;
* a **module that does not compile**, whose closure resolves but whose members have no artifacts.

It is sound for all three because it *dominates* every per-module closure digest: a workspace
module whose compiled output could contribute grammar to anything has that output in this
directory, and a module with no compiled output contributes no grammar. So anything a precise
closure digest would have noticed, this notices too.

It is coarse in exchange: any module rebuild invalidates every entry keyed this way. That is as
wide as these files' currency used to reach, but it now sits in a **per-entry** key instead of
the index *filename* — so it no longer orphans the index and no longer touches the entries that do
have a precise closure.

Measured here: a few targets need this beyond the standalone case. -/
private def ResultCache.workspaceArtifactsDigest (cache : ResultCache)
    (workspace : Lake.Workspace) : IO (Option Digest) := do
  if let some digest ← cache.workspaceArtifacts.get then
    return digest
  let digest ← withPhase "workspace_artifacts" do
    try
      let root ← IO.FS.realPath workspace.root.leanLibDir
      match ← rootTraceParts? root with
      | some parts => pure (some (digestParts parts))
      | none => pure none
    catch _ =>
      pure none
  cache.workspaceArtifacts.set (some digest)
  return digest

/-- Closure digests for a whole batch, from **one** shared no-build graph fetch.

`none` at a position means that target's currency could not be established, so it misses on
read and is not written — never that it hits. A workspace module gets the precise per-closure
digest; a standalone file gets `workspaceArtifactsDigest`, which is coarse but sound. -/
private def ResultCache.closureDigests (cache : ResultCache) (project : Project.Snapshot)
    (targets : Array Project.SourceTarget) : IO (Array (Option Digest)) := do
  try
    -- The fallback is computed **on demand**, not up front. It digests every artifact in
    -- the workspace's build directory, which is slow on a large project, and on a project where
    -- every target is a workspace module whose closure resolves it is never used. Computing it
    -- eagerly spent most of a warm run on a value nothing read.
    -- `workspaceArtifactsDigest` memoizes, so this stays at most one walk per run.
    let fallback : IO (Option Digest) := cache.workspaceArtifactsDigest project.workspace
    let known ← cache.closureDigestsByModule.get
    let wanted := targets.filterMap fun target => target.module?.map (·.name)
    let missing := wanted.filter fun name => !known.contains name.toString
    let mut known := known
    if !missing.isEmpty then
      let resolved ← withPhase "closure_resolve" <| Project.importClosures? project.workspace missing
      let byName := resolved.foldl (init := Std.HashMap.emptyWithCapacity resolved.size)
        fun map (name, closure) => map.insert name.toString closure
      for name in missing do
        -- The closure Lake reports is the module's *imports*. Its own artifacts belong in
        -- the digest too: its own `.olean` is what carries the projection being served, so a
        -- rebuild of the module itself must move the key even when nothing it imports changed.
        let closure := (byName[name.toString]?.getD none).map (·.push name)
        -- Precise when the closure resolves and every member's trace reads; otherwise the
        -- conservative whole-workspace digest rather than a permanent miss. See `fallback` below.
        let digest? ← withPhase "closure_hash" <|
          closureDigest? project.workspace cache.artifactHashByModule closure
        let resolved ← match digest? with
          | some digest => pure (some digest)
          | none => fallback
        known := known.insert name.toString resolved
      cache.closureDigestsByModule.set known
    targets.mapM fun target => do
      match target.module? with
      | none => fallback
      | some mod =>
        match known[mod.name.toString]? with
        | some digest? => pure digest?
        | none => fallback
  catch _ =>
    return Array.replicate targets.size none

private def resultDirectory (cache : ResultCache) : System.FilePath :=
  cache.root / "results"

private def baseDigest (cache : ResultCache) : Digest :=
  digestParts #[
    resultCacheSchema,
    cache.toolchain,
    toString cache.environment,
    toString cache.formatter
  ]

private def indexPath (cache : ResultCache) : System.FilePath :=
  resultDirectory cache / s!"{baseDigest cache}.json"

private def validAnalysis (target : Project.SourceTarget)
    (analysis : SemanticAnalysis) : Bool :=
  analysis.validFor target.source

private def analysisDigest (analysis : SemanticAnalysis) : Digest :=
  Digest.ofString (Lean.toJson analysis).compress

private def temporaryPath (target : System.FilePath) : IO System.FilePath := do
  let pid ← IO.Process.getPID
  let nonce ← IO.monoNanosNow
  return System.FilePath.mk s!"{target}.tmp-{pid}-{nonce}"

/-- How many index files a project keeps besides the one currently in use.

The index name is a digest of the *epoch* — toolchain, search-path order, dependency roots,
and the formatter binary's own identity. Project edits no longer move it, but an epoch
change still does, and each change orphans the previous index with nothing collecting it. Measured
before this: repeated formatter rebuilds left index files piling up without bound.

Not zero, deliberately. Two `lean-fmt` builds can share one project — an editor holding an older
binary while the CLI runs a newer one — and each is a distinct epoch. At zero retention they would
delete each other's index on every run and neither would ever hit. Retaining a few makes that case
cost disk instead of correctness, while still bounding the directory. -/
private def indexRetention : Nat := 3

/-- Delete all but the `indexRetention` most recently modified indexes other than the live one.

Best effort. A concurrent run may unlink a file between the listing and the delete, or own
a directory this process cannot write; either way the collection is skipped and the run proceeds.
An uncollected index costs disk, never correctness — entries are keyed by content and validated on
read, so a stale index is unreachable rather than wrong. -/
private def modifiedSeconds? (path : System.FilePath) : IO (Option Int) := do
  try
    return some (← path.metadata).modified.sec
  catch _ =>
    return none

private def removeQuietly (path : System.FilePath) : IO Unit := do
  try
    IO.FS.removeFile path
  catch _ =>
    pure ()

private def collectStaleIndexes (cache : ResultCache) : IO Unit := do
  try
    let live := indexPath cache
    let candidates := (← (resultDirectory cache).readDir).filter fun entry =>
      entry.path.extension == some "json" && entry.path.toString != live.toString
    let mut dated := #[]
    for candidate in candidates do
      if let some seconds ← modifiedSeconds? candidate.path then
        dated := dated.push (seconds, candidate.path)
    let ordered := dated.qsort fun a b => a.1 > b.1
    for (_, path) in ordered.extract indexRetention ordered.size do
      removeQuietly path
  catch _ =>
    pure ()

private def writeIndexAtomic (path : System.FilePath) (index : CacheIndex) : IO Unit := do
  let temporary ← temporaryPath path
  try
    IO.FS.writeFile temporary (Lean.toJson index).compress
    IO.FS.rename temporary path
  catch error =>
    if ← temporary.pathExists then
      IO.FS.removeFile temporary
    throw error

/- Construct a cache capability only after the evaluated workspace's ordered roots, current
source contents, and all non-toolchain module artifacts have trustworthy, content-matching Lake
traces. Absence is a normal disabled-cache outcome; callers cannot manufacture a partial epoch. -/
def ResultCache.open? (workspace : Lake.Workspace) (application : System.FilePath) :
    IO (Option ResultCache) := do
  try
    let some environment ← environmentDigest? workspace
      | return none
    -- Formatter identity is the binary's path, size, and modification time, not a content
    -- hash of its bytes: the executable statically links Lean's own shared runtime, so it is
    -- large, and the pure-Lean SHA-256 over it dominated every cached invocation. A rebuild always
    -- rewrites the file, so (size, mtime) changes whenever the formatter could behave differently;
    -- `toolchain` below pins the toolchain revision separately.
    let stat ← application.metadata
    let formatter := Digest.ofString
      s!"{application}\u0000{stat.byteSize}\u0000{stat.modified.sec}\u0000{stat.modified.nsec}"
    let directoryReady ← IO.mkRef false
    let loadedEntries ← IO.mkRef none
    let workspaceArtifacts ← IO.mkRef none
    let closureDigestsByModule ← IO.mkRef {}
    let artifactHashByModule ← IO.mkRef {}
    return some {
      root := workspace.root.dir / ".lean-fmt-cache"
      toolchain := s!"{Lean.versionString}\u0000{workspace.lakeEnv.lean.githash}"
      environment
      formatter
      directoryReady
      loadedEntries
      workspaceArtifacts
      closureDigestsByModule
      artifactHashByModule
    }
  catch _ =>
    return none

private def ResultCache.loadEntries (cache : ResultCache) : IO (Std.HashMap String CacheEntry) := do
  if let some entries ← cache.loadedEntries.get then
    return entries
  let entries ← try
    let contents ← IO.FS.readFile (indexPath cache)
    let .ok json := Lean.Json.parse contents
      | pure {}
    let .ok (index : CacheIndex) := Lean.fromJson? json
      | pure {}
    if index.schema != resultCacheSchema || index.base != baseDigest cache then
      pure {}
    else
      pure <| index.entries.foldl
        (init := Std.HashMap.emptyWithCapacity index.entries.size) fun entries entry =>
          entries.insert (toString entry.identity) entry
  catch _ =>
    pure {}
  cache.loadedEntries.set (some entries)
  return entries

/- Read an ordered batch from one environment-scoped index. Individual schema, identity, payload,
and source failures remain ordinary per-target misses; a corrupt index is an empty cache. -/
/-- The current observation for one target, in the shared decision's vocabulary.

`Mod` is instantiated at `Unit`: the decision for one entry consults only that entry's module,
so the per-module functions are constant. A module name would make them partial in a way nothing
here needs.

**A2 applies here.** These digests are read from the filesystem before the analysis is served, and
nothing prevents the tree changing in between. `LeanFmt.Cache.Spec` carries that as a hypothesis
rather than proving it away, and this is the code the hypothesis is about. -/
private def observation (target : Project.SourceTarget) (closure : Digest) :
    Cache.Decision.Obs Unit Digest Digest String :=
  { schema := resultCacheSchema
    sourceDigest := fun _ => Digest.ofString target.source
    closureDigest := fun _ => closure }

/-- A stored entry in the shared decision's vocabulary. -/
private def entryDecision (entry : CacheEntry) :
    Cache.Decision.Entry Unit SemanticAnalysis Digest Digest String :=
  { mod := ()
    schema := entry.schema
    sourceDigest := entry.sourceDigest
    closureDigest := entry.closureDigest
    provided := providedOf entry.analysis
    analysis := entry.analysis }

def ResultCache.readAll (cache : ResultCache) (project : Project.Snapshot)
    (targets : Array Project.SourceTarget) : IO (Array (Option SemanticAnalysis)) := do
  let entries ← cache.loadEntries
  if entries.isEmpty then
    return Array.replicate targets.size none
  let closures ← cache.closureDigests project targets
  (targets.zip closures).mapM fun (target, closure?) => do
    try
      -- Undeterminable currency is an ordinary miss, never a hit. It is not
      -- a cache-disabling condition: one target degrades, the rest of the batch is unaffected.
      let some closure := closure?
        | return none
      let expected ← identity cache project target closure
      let digest := cacheIdentityDigest expected
      let some entry := entries.get? (toString digest)
        | return none
      -- Integrity of the record, which is not currency: the payload digest and
      -- `validAnalysis` catch a truncated or mismatched entry, and `identity` confirms the hash
      -- probe found the entry it meant to.
      unless entry.identity == digest && entry.payload == analysisDigest entry.analysis &&
          validAnalysis target entry.analysis do
        return none
      -- Currency is `Cache.Decision.Entry.identityCurrent`, the function
      -- `LeanFmt.Cache.Spec` proves `serves_sound` and `serves_complete` about. The other half of
      -- `Decision.serves` — `Provided.meets` — runs in `LeanFmt.Application`, which is where the
      -- rule plan is known.
      unless (entryDecision entry).identityCurrent (observation target closure) do
        return none
      return some entry.analysis
    catch _ =>
      return none

private def ResultCache.ensureWriteDirectory (cache : ResultCache) : IO Unit := do
  unless ← cache.directoryReady.get do
    IO.FS.createDirAll (resultDirectory cache)
    cache.directoryReady.set true

/- Merge and atomically publish an ordered batch once. Cache failure never changes successful
analysis; the next run simply observes the previous index or an empty cache. -/
def ResultCache.writeAll (cache : ResultCache) (project : Project.Snapshot)
    (targets : Array Project.SourceTarget)
    (analyses : Array (Option SemanticAnalysis)) : IO Unit := do
  try
    let mut entries ← cache.loadEntries
    let closures ← withPhase "write_closures" <| cache.closureDigests project targets
    for ((target, analysis?), closure?) in (targets.zip analyses).zip closures do
      let some analysis := analysis?
        | continue
      unless validAnalysis target analysis do
        continue
      -- A target whose currency could not be established is not written. Writing it under
      -- a placeholder closure would make it indistinguishable from a genuinely current entry on
      -- the next run, which is the stale hit this cache exists to remove.
      let some closure := closure?
        | continue
      let expected ← identity cache project target closure
      let digest := cacheIdentityDigest expected
      let entry : CacheEntry := {
        schema := resultCacheSchema
        identity := digest
        payload := analysisDigest analysis
        sourceDigest := expected.source
        closureDigest := expected.closure
        analysis
      }
      entries := entries.insert (toString digest) entry
    cache.ensureWriteDirectory
    let ordered := entries.toList.toArray.map (·.2)
      |>.qsort (toString ·.identity < toString ·.identity)
    let index : CacheIndex := {
      schema := resultCacheSchema
      base := baseDigest cache
      entries := ordered
    }
    writeIndexAtomic (indexPath cache) index
    collectStaleIndexes cache
    cache.loadedEntries.set (some entries)
  catch _ =>
    return

end LeanFmt.Internal
