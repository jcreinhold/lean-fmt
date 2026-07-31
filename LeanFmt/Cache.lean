/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.Cache.Decision
import all LeanFmt.Imports
import all LeanFmt.Profile
import all LeanFmt.Project
import all LeanFmt.Semantic

-- `import all` for `Lake.BuildMetadata.schemaVersion`, which is not `public`. It is the one thing
-- this file must pin and the one thing Lake's parse does not check; see `readTrace?`.
import all Lake.Build.Common
import Lake.Build.ModuleArtifacts
import Lake.Build.Trace
import Lake.Config.Workspace

/-! The aggregate result cache: one epoch for the workspace, one entry per module.

Identity is the whole point. An entry is served only when the environment that produced it is the
environment now asking — toolchain, Lake configuration, every dependency artifact, the formatter's
own binary — and the proof is a digest over all of it, recomputed each run. `Cache/Spec.lean` proves
the decision sound and complete; the code here supplies the inputs that proof quantifies over.

Errors run one way. A cache that cannot establish identity must miss and must not serve, so every
degradation here narrows what is served rather than widening it. An artifact this code cannot
validate is hashed by content instead of vetoing the run: coverage is kept, availability is not
traded for it. -/

namespace LeanFmt.Internal

open LeanFmt.Internal.Profile

/- One of Lake's trace files, parsed by Lake, if it is one this code understands.

**The schema check is ours because Lake's parse does not make one.**
`BuildMetadata.fromJsonObject?` consults `schemaVersion` only to tell a legacy decimal `depHash`
from a hex one, `fromJson?` consults it only to word an error, and the parsed structure does not
carry the version at all. So a trace written under a future schema whose fields still parse would
be accepted, and every digest below would be computed from a shape this code no longer understands
— a stale hit, which is the one direction currency must never degrade toward.

The contents come back with it because both callers digest the file's own bytes, not the parse. -/
private def readTrace? (tracePath : System.FilePath) : IO (Option (String × Lake.BuildMetadata)) :=
  do
  try
    let contents ← IO.FS.readFile tracePath
    let .ok json := Lean.Json.parse contents | return none
    unless
      (json.getObjValAs? String "schemaVersion").toOption ==
        some Lake.BuildMetadata.schemaVersion do
      return none
    let .ok metadata := Lake.BuildMetadata.fromJson? json | return none
    return some (contents, metadata)
  catch _ =>
    return none

/- A module trace's recorded outputs, named. Lake's own reader, so the `<16-hex>.<ext>` tokens and
which array position means `.olean.server` are its business rather than this file's. -/
private def moduleOutputs? (metadata : Lake.BuildMetadata) : Option Lake.ModuleOutputDescrs := do
  let outputs ← metadata.outputs?
  (Lake.ModuleOutputDescrs.fromJson? outputs).toOption

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
  | some result => .success result.tier result.caps result.canonical?.isSome

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
  /-- The elaboration-visible interface the module's `leanFmtArtifact` sidecar records
  (`ClosureMode.interface`). A distinct constructor, not a converted `hash`: the prefix in
  `closureDigest?` differs, so toggling the mode misses every entry instead of aliasing one. -/
  | interfaceHash (value : Digest)
  /-- No compiled output of any form on disk. -/
  | unbuilt
  /-- Output may exist; currency cannot be recomputed from it. -/
  | unreadable
  deriving Inhabited

structure ResultCache where private mk ::
  root : System.FilePath
  toolchain : String
  environment : Digest
  formatter : Digest
  /-- How closure currency is computed (`[cache] closure`); see `ClosureMode`. Per cache, not
  per entry: the digest *prefixes* differ per mode, so a mode change misses every entry. -/
  closureMode : ClosureMode
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

def resultCacheSchema : String :=
  "lean-fmt.result-cache.v4"

private def digestParts (parts : Array String) : Digest :=
  Digest.ofString (String.intercalate "\u0000" parts.toList)

def cacheIdentityDigest (identity : CacheIdentity) : Digest :=
  digestParts #[resultCacheSchema, (Lean.toJson identity).compress]

/- One artifact's contribution to the epoch: its trace when the trace can be trusted, its own
contents when it cannot.

**Every artifact contributes; none can veto.** Both of these returned `none` on anything they could
not validate, and `environmentDigest` turned a single `none` into "this workspace gets no cache" —
silently, since a disabled cache is a supported outcome. One orphaned file was enough. Measured on
`mathlib4`: 8,408 `.olean` files, 8,407 `.trace` files, and the odd one out
(`Counterexamples/SorgenfreyLine.olean`, left behind rather than pruned) cost every project
depending on that checkout its whole result cache.

The refusal existed to avoid an epoch that silently omits data. This form omits nothing: what cannot
be validated is hashed instead, so changing an untraced artifact still moves the epoch. Availability
is not traded for coverage — the two arms cover the same artifact, one cheaply and one expensively.

**The expensive arm is unbounded in principle**, and is left visible rather than capped: a root full
of untraced artifacts would read every one of them on every run. `cache.untraced_artifacts` counts
them and the cost lands in `phase.cache_epoch_ms`. On the mathlib checkout above the count is 1. -/

/- Intactness, never currency: a valid trace proves the artifact on disk is the one its trace
describes, not that the trace describes current source. `CacheIdentity.closure` covers currency. -/
private def oleanPart (root olean : System.FilePath) : IO (String × Bool) := do
  let tracePath := olean.withExtension "trace"
  let contentPart : IO (String × Bool) := do
    let relative := Lake.relPathFrom root olean |>.toString
    let hash? ←
      try
        pure (some (← Lake.computeFileHash olean))
      catch _ =>
        pure none
    return (s!"untraced\u0000{relative}\u0000{hash?.map (·.toString) |>.getD "unreadable"}", true)
  let some (contents, metadata) ← readTrace? tracePath |
    contentPart
  let some outputs := moduleOutputs? metadata | contentPart
  -- A Lake artifact is named `<hash>.<ext>` where `ext` is the whole suffix — `olean`,
  -- `olean.server`, `olean.private` — so the sibling on disk is the module's own path with
  -- that extension put back.
  let some base := olean.toString.dropSuffix? ".olean" | contentPart
  let intact ←
    try
      let mut intact := true
      for descr in outputs.oleanParts do
        let output := System.FilePath.mk s!"{base}.{descr.ext}"
        unless (← output.pathExists) && (← Lake.computeFileHash output) == descr.hash do
          intact := false
      pure intact
    catch _ =>
      pure false
  unless intact do
    return ← contentPart
  let relative := Lake.relPathFrom root tracePath |>.toString
  return (s!"{relative}\u0000{Digest.ofString contents}", false)

/-- The parts, and how many of them took the content arm. -/
private def rootTraceParts (root : System.FilePath) : IO (Array String × Nat) := do
  unless ← root.isDir do
    return (#[], 0)
  let oleans :=
    (← root.walkDir).filter (·.extension == some "olean") |>.qsort (·.toString < ·.toString)
  let mut parts := #[s!"root\u0000{← IO.FS.realPath root}"]
  let mut untraced := 0
  for olean in oleans do
    let (part, byContent) ← oleanPart root olean
    parts := parts.push part
    if byContent then
      untraced := untraced + 1
  return (parts, untraced)

/- A shared library's `outputs` is one artifact name rather than a module's several. -/
private def sharedPart (root library : System.FilePath) : IO (String × Bool) := do
  let tracePath := library.addExtension "trace"
  let contentPart : IO (String × Bool) := do
    let relative := Lake.relPathFrom root library |>.toString
    let hash? ←
      try
        pure (some (← Lake.computeFileHash library))
      catch _ =>
        pure none
    return (s!"shared-untraced\u0000{relative}\u0000{hash?.map (·.toString) |>.getD "unreadable"}",
        true)
  let some (contents, metadata) ← readTrace? tracePath |
    contentPart
  let some outputs := metadata.outputs? | contentPart
  let .ok descr := Lake.ArtifactDescr.fromJson? outputs | contentPart
  let intact ←
    try
      pure ((← Lake.computeFileHash library) == descr.hash)
    catch _ =>
      pure false
  unless intact do
    return ← contentPart
  let relative := Lake.relPathFrom root tracePath |>.toString
  return (s!"shared\u0000{relative}\u0000{Digest.ofString contents}", false)

private def sharedTraceParts (root : System.FilePath) : IO (Array String × Nat) := do
  unless ← root.isDir do
    return (#[], 0)
  let libraries :=
    (← root.walkDir).filter (·.extension == some Lake.sharedLibExt) |>.qsort
      (·.toString < ·.toString)
  let mut parts := #[s!"shared-root\u0000{← IO.FS.realPath root}"]
  let mut untraced := 0
  for library in libraries do
    let (part, byContent) ← sharedPart root library
    parts := parts.push part
    if byContent then
      untraced := untraced + 1
  return (parts, untraced)

private def pathParts (label : String) (paths : List System.FilePath) : Array String :=
  paths.toArray.mapIdx fun index path => s!"{label}\u0000{index}\u0000{path}"

private def insideToolchain (toolchain path : System.FilePath) : Bool :=
  path == toolchain ||
    path.toString.startsWith (toolchain.toString ++ System.FilePath.pathSeparator.toString)

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

Order matters and matches `computeExportInfo`: `oleanParts` (olean, olean.server, olean.private),
then `irSig?`, then `ir?`. A legacy non-module-system module has one `oleanPart` and neither of the
others, which folds correctly under the same loop. Reading the parts by name rather than by
position in the `o` array is Lake's `ModuleOutputDescrs` doing it, not a convention repeated here. -/
private def moduleArtifactHash? (tracePath : System.FilePath) : IO (Option Lake.Hash) := do
  let some (_, metadata) ← readTrace? tracePath |
    return none
  let some outputs := moduleOutputs? metadata | return none
  let mut hash := Lake.Hash.nil
  for descr in outputs.oleanParts do
    hash := hash.mix descr.hash
  for extra in [outputs.irSig?, outputs.ir?]do
    if let some descr := extra then
      hash := hash.mix descr.hash
  return some hash

/-- Interface-mode preference for one closure member: the `interfaceHash` its `leanFmtArtifact`
sidecar recorded, or `none` when no usable sidecar exists and the caller falls back to the
trace path. Dependencies do not build the facet, and their artifact hash moves only on a
dependency update — exactly when their interface would — so the fallback is both sound (the
artifact hash is strictly more conservative than the interface hash) and cheap.

Currency is the guard that makes this safe: the facet is fetched on demand, so a sidecar can
describe an *older* build than the `.olean` beside it. A sidecar older than the module's `.olean`
is treated as absent — the fallback is the old behavior, never a stale hit. -/
private def memberInterfaceFact (workspace : Lake.Workspace) (name : Lean.Name) :
    IO (Option MemberFact) := do
  let some mod := workspace.findModule? name | return none
  -- The facet's own path convention — `artifactFile` in the lakefile that declares
  -- `leanFmtArtifact`, duplicated in `Project.lean`'s facet probe; the compiler suite's
  -- mixed-selection case notices if the two drift.
  let sidecar := Lean.modToFilePath (mod.pkg.buildDir / "lean-fmt-artifacts") name "json"
  try
    if let some oleanPath := Project.moduleOutputPaths? workspace name |>.bind (·[0]?) then
      if ← oleanPath.pathExists then
        let oleanTime := (← oleanPath.metadata).modified
        let sidecarTime := (← sidecar.metadata).modified
        if
            sidecarTime.sec < oleanTime.sec ||
              (sidecarTime.sec == oleanTime.sec && sidecarTime.nsec < oleanTime.nsec) then
          return none
    let contents ← IO.FS.readFile sidecar
    let .ok json := Lean.Json.parse contents | return none
    let .ok artifact := (Lean.fromJson? json : Except String ModuleArtifact) | return none
    unless artifact.schema == artifactSchema do
      return none
    match artifact.interfaceHash with
    | some value =>
      return some (.interfaceHash value)
    | none =>
      return none
  catch _ =>
    return none

/-- What Lake's recorded outputs say about one closure member.

`unreadable` is the degradation an unknown takes; `unbuilt` is not a degradation at all
but a fact, and the difference is worth a filesystem check. On mathlib, one unbuilt module in a
62-file batch used to send every closure through the whole-workspace fallback digest: 7,018 ms, 30%
of a cold `check`. -/
private def memberFact (workspace : Lake.Workspace) (mode : ClosureMode) (name : Lean.Name) :
    IO MemberFact := do
  if mode == .interface then
    if let some fact← memberInterfaceFact workspace name then
      return fact
  let some tracePath := Project.moduleTracePath? workspace name | return .unreadable
  if let some hash← moduleArtifactHash? tracePath then
    return .hash hash
  -- The trace did not yield a hash. Absence of *every* output Lake would write is the one
  -- case that is a fact rather than an unknown, and it is checked here rather than inferred from
  -- the trace alone: an `.olean` sitting next to a missing trace is output whose currency is
  -- unknown.
  let some outputs := Project.moduleOutputPaths? workspace name | return .unreadable
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
private def closureDigest? (workspace : Lake.Workspace) (mode : ClosureMode)
    (memo : IO.Ref (Std.HashMap String MemberFact)) (closure : Option (Array Lean.Name)) :
    IO (Option Digest) := do
  let some members := closure | return none
  let ordered := members.qsort (·.toString < ·.toString)
  let mut parts := #[]
  for name in ordered do
    let key := name.toString
    let fact ←
      do
        if let some hit := (← memo.get)[key]? then
          pure hit
        else
          let computed ← memberFact workspace mode name
          memo.modify (·.insert key computed)
          pure computed
    match fact with
    | .hash hash =>
      parts := parts.push s!"closure {name} {hash}"
    | .interfaceHash value =>
      parts := parts.push s!"closure-interface {name} {value.hex}"
    | .unbuilt =>
      parts := parts.push s!"closure {name} unbuilt"
    | .unreadable =>
      return none
  return some (digestParts parts)

/-- `realPath` for a configured search-path root that may not exist.

Lake puts a directory on the search path whether or not anything has built there yet, so an
absent root is ordinary rather than suspicious. `IO.FS.realPath` throws on one, and that exception
used to escape this function into `ResultCache.open?`'s catch-all and disable the cache for the
**whole project** — silently, since a disabled cache is a supported outcome. Measured on mathlib:
one absent root, and not a single entry was ever written.

Absence is recorded as its own part rather than skipped, so that the root later appearing with
artifacts moves `environment`. A root that *exists* but whose artifacts do not validate used to
return `none` for the whole cache; `oleanPart` now hashes those artifacts instead, for the reason
recorded there. Nothing in this layer can veto the cache any more. -/
private def realPathIfDir? (path : System.FilePath) : IO (Option System.FilePath) := do
  try
    unless ← path.isDir do
      return none
    return some (← IO.FS.realPath path)
  catch _ =>
    return none

/-- The epoch. Total: every input either validates or is hashed, and no input can refuse the
cache for the workspace. The `sysroot` resolution is guarded for the same reason
`realPathIfDir?` exists — an exception here would reach `open?`'s catch-all and read as "no
cache", which is exactly the failure this function stopped having. -/
private def environmentDigest (workspace : Lake.Workspace) : IO Digest := do
  let toolchain ←
    try
      IO.FS.realPath workspace.lakeEnv.lean.sysroot
    catch _ =>
      pure workspace.lakeEnv.lean.sysroot
  let roots := workspace.augmentedLeanPath
  let mut parts :=
    #[s!"lean-version\u0000{Lean.versionString}",
      s!"lean-githash\u0000{workspace.lakeEnv.lean.githash}",
      s!"workspace-configuration\u0000{Project.externalConfigurationIdentity workspace}"]
  parts := parts ++ pathParts "lean-path" workspace.augmentedLeanPath
  parts := parts ++ pathParts "source-path" workspace.augmentedLeanSrcPath
  parts := parts ++ pathParts "shared-path" workspace.augmentedSharedLibPath
  parts := parts ++ pathParts "binary-path" workspace.augmentedPath
  let mut untraced := 0
  -- The workspace's own build directory is skipped here and covered per entry by
  -- `CacheIdentity.closure` instead. It was the *second* whole-project invalidator:
  -- `rootTraceParts` folds every `.olean`'s trace contents into `environment`, `environment`
  -- names the index file, so rebuilding any one module renamed the index and orphaned every entry
  -- — the same defect as the project-source walk, one layer down, and removing only the source
  -- walk would not have fixed it.
  --
  -- Dependency package roots keep the coverage they had. Coverage here is scoped to project
  -- sources, and a dependency's artifacts are an epoch property: they
  -- change when the manifest or a dependency build changes, not when the user edits their own
  -- file.
  let ownLibDir ←
    try
      IO.FS.realPath workspace.root.leanLibDir
    catch _ =>
      pure workspace.root.leanLibDir
  for rawRoot in roots do
    let some root ← realPathIfDir? rawRoot |
      parts := parts.push s!"lean-path-absent\u0000{rawRoot}"
      continue
    if insideToolchain toolchain root || root == ownLibDir then
      continue
    let (rootParts, rootUntraced) ← rootTraceParts root
    parts := parts ++ rootParts
    untraced := untraced + rootUntraced
  for rawRoot in workspace.augmentedSharedLibPath do
    let some root ← realPathIfDir? rawRoot |
      parts := parts.push s!"shared-path-absent\u0000{rawRoot}"
      continue
    if insideToolchain toolchain root then
      continue
    let (rootParts, rootUntraced) ← sharedTraceParts root
    parts := parts ++ rootParts
    untraced := untraced + rootUntraced
  -- Project source *content* deliberately does not appear here. `environment` names the
  -- index file through `baseDigest`, so folding project sources in made one edit rename the index
  -- and orphan every entry. Project-source currency is per entry now, in
  -- `CacheIdentity.closure`. The ordered *paths* above stay: search-path precedence is an epoch
  -- property and changing it changes what every module resolves to.
  recordCount "untraced_artifacts" untraced
  return digestParts parts

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
      closure }

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
  if let some digest← cache.workspaceArtifacts.get then
    return digest
  let digest ←
    withPhase "workspace_artifacts" do
        try
          let root ← IO.FS.realPath workspace.root.leanLibDir
          let (parts, _) ← rootTraceParts root
          pure (some (digestParts parts))
        catch _ =>
          pure none
  cache.workspaceArtifacts.set (some digest)
  return digest

/-- Closure digests for a whole batch, from the run's one shared closure fetch.

`none` at a position means that target's currency could not be established, so it misses on
read and is not written — never that it hits. A workspace module gets the precise per-closure
digest; a standalone file gets `workspaceArtifactsDigest`, which is coarse but sound.

`importClosures` folds the selected modules in whoever asks first, so on a run with FMT004 selected
these names are already resolved and this costs no traversal at all. -/
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
      -- The unresolved closure stays `none` here, and this caller misses. Folding it to `#[]`, as
      -- FMT004 legitimately does with the same fact, would read as "nothing to check" — a
      -- *permissive* answer, and a stale hit is the one direction currency must never degrade
      -- toward. The producer returns the honest `Option` so each caller states its own direction.
      let closures ← withPhase "closure_resolve" <| project.importClosures missing
      for name in missing do
        -- The closure Lake reports is the module's *imports*. Its own artifacts belong in
        -- the digest too: its own `.olean` is what carries the projection being served, so a
        -- rebuild of the module itself must move the key even when nothing it imports changed.
        let closure := (closures[name]?.bind (·.build)).map (·.push name)
        -- Precise when the closure resolves and every member's trace reads; otherwise the
        -- conservative whole-workspace digest rather than a permanent miss. See `fallback` below.
        let digest? ←
          withPhase "closure_hash" <|
              closureDigest? project.workspace cache.closureMode cache.artifactHashByModule closure
        let resolved ←
          match digest? with
          | some digest =>
            pure (some digest)
          | none =>
            fallback
        known := known.insert name.toString resolved
      cache.closureDigestsByModule.set known
    targets.mapM fun target => do
        match target.module? with
        | none =>
          fallback
        | some mod =>
          match known[mod.name.toString]? with
          | some digest? =>
            pure digest?
          | none =>
            fallback
  catch _ =>
    return Array.replicate targets.size none

private def resultDirectory (cache : ResultCache) : System.FilePath :=
  cache.root / "results"

private def baseDigest (cache : ResultCache) : Digest :=
  digestParts
    #[resultCacheSchema, cache.toolchain, toString cache.environment, toString cache.formatter]

private def indexPath (cache : ResultCache) : System.FilePath :=
  resultDirectory cache / s!"{baseDigest cache}.json"

private def validAnalysis (target : Project.SourceTarget) (analysis : SemanticAnalysis) : Bool :=
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
private def indexRetention : Nat :=
  3

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
    let candidates :=
      (← (resultDirectory cache).readDir).filter fun entry =>
        entry.path.extension == some "json" && entry.path.toString != live.toString
    let mut dated := #[]
    for candidate in candidates do
      if let some seconds← modifiedSeconds? candidate.path then
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

/- What the memo below stores: the identity of the binary it hashed, and the hash. -/
private structure FormatterMemo where
  /-- The binary's path, size, and modification time — what used to *be* the identity. -/
  stamp : String
  /-- Its content hash, which is the identity now. -/
  digest : Digest
  deriving Lean.ToJson, Lean.FromJson

/-- The formatter binary's content identity.

**Content, not (path, size, mtime).** Those three were the identity, and they cost a consuming
project its whole cache on every CI run that rebuilds or reinstalls lean-fmt: a new mtime, often a
new path, and every stored entry orphaned — including every stored `CanonicalLayout` — for a binary
that behaves identically. That is the entire cold-run cost, arriving on every CI run for a reason
unrelated to correctness. `docs/ci.md` used to instruct consumers to work around it by caching
`.lake` and `.lean-fmt-cache` under one key so the mtime survived.

**The old objection was about cost per invocation, and the memo answers exactly that.** The
executable statically links Lean's runtime and runs to about 185 MB, so hashing it is not something
to do on every run. But (path, size, mtime) is a fine answer to "has this file changed since I last
hashed it", which is the only question the memo asks. A rebuild pays one hash; every run after it
reads a small file.

`Lake.computeFileHash`, not `Digest.ofString`: the latter is a pure-Lean SHA-256, and 185 MB
through it is not a cost the memo could redeem.

**A memo that cannot be read or written costs the hash and nothing else.** It is an optimization,
and an identity is never inferred from its absence. -/
private def formatterDigest (cacheRoot application : System.FilePath) : IO Digest := do
  let stat ← application.metadata
  let stamp :=
    s!"{application}\u0000{stat.byteSize}\u0000{stat.modified.sec}\u0000{stat.modified.nsec}"
  let memoPath := cacheRoot / "formatter-identity.json"
  let memo? ←
    try
      let contents ← IO.FS.readFile memoPath
      pure
          ((Lean.Json.parse contents).toOption.bind
            (Lean.fromJson? (α := FormatterMemo) · |>.toOption))
    catch _ =>
      pure none
  if let some memo := memo? then
    if memo.stamp == stamp then
      return memo.digest
  let digest ←
    withPhase "formatter_hash" <| do
        return Digest.ofString s!"content\u0000{← Lake.computeFileHash application}"
  try
    IO.FS.createDirAll cacheRoot
    IO.FS.writeFile memoPath (Lean.toJson ({ stamp, digest } : FormatterMemo)).compress
  catch _ =>
    pure ()
  return digest

/- Construct a cache capability over the evaluated workspace's ordered roots and every
non-toolchain module artifact. An artifact whose Lake trace cannot be trusted is folded in by
content rather than refused, so the epoch is total; absence is still a normal disabled-cache
outcome, reached now only by an exception this function did not anticipate. -/
def ResultCache.open? (workspace : Lake.Workspace) (application : System.FilePath)
    (closureMode : ClosureMode := .artifacts) : IO (Option ResultCache) := do
  try
    let environment ← environmentDigest workspace
    -- `toolchain` below pins the toolchain revision separately; this pins the binary.
    let cacheRoot := workspace.root.dir / ".lean-fmt-cache"
    let formatter ← formatterDigest cacheRoot application
    let directoryReady ← IO.mkRef false
    let loadedEntries ← IO.mkRef none
    let workspaceArtifacts ← IO.mkRef none
    let closureDigestsByModule ← IO.mkRef { }
    let artifactHashByModule ← IO.mkRef { }
    return some
        { root := cacheRoot
          toolchain := s!"{Lean.versionString}\u0000{workspace.lakeEnv.lean.githash}"
          environment
          formatter
          closureMode
          directoryReady
          loadedEntries
          workspaceArtifacts
          closureDigestsByModule
          artifactHashByModule }
  catch _ =>
    return none

private def ResultCache.loadEntries (cache : ResultCache) : IO (Std.HashMap String CacheEntry) := do
  if let some entries← cache.loadedEntries.get then
    return entries
  let entries ←
    try
      let contents ← IO.FS.readFile (indexPath cache)
      let .ok json := Lean.Json.parse contents | pure { }
      let .ok (index : CacheIndex) := Lean.fromJson? json | pure { }
      if index.schema != resultCacheSchema || index.base != baseDigest cache then
        pure { }
      else
        pure <|
            index.entries.foldl (init := Std.HashMap.emptyWithCapacity index.entries.size)
              fun entries entry => entries.insert (toString entry.identity) entry
    catch _ =>
      pure { }
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

/-- The per-target lookup walk shared by every read: integrity of the record, then one
caller-supplied decision over the entry in the shared vocabulary and the current observation.

Keeping the walk here and the decisions in `Cache.Decision` is the one-home rule: `readAll`
applies `Entry.identityCurrent` (its `Provided.meets` half runs in `LeanFmt.Application`), and
`probeVerdicts` applies `elaborationVerdict?` — neither re-implements currency. -/
private def ResultCache.lookupAll (cache : ResultCache) (project : Project.Snapshot)
    (targets : Array Project.SourceTarget)
    (decideEntry :
      Cache.Decision.Entry Unit SemanticAnalysis Digest Digest String →
        Cache.Decision.Obs Unit Digest Digest String → Option α) :
    IO (Array (Option α)) := do
  let entries ← cache.loadEntries
  if entries.isEmpty then
    return Array.replicate targets.size none
  let closures ← cache.closureDigests project targets
  (targets.zip closures).mapM fun (target, closure?) => do
      try
        -- Undeterminable currency is an ordinary miss, never a hit. It is not
        -- a cache-disabling condition: one target degrades, the rest of the batch is unaffected.
        let some closure := closure? | return none
        let expected ← identity cache project target closure
        let digest := cacheIdentityDigest expected
        let some entry := entries.get? (toString digest) | return none
        -- Integrity of the record, which is not currency: the payload digest and
        -- `validAnalysis` catch a truncated or mismatched entry, and `identity` confirms the hash
        -- probe found the entry it meant to.
        unless
          entry.identity == digest && entry.payload == analysisDigest entry.analysis &&
            validAnalysis target entry.analysis do
          return none
        return decideEntry (entryDecision entry) (observation target closure)
      catch _ =>
        return none

def ResultCache.readAll (cache : ResultCache) (project : Project.Snapshot)
    (targets : Array Project.SourceTarget) : IO (Array (Option SemanticAnalysis)) :=
  -- Currency is `Cache.Decision.Entry.identityCurrent`, the function
  -- `LeanFmt.Cache.Spec` proves `serves_sound` and `serves_complete` about. The other half of
  -- `Decision.serves` — `Provided.meets` — runs in `LeanFmt.Application`, which is where the
  -- rule plan is known.
  cache.lookupAll project targets fun entry obs =>
    if entry.identityCurrent obs then some entry.analysis else none

/-- The organize verdict probe: for each candidate target, the stored verdict about those bytes,
paired with the analysis that recorded it (a rejection's diagnostics are its report).

The decision is `Cache.Decision.elaborationVerdict?`, the function `LeanFmt.Cache.Spec` proves
`verdict_sound` and `verdict_complete` about. `none` is a miss — validate. `unbuilt` is never
in the store (`storableAnalysis`), so a missing dependency olean can only ever miss here and be
validated again, never mistaken for a rejection. -/
def ResultCache.probeVerdicts (cache : ResultCache) (project : Project.Snapshot)
    (targets : Array Project.SourceTarget) :
    IO (Array (Option (Cache.Decision.ElabVerdict × SemanticAnalysis))) :=
  cache.lookupAll project targets fun entry obs =>
    (Cache.Decision.elaborationVerdict? entry obs).map (·, entry.analysis)

private def ResultCache.ensureWriteDirectory (cache : ResultCache) : IO Unit := do
  unless ← cache.directoryReady.get do
    IO.FS.createDirAll (resultDirectory cache)
    cache.directoryReady.set true

/-- May this analysis be stored at all?

A broken analysis is a fact about the bytes — they did not elaborate — and is stored (it is
organize's rejection verdict). An *unbuilt* analysis carries no information about the bytes: the
dependency olean was missing, so the frontend never reached them. Storing one would poison every
later probe with a non-verdict, so it is the one outcome class `writeAll` refuses. -/
private def storableAnalysis (analysis : SemanticAnalysis) : Bool :=
  (unbuiltDependency? analysis.diagnostics).isNone

/-- Merge two analyses recorded under **one identity key** — same source bytes, same closure,
same configuration — so that storing keeps every capability either run computed.

The write-side invariant of the persistent cache: per key, what an entry `providedOf` is
monotone over time. Before this, `writeAll`'s bare insert let a run overwrite an entry with a
strictly poorer analysis of the same bytes (a validation capturing no canonical text displacing
one that did), and the next run that needed the displaced capability paid a frontend run for
nothing. `Cache.Spec` quantifies over the read decision and is untouched; this is the half that
makes writes preserve what reads rely on.

- A success is strictly more informative than a broken record: under one identity the pair can
  only arise through resource flakiness (a heartbeat-bound elaboration succeeding on retry), and
  the success is the sound direction to keep.
- Both success: keep the analysis that serves everything the other serves (`Tier.satisfies` and
  `SemanticCaps.subset`, the same order `Provided.meets` applies), grafting `canonical?` from
  the other when absent. Canonical text is a deterministic function of the source bytes and the
  format configuration — both pinned by the shared key — so the graft is exactly what a fresh
  render would produce.
- No capture mode today produces an incomparable (tier, caps) pair; if one ever does, keep the
  fresher analysis. The displaced capability misses and recomputes — the merge may never claim
  a capability no single analysis carries, and a miss is the safe direction. -/
private def mergeAnalysis (old new : SemanticAnalysis) : SemanticAnalysis :=
  match old.result?, new.result? with
  | none, some _ => new
  | some _, none => old
  | none, none => new
  | some oldResult, some newResult =>
    let canonical? := newResult.canonical?.or oldResult.canonical?
    if newResult.tier.satisfies oldResult.tier && oldResult.caps.subset newResult.caps then
      { new with result? := some { newResult with canonical? } }
    else
      if oldResult.tier.satisfies newResult.tier && newResult.caps.subset oldResult.caps then
        { old with result? := some { oldResult with canonical? } }
      else { new with result? := some { newResult with canonical? } }

/-- The identity keys a full-project run can still serve: every current target's own key, and
the key of each target's organize candidate — a stored rejection verdict has a consumer exactly
while the header on disk still computes to that candidate (`Imports.organizeCandidate?`, the one
definition both sides use).

`none` when any closure digest is unresolved: pruning without knowing a target's live key would
delete its entry out of ignorance, and the minimum-storage rule deletes only what no run can ask
for again. -/
private def ResultCache.liveDigests? (cache : ResultCache) (project : Project.Snapshot) :
    IO (Option (Std.HashSet String)) := do
  let targets := project.targets
  let closures ← cache.closureDigests project targets
  let mut live : Std.HashSet String := { }
  for (target, closure?) in targets.zip closures do
    let some closure := closure? | return none
    let expected ← identity cache project target closure
    live := live.insert (toString (cacheIdentityDigest expected))
    if let some output←
        Imports.organizeCandidate? target.source target.config.format.importLayout
          target.config.format.importGroups then
      let candidateExpected ← identity cache project (target.withSource output) closure
      live := live.insert (toString (cacheIdentityDigest candidateExpected))
  return some live

/- Merge and atomically publish an ordered batch once. Cache failure never changes successful
analysis; the next run simply observes the previous index or an empty cache. -/
def ResultCache.writeAll (cache : ResultCache) (project : Project.Snapshot)
    (targets : Array Project.SourceTarget) (analyses : Array (Option SemanticAnalysis))
    (prune : Bool := false) : IO Unit := do
  try
    let mut entries ← cache.loadEntries
    let closures ← withPhase "write_closures" <| cache.closureDigests project targets
    for ((target, analysis?), closure?) in (targets.zip analyses).zip closures do
      let some analysis := analysis? | continue
      unless validAnalysis target analysis && storableAnalysis analysis do
        continue
      -- A target whose currency could not be established is not written. Writing it under
      -- a placeholder closure would make it indistinguishable from a genuinely current entry on
      -- the next run, which is the stale hit this cache exists to remove.
      let some closure := closure? | continue
      let expected ← identity cache project target closure
      let digest := cacheIdentityDigest expected
      -- Merge, never replace: an entry already at this key recorded capabilities of these same
      -- bytes this run did not recompute (monotone writes — see `mergeAnalysis`).
      let analysis :=
        match entries.get? (toString digest) with
        | some old => mergeAnalysis old.analysis analysis
        | none => analysis
      let entry : CacheEntry :=
        { schema := resultCacheSchema
          identity := digest
          payload := analysisDigest analysis
          sourceDigest := expected.source
          closureDigest := expected.closure
          analysis }
      entries := entries.insert (toString digest) entry
    -- The minimum-storage rule: an entry lives exactly while some run can ask for it — a current
    -- target's own bytes, or a current organize candidate's. Only a full-project write prunes:
    -- a file-targeted run cannot tell "deleted" from "not in my selection".
    if prune then
      match ← cache.liveDigests? project with
      | some live =>
        let before := entries.size
        entries := entries.filter fun key _ => live.contains key
        recordCount "entries_pruned" (before - entries.size)
      | none =>
        pure ()
    cache.ensureWriteDirectory
    let ordered :=
      entries.toList.toArray.map (·.2) |>.qsort (toString ·.identity < toString ·.identity)
    let index : CacheIndex :=
      { schema := resultCacheSchema
        base := baseDigest cache
        entries := ordered }
    writeIndexAtomic (indexPath cache) index
    recordCount "cache_bytes" (← (indexPath cache).metadata).byteSize.toNat
    collectStaleIndexes cache
    cache.loadedEntries.set (some entries)
  catch _ =>
    return

end LeanFmt.Internal
