module

import all LeanFmt.Project
import all LeanFmt.Semantic
import Lake.Build.Trace
import Lake.Config.Workspace

namespace LeanFmt.Internal

private structure TraceOutputs where
  o : Array String
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

private def sourceRootParts? (root : System.FilePath) : IO (Option (Array String)) := do
  try
    unless ← root.isDir do
      return none
    let sources := (← root.walkDir fun path => pure <| path.fileName != some ".lake")
      |>.filter (·.extension == some "lean")
      |>.qsort (·.toString < ·.toString)
    let mut parts := #[s!"source-root\u0000{← IO.FS.realPath root}"]
    for source in sources do
      let relative := Lake.relPathFrom root source |>.toString
      let digest := Digest.ofBytes (← IO.FS.readBinFile source)
      parts := parts.push s!"source\u0000{relative}\u0000{digest}"
    return some parts
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
  for root in roots do
    let root ← IO.FS.realPath root
    if insideToolchain toolchain root then
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
  let mut seenSourceRoots : Std.HashSet String := {}
  for root in workspace.augmentedLeanSrcPath do
    let root ← IO.FS.realPath root
    if insideToolchain toolchain root || seenSourceRoots.contains root.toString then
      continue
    seenSourceRoots := seenSourceRoots.insert root.toString
    let some rootParts ← sourceRootParts? root
      | return none
    parts := parts ++ rootParts
  return some (digestParts parts)

private def identity (cache : ResultCache) (project : Project.Snapshot)
    (target : Project.SourceTarget) : IO CacheIdentity := do
  return {
    source := Digest.ofString target.source
    toolchain := cache.toolchain
    environment := cache.environment
    formatter := cache.formatter
    configuration := ← Project.configurationIdentity project target
    validationLevel := cache.validationLevel
    semanticSchema := semanticResultSchema
  }

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
    let formatter := Digest.ofBytes (← IO.FS.readBinFile application)
    let directoryReady ← IO.mkRef false
    let loadedEntries ← IO.mkRef none
    return some {
      root := workspace.root.dir / ".lean-fmt-cache"
      toolchain := s!"{Lean.versionString}\u0000{workspace.lakeEnv.lean.githash}"
      environment
      formatter
      validationLevel
      directoryReady
      loadedEntries
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
  targets.mapM fun target => do
    try
      let expected ← identity cache project target
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
    for (target, analysis?) in targets.zip analyses do
      let some analysis := analysis?
        | continue
      unless validAnalysis target analysis do
        continue
      let expected ← identity cache project target
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
