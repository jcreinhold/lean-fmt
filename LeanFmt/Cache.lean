module

import all LeanFmt.Project
import all LeanFmt.Semantic
import Lake.Build.Trace
import Lake.Config.Workspace

namespace LeanFmt.Internal

private structure TraceOutputs where
  o : Array String
  /-- `ir.sig` and `ir` content hashes. Optional because a legacy (non-module-system) module has
  neither, and `computeExportInfo`'s legacy branch mixes only the `.olean`. -/
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

inductive ValidationLevel where
  | syntax
  | elaboration
  deriving BEq, Lean.ToJson, Lean.FromJson

structure CacheIdentity where
  source : Digest
  toolchain : String
  environment : Digest
  formatter : Digest
  configuration : Digest
  validationLevel : ValidationLevel
  semanticSchema : String
  /-- Currency of the grammar this module's artifact was produced under (`ruff-16b` `RCI-IMPL`).

  `source` covers the module's own bytes. This covers the *other* half of what a cached analysis
  depends on: Lean's grammar is open, so a `notation` in `A` changes how `B`'s unchanged bytes parse,
  and `B`'s stored projection then describes a tree those bytes no longer denote.

  It is per entry, not per epoch, which is the whole point. It used to be covered — accidentally and
  far too coarsely — by folding every project source into `environment`, which named the index file
  and so invalidated the entire project on any edit (0 of 112 entries hit after one comment;
  `results/01-contract.md` §2). -/
  closure : Digest
  deriving BEq, Lean.ToJson, Lean.FromJson

private structure CacheEntry where
  schema : String
  identity : Digest
  payload : Digest
  analysis : SemanticAnalysis
  deriving Lean.ToJson, Lean.FromJson

private structure CacheIndex where
  schema : String
  base : Digest
  entries : Array CacheEntry
  deriving Lean.ToJson, Lean.FromJson

structure ResultCache where
  private mk ::
  root : System.FilePath
  toolchain : String
  environment : Digest
  formatter : Digest
  validationLevel : ValidationLevel
  directoryReady : IO.Ref Bool
  loadedEntries : IO.Ref (Option (Std.HashMap String CacheEntry))
  /-- Memoized conservative currency for standalone (non-workspace-module) targets: the digest of
  every artifact in the workspace's own build directory. Computed at most once per run. -/
  workspaceArtifacts : IO.Ref (Option (Option Digest))
  /-- Memoized per-module closure digests, keyed by module name.

  `readAll` and `writeAll` both need them, and resolving a closure means a no-build Lake graph fetch.
  Without this the same batch would fetch twice per run. Memoizing per *name* rather than per batch
  keeps it correct when the two calls are handed different target arrays. -/
  closureDigestsByModule : IO.Ref (Std.HashMap String (Option Digest))

def resultCacheSchema : String := "lean-fmt.result-cache.v2"

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

/- ## Per-module currency (`ruff-16b` `RCI-IMPL`)

What used to be here was `sourceRootParts?`: a walk of every non-`.lake` `.lean` file under every
source root, digesting each one's bytes into `environment`. `environment` feeds `baseDigest`, and
`baseDigest` *names the index file* -- so editing any one source renamed the index and orphaned every
entry in it. Measured on this repository: after appending one comment to one of 112 files, 0 entries
hit, not 111, and a second index file appeared that nothing ever collected.

It was standing in for a check nobody had written. `validateOleanTrace?` proves an artifact is
**intact** -- its recorded outputs exist and hash to their content-addressed names -- never that it is
**current**. The whole-project walk was the crude substitute: invalidate everything whenever anything
changes.

The replacement is exact and per entry. For a module `X`, Lake's `computeExportInfo` defines

    X:importAllArts = Hash.nil |>.mix olean |>.mix oleanServer |>.mix oleanPrivate
                              |>.mix irSig |>.mix ir

and each mixed value is the content hash Lake writes as the leading 16 hex digits of the
corresponding entry in `X`'s own `outputs`. So the value a dependent recorded for `X` is recomputable
from `X`'s own trace file -- no import resolution and no closure walk here, which this stack's stop
rules forbid. `testLakeTraceCharacterization` pins that identity across every (importer, importee)
pair in the built tree, mutation-checked.

**Do not "simplify" this to `X transitive imports (all)`.** That key hashes the closure of `X`'s
*imports* and excludes `X` itself. This stack's roadmap proposed exactly that and measurement refuted
it (`evidence/01-invalidation-and-traces.md` section 3.1): reading it would pass on precisely the
stale grammar case the check exists to catch. -/

/-- Recompute Lake's `importAllArts` for one module from its own recorded trace outputs.

Order matters and matches `computeExportInfo`: the `o` array (olean, olean.server, olean.private),
then `rs`, then `r`. A legacy non-module-system module has `o = [olean]` and no `rs`/`r`, which folds
correctly under the same loop. -/
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

/-- The grammar-currency digest for one target: its transitive import closure, each member paired
with its module artifacts as they are on disk **right now**.

`none` -- meaning the entry misses -- whenever currency cannot be established: the closure could not
be resolved, a member is not a workspace module, or a member's trace is absent, unparseable, or of an
unrecognized schema. `RCI-SPEC` froze this direction: currency that cannot be determined degrades to a
miss, never to a hit, and such an entry is not written either, since a placeholder value would be
indistinguishable from a real one on the next run.

This degrades **one entry**, not the cache. That is deliberately finer than `environmentDigest?`,
which disables everything when it returns `none` -- correctly, because that is a property of the epoch
rather than of an entry. -/
private def closureDigest? (workspace : Lake.Workspace)
    (closure : Option (Array Lean.Name)) : IO (Option Digest) := do
  let some members := closure
    | return none
  let ordered := members.qsort (·.toString < ·.toString)
  let mut parts := #[]
  for name in ordered do
    let some tracePath := Project.moduleTracePath? workspace name
      | return none
    let some hash ← moduleArtifactHash? tracePath
      | return none
    parts := parts.push s!"closure {name} {hash}"
  return some (digestParts parts)

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
  -- `CacheIdentity.closure` instead. It was the *second* whole-project invalidator: `rootTraceParts?`
  -- folds every `.olean`'s trace contents into `environment`, `environment` names the index file, so
  -- rebuilding any one module renamed the index and orphaned every entry -- the same defect as the
  -- project-source walk, one layer down, and removing only the source walk would not have fixed it.
  --
  -- Dependency package roots keep exactly the coverage they had. The completion contract scopes this
  -- stack to project-source coverage, and a dependency's artifacts are an epoch property: they change
  -- when the manifest or a dependency build changes, not when the user edits their own file.
  let ownLibDir ← try IO.FS.realPath workspace.root.leanLibDir catch _ => pure workspace.root.leanLibDir
  for root in roots do
    let root ← IO.FS.realPath root
    if insideToolchain toolchain root || root == ownLibDir then
      continue
    let some rootParts ← rootTraceParts? root
      | return none
    parts := parts ++ rootParts
  for root in workspace.augmentedSharedLibPath do
    let root ← IO.FS.realPath root
    if insideToolchain toolchain root then
      continue
    let some rootParts ← sharedTraceParts? root
      | return none
    parts := parts ++ rootParts
  -- Project source *content* deliberately does not appear here. `environment` names the index file
  -- through `baseDigest`, so folding project sources in made one edit rename the index and orphan
  -- every entry (`ruff-16b` `RCI-SPEC`). Project-source currency is per entry now, in
  -- `CacheIdentity.closure`. The ordered *paths* above stay: search-path precedence is an epoch
  -- property and changing it changes what every module resolves to.
  return some (digestParts parts)

/-- The per-target key. `closure` is supplied by the caller rather than computed here because it
comes from one shared no-build Lake graph fetched once for the whole batch; computing it per target
would mean one graph build per file, which `LeanFmt.Project` exists to prevent. -/
private def identity (cache : ResultCache) (project : Project.Snapshot)
    (target : Project.SourceTarget) (closure : Digest) : IO CacheIdentity := do
  return {
    source := Digest.ofString target.source
    toolchain := cache.toolchain
    environment := cache.environment
    formatter := cache.formatter
    configuration := ← Project.configurationIdentity project target
    validationLevel := cache.validationLevel
    semanticSchema := semanticResultSchema
    closure
  }

/-- Conservative currency for any target whose precise closure cannot be established: the digest of
every artifact in the workspace's own build directory.

Three kinds of target land here, and no header resolution happens for any of them -- a second import
resolver in the cache layer is what this stack's stop rules forbid:

* a **standalone file** with no Lake module at all (`experiments/`, ungrabbed fixtures);
* an **executable root** such as `Main`, which is a real module with a real trace but is not reachable
  through `Lake.Workspace.findModule?`, since that searches libraries only;
* a **module that does not compile**, whose closure resolves but whose members have no artifacts.

It is sound for all three because it *dominates* every per-module closure digest: a workspace module
whose compiled output could contribute grammar to anything has that output in this directory, and a
module with no compiled output contributes no grammar. So anything a precise closure digest would have
noticed, this notices too.

It is coarse in exchange: any module rebuild invalidates every entry keyed this way. That is the same
blast radius these files had before this stack, with the decisive difference that it now lives in a
**per-entry** key instead of in the index *filename* -- so it no longer orphans the index and no longer
touches the entries that do have a precise closure.

Measured here: 6 of 113 targets need this beyond the standalone case. -/
private def ResultCache.workspaceArtifactsDigest (cache : ResultCache)
    (workspace : Lake.Workspace) : IO (Option Digest) := do
  if let some digest ← cache.workspaceArtifacts.get then
    return digest
  let digest ← try
    let root ← IO.FS.realPath workspace.root.leanLibDir
    match ← rootTraceParts? root with
    | some parts => pure (some (digestParts parts))
    | none => pure none
  catch _ =>
    pure none
  cache.workspaceArtifacts.set (some digest)
  return digest

/-- Closure digests for a whole batch, from **one** shared no-build graph fetch.

`none` at a position means that target's currency could not be established, so it misses on read and
is not written -- never that it hits. A workspace module gets the precise per-closure digest; a
standalone file gets `workspaceArtifactsDigest`, which is coarse but sound. -/
private def ResultCache.closureDigests (cache : ResultCache) (project : Project.Snapshot)
    (targets : Array Project.SourceTarget) : IO (Array (Option Digest)) := do
  try
    let fallback ← cache.workspaceArtifactsDigest project.workspace
    let known ← cache.closureDigestsByModule.get
    let wanted := targets.filterMap fun target => target.module?.map (·.name)
    let missing := wanted.filter fun name => !known.contains name.toString
    let mut known := known
    if !missing.isEmpty then
      let resolved ← Project.importClosures? project.workspace missing
      let byName := resolved.foldl (init := Std.HashMap.emptyWithCapacity resolved.size)
        fun map (name, closure) => map.insert name.toString closure
      for name in missing do
        -- The closure Lake reports is the module's *imports*. Its own artifacts belong in the digest
        -- too: its own `.olean` is what carries the projection being served, so a rebuild of the
        -- module itself must move the key even when nothing it imports changed.
        let closure := (byName[name.toString]?.getD none).map (·.push name)
        -- Precise when the closure resolves and every member's trace reads; otherwise the
        -- conservative whole-workspace digest rather than a permanent miss. See `fallback` below.
        let digest? ← closureDigest? project.workspace closure
        known := known.insert name.toString (digest?.orElse fun _ => fallback)
      cache.closureDigestsByModule.set known
    return targets.map fun target =>
      match target.module? with
      | none => fallback
      | some mod => known[mod.name.toString]?.getD fallback
  catch _ =>
    return Array.replicate targets.size none

private def resultDirectory (cache : ResultCache) : System.FilePath :=
  cache.root / "results"

private def baseDigest (cache : ResultCache) : Digest :=
  digestParts #[
    resultCacheSchema,
    cache.toolchain,
    toString cache.environment,
    toString cache.formatter,
    (Lean.toJson cache.validationLevel).compress,
    semanticResultSchema
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

private def writeIndexAtomic (path : System.FilePath) (index : CacheIndex) : IO Unit := do
  let temporary ← temporaryPath path
  try
    IO.FS.writeFile temporary (Lean.toJson index).compress
    IO.FS.rename temporary path
  catch error =>
    if ← temporary.pathExists then
      IO.FS.removeFile temporary
    throw error

/- Construct a cache capability only after the evaluated workspace's ordered roots, current source
contents, and all non-toolchain module artifacts have trustworthy, content-matching Lake traces.
Absence is a normal disabled-cache outcome; callers cannot manufacture a partial epoch. -/
def ResultCache.open? (workspace : Lake.Workspace) (application : System.FilePath)
    (validationLevel := ValidationLevel.syntax) : IO (Option ResultCache) := do
  try
    let some environment ← environmentDigest? workspace
      | return none
    -- Formatter identity is the binary's path, size, and modification time, not a content hash of
    -- its bytes: the executable statically links libleanshared and runs to ~180 MB, and the pure-Lean
    -- SHA-256 over that dominated every cached invocation (~2.8 s). A rebuild always rewrites the file,
    -- so (size, mtime) changes exactly when the formatter could behave differently; the toolchain
    -- revision is already pinned separately via `toolchain` below.
    let stat ← application.metadata
    let formatter := Digest.ofString
      s!"{application} {stat.byteSize} {stat.modified.sec} {stat.modified.nsec}"
    let directoryReady ← IO.mkRef false
    let loadedEntries ← IO.mkRef none
    let workspaceArtifacts ← IO.mkRef none
    let closureDigestsByModule ← IO.mkRef {}
    return some {
      root := workspace.root.dir / ".lean-fmt-cache"
      toolchain := s!"{Lean.versionString}\u0000{workspace.lakeEnv.lean.githash}"
      environment
      formatter
      validationLevel
      directoryReady
      loadedEntries
      workspaceArtifacts
      closureDigestsByModule
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
def ResultCache.readAll (cache : ResultCache) (project : Project.Snapshot)
    (targets : Array Project.SourceTarget) : IO (Array (Option SemanticAnalysis)) := do
  let entries ← cache.loadEntries
  if entries.isEmpty then
    return Array.replicate targets.size none
  let closures ← cache.closureDigests project targets
  (targets.zip closures).mapM fun (target, closure?) => do
    try
      -- Undeterminable currency is an ordinary miss, never a hit (`RCI-SPEC`). It is not a
      -- cache-disabling condition: one target degrades, the rest of the batch is unaffected.
      let some closure := closure?
        | return none
      let expected ← identity cache project target closure
      let digest := cacheIdentityDigest expected
      let some entry := entries.get? (toString digest)
        | return none
      unless entry.schema == resultCacheSchema && entry.identity == digest &&
          entry.payload == analysisDigest entry.analysis && validAnalysis target entry.analysis do
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
    let closures ← cache.closureDigests project targets
    for ((target, analysis?), closure?) in (targets.zip analyses).zip closures do
      let some analysis := analysis?
        | continue
      unless validAnalysis target analysis do
        continue
      -- A target whose currency could not be established is not written. Writing it under a
      -- placeholder closure would make it indistinguishable from a genuinely current entry on the
      -- next run, which is the stale hit this stack exists to remove.
      let some closure := closure?
        | continue
      let expected ← identity cache project target closure
      let digest := cacheIdentityDigest expected
      let entry : CacheEntry := {
        schema := resultCacheSchema
        identity := digest
        payload := analysisDigest analysis
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
    cache.loadedEntries.set (some entries)
  catch _ =>
    return

end LeanFmt.Internal
