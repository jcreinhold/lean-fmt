module

import all LeanFmt.Cache
import all LeanFmt.Config
import all LeanFmt.Edit
import all LeanFmt.Imports
import all LeanFmt.Printer
import all LeanFmt.Project
import all LeanFmt.Semantic
import all LeanFmt.Suppression
import Lake.Build.Module
import Lake.Build.Run
import Lake.Config.Env
import Lake.Config.InstallPath
import Lake.Load.Workspace
import Lean.Util.Diff
import all Lean.Shell

open System

namespace LeanFmt.Internal.Application

inductive RunMode where
  | check
  | format
  | diff
  | fix
  deriving BEq

def RunMode.toString : RunMode → String
  | .check => "check"
  | .format => "format"
  | .diff => "diff"
  | .fix => "fix"

/-- Whether this mode's answer contains canonical text, and therefore needs a projection to render.

`format` and `diff` render it; `check` and `fix` do not. `check` reports selected rules and a
badly-laid-out but lint-clean file is `check`-clean. `fix` stopped rendering at `ruff-11c` RDF-IMPL: it
applies admitted rule fixes at the file's **original** coordinates and does not reflow, mirroring
`ruff check --fix` (the user composes `fix` then `format` for both). So a fixed file keeps its layout
until `format` runs, and a fix `Edit` lands on the bytes the user sees. Keeping `check`/`fix` off this
path is also what lets them take the source-only fast path on a source-only selection, which needs no
artifact at all. -/
def RunMode.rendersCanonical : RunMode → Bool
  | .check | .fix => false
  | .format | .diff => true

structure RunRequest where
  mode : RunMode
  root : FilePath
  files : Array FilePath
  maxMemoryGiB : Nat := 8
  cache : Bool := true
  configPath? : Option FilePath := none
  select : Array String := #[]
  ignore : Array String := #[]
  /-- Lifecycle/fixability selection (`ruff-12` RRL-IMPL), threaded verbatim into `FormatterConfig.rulePlan`
  through a `CliSelection`. `extendSelect` adds to the selection; `fixable`/`unfixable`/`extendFixable`
  choose which selected rules' fixes `fix` applies; `preview` unlocks preview rules. -/
  extendSelect : Array String := #[]
  fixable : Array String := #[]
  unfixable : Array String := #[]
  extendFixable : Array String := #[]
  preview : Bool := false
  /-- Apply unsafe fixes too, not just safe ones. Governs which fixes `fix` admits into its patch (and
  `check`'s preview of it), never relaxing validation or conflict rejection. Since `ruff-11c` the
  rendering modes carry no rule fix — `format` publishes only layout (`ruff-11d`), `diff` diffs only
  layout — so this flag only shapes their reported withheld-unsafe count, not their bytes. Display-only
  fixes are unaffected: nothing applies them. -/
  unsafeFixes : Bool := false
  validationLevel : ValidationLevel := .syntax
  /-- `format --check` (`ruff-11d` FIP-IMPL): the non-writing CI preview. Meaningful only for `.format`.
  When `false` (the default), `format` publishes the canonical layout in place through the `ruff-06`
  guarded path — the same publisher `fix` uses. When `true`, `format` renders but writes nothing and
  reports `would-format`/`clean`, exactly the pre-`ruff-11d` default. `check`/`diff`/`fix` ignore it. -/
  formatCheck : Bool := false

/-- Whether this run publishes source. `fix` always does; `format` does unless `--check` demotes it to a
preview (`ruff-11d` FIP-IMPL). A writer needs the validator child, so it must fall through to
`withExactRun` and stay off the cache-only preview fast paths — the one place the `--check` disposition
reaches the driver, not just `Cli.lean`. `check`/`diff` never write. -/
def RunRequest.writesFormat (request : RunRequest) : Bool :=
  request.mode == .format && !request.formatCheck

private abbrev SourceSnapshot := Project.SourceTarget

structure FileReport where
  path : String
  status : String
  findings : Array Finding := #[]
  diagnostics : Array String := #[]
  formatted : Option String := none
  diff : Option String := none
  written : Bool := false
  /-- Fixes this file has that were withheld because they are unsafe and `--unsafe-fixes` was off.
  Zero once the run opts in. It is what tells a user what `--unsafe-fixes` would add rather than
  leaving the withheld fixes invisible. -/
  withheldUnsafe : Nat := 0
  /-- Findings this file's source-suppression directives removed from the report. It is the visible
  cost of the directives — a nonzero count with an empty finding list means the file is clean only
  because it was told to be. -/
  suppressed : Nat := 0
  /-- Redundant-import (FMT006) candidates *withheld* from the report because a modifier or role
  reachability cannot reason about (`import all`, `meta import`, a re-exported `public import`) makes
  them unsafe even to name. Recorded, never silent — `RIR-FINAL` audits this count. -/
  withheldRedundant : Nat := 0
  deriving Lean.ToJson

structure RunReport where
  mode : String
  files : Array FileReport
  findings : Nat
  changed : Nat
  written : Nat
  broken : Nat
  rejected : Nat
  withheldUnsafe : Nat
  suppressed : Nat
  withheldRedundant : Nat
  infrastructureFailures : Array String
  deriving Lean.ToJson

private structure ChildOutput where
  exitCode : UInt32
  stdout : String
  stderr : String
  peakAggregateRssKiB : Nat

/- A valid exact-analysis capability. Construction brackets its temporary storage, fixes the target
project/toolchain and aggregate envelope once, and owns collision-free request names. No caller can
observe setup paths or sequence cleanup. Each analysis still receives a fresh child process. -/
structure ExactRun where
  private mk ::
  project : Project.Snapshot
  application : FilePath
  temporary : FilePath
  maxBytes : Nat
  nextIndex : IO.Ref Nat

private structure FacetDescriptor where
  hash : String
  ext : String
  path : String
  deriving Lean.FromJson

private def decodeFacetDescriptor? (encoded : String) : Option Lake.Artifact := do
  let json ← Lean.Json.parse encoded |>.toOption
  let descriptor : FacetDescriptor ← Lean.fromJson? json |>.toOption
  let hash ← Lake.Hash.ofString? descriptor.hash
  guard <| !descriptor.path.isEmpty
  return {
    descr := Lake.artifactWithExt hash descriptor.ext
    path := FilePath.mk descriptor.path
    mtime := 0
  }

private def withoutProcessOutput (action : IO α) : IO α := do
  let buffer ← IO.mkRef { : IO.FS.Stream.Buffer }
  let stdout ← IO.setStdout (.ofBuffer buffer)
  let stderr ← IO.setStderr (.ofBuffer buffer)
  try action finally
    discard <| IO.setStdout stdout
    discard <| IO.setStderr stderr

/- Fetch the target workspace's registered formatter facet jobs together under Lake's no-build
policy. Returned descriptors never escape this operation: every content hash is recomputed and
every payload is matched to its immutable module/source snapshot. A missing, stale, corrupt, or
failing facet is an ordered miss, never an extractor launch or a partial batch failure.

**`checkNoBuild` before `runBuild`, and the `catch` cannot replace it.** Under `noBuild`, a target
that is out of date makes `finalizeBuild` call `IO.Process.exit noBuildCode` — `Lake/Build/Run.lean:368`,
and `noBuildCode` is 3 (`:275`). That is a process exit, not an exception: nothing below catches it,
`withoutProcessOutput` is still holding stdout and stderr in a buffer that is never flushed, and the
run dies silently mid-batch. `checkNoBuild` asks the same question and returns a `Bool` (`:405-414`),
so it is the only safe way to reach `runBuild` here. `Project.exactSetup` and `compilerStatus` already
guard this way; this operation did not, and could not have been caught doing it: every registry rule
is `input := .source`, so `RulePlan.requiresSyntax` was always `false` and no product path ever called
this with a stale module until `RFP-IMPL` made rendering modes need a projection. The claim above was
false the whole time and nothing was exercising it. -/
def officialArtifacts (workspace : Lake.Workspace)
    (snapshots : Array SourceSnapshot) : IO (Array (Option ModuleArtifact)) := do
  if (← IO.getEnv "LEAN_FMT_DISABLE_ARTIFACT") == some "1" then
    return Array.replicate snapshots.size none
  let facetName := `module.leanFmtArtifact
  let some config := workspace.findModuleFacetConfig? facetName
    | return Array.replicate snapshots.size none
  let build : Lake.FetchM (Lake.Job (Array (Option String))) := do
    let jobs ← snapshots.mapM fun snapshot => do
      match snapshot.module? with
      | none => return Lake.Job.pure none
      | some mod =>
        let job ← config.run (β := Lake.FacetOut facetName) mod
        return job.mapResult fun
          | .ok value state => .ok (some (config.format .json value)) state
          | .error _ state => .ok none state
    return Lake.Job.collectArray jobs "lean-fmt official artifacts"
  try
    withoutProcessOutput do
      unless ← workspace.checkNoBuild build do
        return Array.replicate snapshots.size none
      let encoded ← workspace.runBuild (cfg := { noBuild := true, verbosity := .quiet }) build
      (snapshots.zip encoded).mapM fun (snapshot, encoded?) => do
        let some mod := snapshot.module?
          | return none
        let some encoded := encoded?
          | return none
        let some facet := decodeFacetDescriptor? encoded
          | return none
        readFacet? facet mod.name snapshot.source
  catch _ =>
    return Array.replicate snapshots.size none

private def writeSetup (directory : FilePath) (index : Nat)
    (setup : Lean.ModuleSetup) : IO FilePath := do
  let path := directory / s!"{index}.setup.json"
  IO.FS.writeFile path (Lean.toJson setup).compress
  return path

private def diagnosticSetup (snapshot : SourceSnapshot) : Lean.ModuleSetup :=
  match snapshot.module? with
  | some mod => {
      name := mod.name
      package? := mod.pkg.id?
      isModule := true
      options := mod.leanOptions
    }
  | none => { name := `_unknown }

private def exactSetupResult (project : Project.Snapshot)
    (snapshot : SourceSnapshot) : IO (Except IO.Error Lean.ModuleSetup) :=
  try
    return Except.ok (← Project.exactSetup project snapshot)
  catch error =>
    return Except.error error

private def residentKiB : IO Nat := do
  let pid ← IO.Process.getPID
  let output ← IO.Process.output {
    cmd := "/bin/ps"
    args := #["-o", "rss=", "-p", toString pid]
  }
  unless output.exitCode == 0 do
    throw <| IO.userError s!"could not sample parent RSS: {output.stderr.trimAscii}"
  let some value := output.stdout.trimAscii.toNat?
    | throw <| IO.userError "could not parse parent RSS"
  return value

private def processGroupRssKiB (processGroup : UInt32) : IO Nat := do
  let output ← IO.Process.output { cmd := "/bin/ps", args := #["-axo", "pgid=,rss="] }
  unless output.exitCode == 0 do
    throw <| IO.userError s!"could not sample child process group RSS: \
      {output.stderr.trimAscii}"
  return output.stdout.splitOn "\n" |>.foldl (init := 0) fun total line =>
    let fields := line.trimAscii.copy.splitOn " " |>.filter (!·.isEmpty)
    match fields with
    | [group, rss] =>
      if group.toNat? == some processGroup.toNat then total + rss.toNat?.getD 0 else total
    | _ => total

private def awaitRead (task : Task (Except IO.Error String)) : IO String := do
  match ← IO.wait task with
  | .ok contents => return contents
  | .error error => throw error

private partial def monitorChild (child : IO.Process.Child {
      stdin := .inherit, stdout := .piped, stderr := .piped })
    (stdoutTask stderrTask : Task (Except IO.Error String))
    (maxBytes peakKiB : Nat) : IO ChildOutput := do
  match ← child.tryWait with
  | some exitCode =>
    return {
      exitCode
      stdout := ← awaitRead stdoutTask
      stderr := ← awaitRead stderrTask
      peakAggregateRssKiB := peakKiB
    }
  | none =>
    let aggregateKiB := (← residentKiB) + (← processGroupRssKiB child.pid)
    let peakKiB := max peakKiB aggregateKiB
    if aggregateKiB * 1024 > maxBytes then
      try child.kill catch _ => pure ()
      discard child.wait
      discard <| awaitRead stdoutTask
      discard <| awaitRead stderrTask
      throw <| IO.userError s!"resource envelope exhausted during exact frontend child \
        ({aggregateKiB} KiB > {maxBytes / 1024} KiB)"
    IO.sleep 50
    monitorChild child stdoutTask stderrTask maxBytes peakKiB

private def runBounded (arguments : IO.Process.SpawnArgs)
    (maxBytes : Nat) : IO ChildOutput := do
  let child ← IO.Process.spawn {
    cmd := arguments.cmd
    args := arguments.args
    cwd := arguments.cwd
    env := arguments.env
    inheritEnv := arguments.inheritEnv
    stdin := .inherit
    stdout := .piped
    stderr := .piped
    setsid := true
  }
  let stdoutTask ← IO.asTask child.stdout.readToEnd
  let stderrTask ← IO.asTask child.stderr.readToEnd
  monitorChild child stdoutTask stderrTask maxBytes 0

private def ExactRun.nextPathIndex (run : ExactRun) : IO Nat :=
  run.nextIndex.modifyGet fun index => (index, index + 1)

private def ExactRun.envelope (run : ExactRun)
    (snapshot : SourceSnapshot) (captureSemantic : Bool) (validator := false)
    (captureOccurrences : Bool := false) : IO AnalysisEnvelope := do
  let index ← run.nextPathIndex
  let setupResult ← exactSetupResult run.project snapshot
  let setup := match setupResult with
    | .ok setup => setup
    | .error _ => diagnosticSetup snapshot
  let setupPath ← writeSetup run.temporary index setup
  let sourcePath := run.temporary / s!"{index}.lean"
  IO.FS.writeFile sourcePath snapshot.source
  try
    if (← residentKiB) * 1024 >= run.maxBytes then
      throw <| IO.userError s!"resource envelope exhausted before exact frontend child \
        (limit {run.maxBytes} bytes)"
    let overrideName := if validator then "LEAN_FMT_TEST_VALIDATOR" else "LEAN_FMT_TEST_ANALYZER"
    let analyzer := (← IO.getEnv overrideName).map FilePath.mk |>.getD run.application
    let output ← runBounded {
      cmd := analyzer.toString
      -- The trailing capture token encodes the demanded semantic capabilities: "0" none, "1" the two
      -- cheap sub-facts (notations + diagnostics), "2" those plus the info-tree occurrence fold. A
      -- direct 4-argument invocation (every syntax-only harness) omits it and captures nothing.
      -- `occurrences` is only ever demanded together with the tier, so the token is a simple ladder.
      args := #["__analyze-exact", setupPath.toString, sourcePath.toString,
        snapshot.path.toString, toString run.maxBytes,
        if captureOccurrences then "2" else if captureSemantic then "1" else "0"]
      env := run.project.workspace.augmentedEnvVars.push ⟨"LEAN_NUM_THREADS", some "1"⟩
    } run.maxBytes
    unless output.exitCode == 0 do
      throw <| IO.userError s!"exact frontend child failed for {snapshot.relativePath}: \
        {output.stderr.trimAscii}"
    let .ok json := Lean.Json.parse output.stdout
      | throw <| IO.userError s!"exact frontend child returned invalid JSON for \
        {snapshot.relativePath}"
    let .ok envelope := Lean.fromJson? json
      | throw <| IO.userError s!"exact frontend child returned an invalid result for \
        {snapshot.relativePath}"
    if let .error setupError := setupResult then
      if envelope.artifact?.isSome then
        throw <| IO.userError s!"could not establish the exact Lake setup for \
          {snapshot.relativePath}: {setupError}"
    return envelope
  finally
    if ← setupPath.pathExists then IO.FS.removeFile setupPath
    if ← sourcePath.pathExists then IO.FS.removeFile sourcePath

/-- The margin `Printer.format` is rendered at.

`RLF-REFLOW` fired the trigger the older wording named: `Printer.termDoc` now emits `group`/`nest`/`line`
for over-margin applications, so this value *does* change bytes — `Doc.go`'s `.group` fit test
(`Doc.lean:219-229`) breaks a single-line app onto indented continuation lines exactly when its flat
width exceeds this margin. The pre-reflow docstring's premise ("emits no `group`, so every margin
produces identical output") is therefore retired.

It stays a compile-time constant rather than a runtime `line-width` configuration key, and cache identity
stays sound *without* a new component, because the constant is compiled into the application binary and
the `formatter` cache-identity component already hashes that binary
(`formatter := Digest.ofBytes (← IO.FS.readBinFile application)`, `Cache.lean:258`). A margin change is
reachable only by editing this constant and recompiling, which changes the binary, which changes the
`formatter` digest, which invalidates every cached `CanonicalText` rendered at the old margin. The older
wording's fear — "stale under an identity that never mentioned it" — was mistaken about the digest's
scope: the identity mentions the whole binary, this constant included.

The next trigger, unfired: promoting the margin to a *runtime* project-overridable key (a `line-width`
TOML value threaded through `FormatterConfig`) would break that argument, because a runtime override
changes output without changing the binary, so the `formatter` digest would no longer see it. Whoever
adds that key adds its own cache-identity input — folding the resolved margin into the `configuration`
digest (`Project.configurationIdentity`, `Cache.lean:207`) — in the same commit. No caller does today:
`renderCanonicalText` below is the sole production caller and the tests drive width through `format`'s
required parameter directly, so there is no per-project override to hide and none is added speculatively.
The value 100 matches mathlib's own text-linter convention and is otherwise arbitrary. -/
def canonicalWidth : Nat := 100

/-- Render a validated artifact's projection to canonical layout text — the layout, and only the layout.

No rule runs here. Since `ruff-11c` RDF-IMPL the canonical text carries no findings: `format`/`diff`
render this text and report `result.findings` at **original** coordinates (drawn one level up in
`prepareFile`), and every fix lands at original coordinates through `fix`, never on these moved bytes.
The retired `runSourceRules text` here was the source-rule surface that only ever fed the old
canonical-patch, and `ExactRun.reprojectCanonical` — which re-projected the whole registry over the
*rendered* text so a syntax/semantic fix landed in canonical coordinates — retired with it. The
"re-project, don't translate onto moved bytes" model (`ruff-06-fix-safety/notes/01-model.md` §3) still
holds; RDF-IMPL satisfies it the other way, by never moving the bytes a fix indexes. -/
private def renderCanonicalText (raw : String) (artifact : ModuleArtifact) : IO CanonicalText := do
  let normalized := (LosslessSource.normalize raw).1
  let text ← Printer.format artifact.source normalized canonicalWidth artifact.semantic
  return { text }

private def canonicalAnalysis (snapshot : SourceSnapshot) (renderCanonical : Bool)
    (analysis : AnalysisEnvelope) : IO SemanticAnalysis := do
  match SemanticAnalysis.ofEnvelope? snapshot.source analysis with
  | some semantic =>
    -- `ofEnvelope?` has already checked `structurallyValid` and `validFor`, so the projection is
    -- known to describe these bytes before anything renders it.
    if renderCanonical then
      if let some artifact := analysis.artifact? then
        return semantic.withCanonical (← renderCanonicalText snapshot.source artifact)
    return semantic
  | none => throw <| IO.userError s!"invalid exact analysis for {snapshot.relativePath}"

/-- Analyze one snapshot: build the exact envelope the plan demanded and project it, rendering canonical
layout when `renderCanonical`.

Every finding — source, syntax, and the owned `.semantic` FMT014 rename — is computed once, on the
**original** projection (`canonicalAnalysis` → `ofEnvelope?`), at the file's own coordinates, and `fix`
applies it there. `ruff-11c` RDF-IMPL retired `reprojectCanonical`, which re-ran the whole registry over
the *rendered* text so a fix could land in canonical coordinates: with the layout/fix split, no fix is
computed or applied at canonical coordinates, so there is nothing to re-project. `captureOccurrences`
still gates the info-tree fold that supplies FMT014's occurrence at original coordinates (the walk
already runs here for diagnostics); `captureSemantic` and `validator` are unchanged. -/
def ExactRun.analyzeSnapshot (run : ExactRun) (snapshot : SourceSnapshot)
    (renderCanonical : Bool) (validator := false)
    (captureSemantic : Bool := false) (captureOccurrences : Bool := false) : IO SemanticAnalysis := do
  canonicalAnalysis snapshot renderCanonical
    (← run.envelope snapshot captureSemantic validator captureOccurrences)

/- Bracket a complete exact-analysis run. The capability is constructed only after a real fallback
or editor request needs it; cache-only and ordinary-evidence batch runs create no temporary state. -/
def withExactRun (project : Project.Snapshot) (maxMemoryGiB : Nat)
    (action : ExactRun → IO α) : IO α := do
  unless maxMemoryGiB > 0 do
    throw <| IO.userError "--max-memory must provide a nonzero operating envelope"
  let configuredMaxBytes := maxMemoryGiB * 1024 * 1024 * 1024
  let maxBytes := ((← IO.getEnv "LEAN_FMT_TEST_MAX_BYTES").bind (·.toNat?))
    |>.getD configuredMaxBytes
  let temporary ← IO.FS.createTempDir
  let nextIndex ← IO.mkRef 0
  let run : ExactRun := {
    project
    application := ← IO.appPath
    temporary
    maxBytes
    nextIndex
  }
  try action run finally IO.FS.removeDirAll temporary

/-- Whether a cached answer can serve this run.

A `broken` entry always can: it records that the file did not analyze, which no amount of canonical
text would change. A successful entry cannot serve a rendering mode unless it carries the canonical
text that mode must print — a `check` run caches an entry with `canonical? := none`, and treating that
as a hit for `format` would report every file clean. Insufficient is a miss, not an answer. -/
private def cacheHitServes (requiredTier : Tier) (demandedCaps : SemanticCaps) (renderCanonical : Bool)
    (analysis : SemanticAnalysis) : Bool :=
  match analysis.result? with
  | none => true
  | some result =>
    -- Tier gate: a `.source` shortcut entry computed no syntax findings, so it cannot serve a run that
    -- selects a syntax rule. A `.syntax` entry (whole registry over the projection) serves everything.
    -- A `broken` entry (`none`) serves any run — a file that did not analyze did not analyze at any
    -- tier. Without this clause, shipping the first syntax rule would let a source-only `check` poison
    -- a later `--select FMT010` into a persisted false clean.
    --
    -- Caps gate (`ruff-11b` Design B): orthogonal to the tier, a `.semantic` entry serves a run only
    -- when it captured every sub-fact the run demanded. `demandedCaps` is `{}` for a source/syntax run
    -- (subset of anything), so this only ever adds a miss: a fixable-FMT014 demand
    -- (`demandedCaps.occurrences`) against a monolithic-era `.semantic` entry (`caps.occurrences =
    -- false`) misses and recomputes rather than serving a false clean.
    (!renderCanonical || result.canonical?.isSome) && result.tier.satisfies requiredTier
      && demandedCaps.subset result.caps

private def availableAnalysis (plan : RulePlan) (renderCanonical applies : Bool)
    (evidence : Project.ModuleEvidence)
    (snapshot : SourceSnapshot) (cached? : Option SemanticAnalysis)
    (officialArtifact? : Option ModuleArtifact) : IO (Option SemanticAnalysis) := do
  if let some analysis := cached? then
    if cacheHitServes plan.requiredTier (plan.demandedCaps renderCanonical applies) renderCanonical
        analysis then
      return some analysis
  if plan.requiredTier == .source && !renderCanonical && evidence == .current
      && !Suppression.mayContainDirective snapshot.source then
    -- Source rules index the normalized string, so this shortcut and the artifact path produce
    -- findings in one coordinate system and remain interchangeable in the result cache. They are
    -- also now the same call: `runRules` folds over the one registry either way, so this path can
    -- no longer decide a rule differently from the artifact path. It used to, by passing a literal
    -- `true` where the artifact path passed the artifact's own flag (`notes/01-rule-facts.md` §2).
    -- Gated on `renderCanonical` because it takes no artifact, and canonical text cannot be
    -- rendered without the projection an artifact carries. `check` and — since `ruff-11c` RDF-IMPL —
    -- `fix` both reach it on a source-only selection: `fix` no longer renders, so a `fix --select FMT005`
    -- takes the shortcut and applies the dedup at original coordinates without a frontend run. Also
    -- gated on the absence of a directive sigil: suppression is parsed only from the syntax projection
    -- (`ofEnvelope?`), so a directive-bearing file must take the artifact path even when its selected
    -- rules are all source-tier — otherwise its `SuppressionFacts` would default empty and the directive
    -- silently do nothing. `mayContainDirective` is a superset test, so this over-fetches only on files
    -- that mention the sigil without a valid directive, never under-fetches.
    let normalized := (LosslessSource.normalize snapshot.source).1
    return some <| SemanticAnalysis.success normalized (runSourceRules normalized)
  else if let some artifact := officialArtifact? then
    -- A non-rendering syntax/semantic run with a current artifact — `check`/`fix --select FMT01x` — is
    -- served here from the plugin projection, no frontend run. Since `ruff-11c` RDF-IMPL there is no
    -- longer a syntax branch that declines here to force an `ExactRun` re-projection: it retired with
    -- `reprojectCanonical` (no fix is computed at canonical coordinates), so a syntax `--select` costs
    -- one artifact read, never a second frontend pass. A *rendering* run (`format`/`diff`) never reaches
    -- this branch: it demands `.semantic` for notation-aware layout (`RulePlan.demandedTier`), the plugin
    -- artifact carries no `semantic` (`ruff-05b`), so the driver fetches no artifact for it and it takes
    -- its single `analyzeExact` run — the same one it always owed, with no added run for the selection.
    return some (← canonicalAnalysis snapshot renderCanonical { artifact? := some artifact })
  else
    return none

private structure DiffSource where
  lines : List String
  finalNewline : Bool

private def diffSource (source : String) : DiffSource :=
  if source.isEmpty then
    { lines := [], finalNewline := false }
  else
    let finalNewline := source.endsWith "\n"
    let pieces := source.splitOn "\n"
    { lines := if finalNewline then pieces.dropLast else pieces, finalNewline }

/-- A line, paired with whether the file ends right here with no terminating newline.

The flag is part of the line's **identity**, not decoration, and that is the whole reason this type
exists. `diffSource` reads the terminator into `finalNewline` and drops it from `lines`, so `"a\n"`
and `"a"` both project to `["a"]`. A diff over bare strings would pair them as unchanged and print
nothing — for the one edit `FMT002` exists to make. Carrying the flag into the compared element makes
those two lines unequal, so the edit appears. It also lands the `\ No newline` marker correctly for
free: it belongs to whichever side holds the flag. -/
private abbrev DiffLine := String × Bool

private def diffLines (source : DiffSource) : Array DiffLine :=
  let lines := source.lines.toArray
  lines.mapIdx fun index line => (line, !source.finalNewline && index + 1 == lines.size)

/-- Lines of unchanged context around each change, as `diff -U3` and every review tool default to. -/
private def diffContext : Nat := 3

/-- Render an edit script as unified diff.

`Lean.Diff.diff` (`Lean/Util/Diff.lean:170`) supplies the edit script — a histogram diff, the family
`git diff --histogram` uses. Only the hunking is ours: core's `linesToString` (`:201`) prints the whole
script with `-`/`+`/` ` markers and no `@@` headers, which is not a format any tool consumes.

This replaced a `unifiedDiff` that was not a diff: it emitted every old line as `-` and every new line
as `+` under one synthesized header, having never looked for a common line. That was correct output —
applying it reproduces the file — and useless, because a one-line change reprinted the file. It only
ever ran on `FMT001`/`FMT002` fixes, so it was tolerable; `RFP-IMPL` points `diff` at canonical layout
and makes it the surface on which formatting is reviewed, where a whole-file rewrite defeats the mode's
only purpose. The roadmap names `diffs` in this claim's contract, so it is fixed here rather than left. -/
private def unifiedDiff (path before after : String) : String := Id.run do
  let old := diffLines (diffSource before)
  let new := diffLines (diffSource after)
  let script := Lean.Diff.diff old new
  -- How many lines of each side precede entry `i`. Line numbers in a hunk header are counted, not
  -- searched for: an entry absent from one side still has a position *in* that side, and it is the
  -- count of what came before it.
  let mut oldBefore : Array Nat := Array.emptyWithCapacity script.size
  let mut newBefore : Array Nat := Array.emptyWithCapacity script.size
  let mut oldSeen := 0
  let mut newSeen := 0
  for (action, _) in script do
    oldBefore := oldBefore.push oldSeen
    newBefore := newBefore.push newSeen
    match action with
    | .skip => oldSeen := oldSeen + 1; newSeen := newSeen + 1
    | .delete => oldSeen := oldSeen + 1
    | .insert => newSeen := newSeen + 1
  -- Windows of `diffContext` around every change, merged where they touch. Two changes closer than
  -- `2 * diffContext` share a hunk rather than repeating the context between them.
  let mut ranges : Array (Nat × Nat) := #[]
  for index in [0:script.size] do
    if script[index]!.1 != .skip then
      let start := index - min index diffContext
      let stop := min (script.size - 1) (index + diffContext)
      match ranges.back? with
      | some (previousStart, previousStop) =>
        if start ≤ previousStop + 1 then
          ranges := ranges.pop.push (previousStart, max previousStop stop)
        else
          ranges := ranges.push (start, stop)
      | none => ranges := ranges.push (start, stop)
  let mut out := s!"--- a/{path}\n+++ b/{path}\n"
  for (start, stop) in ranges do
    let mut oldCount := 0
    let mut newCount := 0
    for index in [start:stop + 1] do
      match script[index]!.1 with
      | .skip => oldCount := oldCount + 1; newCount := newCount + 1
      | .delete => oldCount := oldCount + 1
      | .insert => newCount := newCount + 1
    -- A hunk covering none of a side starts *at* the line it sits before, not one past it: a pure
    -- insertion into an empty file is `-0,0`, which is what every diff consumer expects to read.
    let oldStart := if oldCount == 0 then oldBefore[start]! else oldBefore[start]! + 1
    let newStart := if newCount == 0 then newBefore[start]! else newBefore[start]! + 1
    out := out ++ s!"@@ -{oldStart},{oldCount} +{newStart},{newCount} @@\n"
    for index in [start:stop + 1] do
      let (action, line, endsWithoutNewline) := script[index]!
      out := out ++ action.linePrefix ++ line ++ "\n"
      if endsWithoutNewline then
        out := out ++ "\\ No newline at end of file\n"
  return out

private def octalDigit? : Char → Option Nat
  | '0' => some 0
  | '1' => some 1
  | '2' => some 2
  | '3' => some 3
  | '4' => some 4
  | '5' => some 5
  | '6' => some 6
  | '7' => some 7
  | _ => none

private def parseOctal? (value : String) : Option Nat := do
  guard !value.isEmpty
  value.toList.foldlM (init := 0) fun total character => do
    let digit ← octalDigit? character
    return total * 8 + digit

private def accessMode (path : FilePath) : IO Nat := do
  let candidates : Array (String × Array String) := #[
    ("/usr/bin/stat", #["-f", "%Lp", path.toString]),
    ("stat", #["-c", "%a", path.toString])
  ]
  for (command, arguments) in candidates do
    try
      let output ← IO.Process.output { cmd := command, args := arguments }
      if output.exitCode == 0 then
        if let some mode := parseOctal? output.stdout.trimAscii.copy then
          return mode
    catch _ => pure ()
  throw <| IO.userError s!"could not read source permissions: {path}"

private def publicationTemp (path : FilePath) : IO FilePath := do
  let pid ← IO.Process.getPID
  let nonce ← IO.monoNanosNow
  return FilePath.mk s!"{path}.lean-fmt-tmp-{pid}-{nonce}"

private def runBeforeWriteHook (path : FilePath) : IO Unit := do
  if let some command ← IO.getEnv "LEAN_FMT_TEST_BEFORE_WRITE" then
    let output ← IO.Process.output { cmd := command, args := #[path.toString] }
    unless output.exitCode == 0 do
      throw <| IO.userError "test before-write hook failed"

private def publishAtomic (path : FilePath) (original output : String) : IO (Except String Unit) := do
  let mode ← accessMode path
  let temporary ← publicationTemp path
  try
    IO.FS.writeFile temporary output
    IO.Prim.setAccessRights temporary mode.toUInt32
    runBeforeWriteHook path
    unless (← IO.FS.readFile path) == original do
      IO.FS.removeFile temporary
      return .error "source changed after analysis; refusing stale write"
    IO.FS.rename temporary path
    return .ok ()
  catch error =>
    if ← temporary.pathExists then
      IO.FS.removeFile temporary
    throw error

private def baseReport (snapshot : SourceSnapshot) (status : String)
    (findings : Array Finding := #[]) (diagnostics : Array String := #[]) : FileReport :=
  { path := snapshot.relativePath, status, findings, diagnostics }

private def validationReport (snapshot : SourceSnapshot) (findings : Array Finding)
    (validation : SemanticAnalysis) : Option FileReport :=
  match validation.result? with
  | some _ => none
  | none => some (baseReport snapshot "rejected" findings validation.diagnostics)

/- Findings index the normalized source, so edits are prepared against it and the result is returned
to the file's own line-ending form on the way out. Preparing edits against the raw bytes would place
every edit past its intended offset in a CRLF file. -/
private structure PreparedFile where
  findings : Array Finding
  normalized : String
  lineEndings : LineEndings
  patch : Patch
  /-- Reported findings whose fix is unsafe and was not admitted into `patch` (opt-in was off). What
  `--unsafe-fixes` would additionally apply. -/
  withheldUnsafe : Nat
  /-- How many config-selected findings a source directive suppressed. -/
  suppressed : Nat
  /-- FMT006 candidates withheld by exposure-changing modifiers (see `FileReport.withheldRedundant`). -/
  withheldRedundant : Nat

/-- The formatted text in the file's own line-ending form, i.e. what a write would produce. -/
private def PreparedFile.output (prepared : PreparedFile) : String :=
  LosslessSource.denormalize prepared.patch.formatted prepared.lineEndings

/-- Whether publishing this would alter the file.

**Not `patch.changed`.** That asks whether the patch carries fix edits, which was the same question
only while the patch was based on the file's own bytes. Based on canonical text it is a different
question and the wrong one: a file needing layout but no fixes has an empty edit set, so
`patch.changed` is `false` while the output differs on every line. Comparing the output to the source
is the question all three callers actually meant. -/
private def PreparedFile.changed (prepared : PreparedFile) : Bool :=
  prepared.patch.formatted != prepared.normalized

/-- Order findings by position, then code, so a report is deterministic regardless of which layer
produced a finding (a rule, or the suppression projection's `FMT900`/`FMT901`). -/
private def reportOrder (left right : Finding) : Bool :=
  if left.range.start != right.range.start then left.range.start < right.range.start
  else if left.range.stop != right.range.stop then left.range.stop < right.range.stop
  else left.code < right.code

/-- Project the source-suppression layer over the config-selected findings.

Applied **after** `plan.findings` (config selection), so unused is computed against the config-selected
set (`notes/01-spec.md` §8). Returns the reported findings — survivors plus the `FMT900` unused and
`FMT901` malformed self-diagnostics, which are *not* themselves suppressible and bypass config
selection (they are formatter self-diagnostics, always on in v1) — and the suppressed count.

Coordinate note: directive scopes index the normalized source, so this projection is exact for the
**report**, which the user reads against their own unmoved bytes. Suppression shapes only the report;
it never touches a patch. A directive silences a diagnostic without changing the bytes a write
publishes — so `prepareFile` builds its patch from the config-selected findings, suppression-free, and
`FMT900`/`FMT901` (themselves report-only, and not suppressible) never enter one. This keeps `check`'s
report patch and `fix`'s applied patch in agreement: since `ruff-11c` RDF-IMPL both index the same
normalized bytes the directive scopes do, so no scope ever has to be mapped onto reflowed canonical
offsets. An editor may still apply an `FMT900` removal from the report; batch `fix` does not. -/
private def projectSuppression (result : SemanticResult) (bytes : ByteArray)
    (selected : Array Finding) : Array Finding × Nat :=
  let outcome := Suppression.apply result.suppression bytes selected
  let reported := (outcome.kept ++ result.suppression.malformed ++ outcome.unused).qsort reportOrder
  (reported, outcome.suppressed)

/-! ## Import findings — computed fresh in IO, merged pre-selection

The import family (FMT005/06/07) is not in the `RuleImpl` engine, so it does not ride the cached
`SemanticResult`. FMT005/07 are pure over the file's own header, but FMT006 depends on *other* files
through the Lake graph, so **none** of it enters the source-digest result cache — caching a graph fact
under a single file's digest would serve a stale answer the moment an unrelated import changed. Import
findings are recomputed every run here and merged into the report before selection (`plan.findings`),
so `--select imports`, per-file ignores, and suppression all apply to them uniformly. -/

private def anyImportSelected (plan : RulePlan) : Bool :=
  importRuleInfos.any (plan.selected.contains ·.code)

/-- The import findings for one already-parsed header at `normalized`'s coordinates, plus the
withheld-redundant count. Each rule is gated on selection so an unselected FMT006 never consults the
graph closure. Pure — the caller did the IO (header parse, closure fetch). -/
private def importFindingsOfHeader (plan : RulePlan)
    (closureOf : Lean.Name → Option (Array Lean.Name))
    (header : Imports.HeaderModel) (normalized : String) : Array Finding × Nat := Id.run do
  let mut findings : Array Finding := #[]
  let mut withheld := 0
  if plan.selected.contains "FMT005" then
    findings := findings ++ Imports.duplicateFindings header normalized
  if plan.selected.contains "FMT007" then
    findings := findings ++ Imports.orderFindings header normalized
  if plan.selected.contains "FMT006" then
    let (redundant, w) := Imports.redundantFindings header closureOf
    findings := findings ++ redundant
    withheld := w
  return (findings, withheld)

/-- The distinct written import module names of `header`, the keys FMT006's closure fetch needs. -/
private def headerImportNames (header : Imports.HeaderModel) : Array Lean.Name :=
  header.imports.foldl (init := #[]) fun acc stmt =>
    if acc.contains stmt.module then acc else acc.push stmt.module

/-- Build a closure lookup for `names` (empty unless FMT006 is selected), then compute one file's
import report. Used by the single-file editor path; the batch `execute` path shares one closure fetch
across all files instead (`computeImportReports`). -/
private def singleImportReport (plan : RulePlan) (workspace : Lake.Workspace)
    (normalized : String) : IO (Array Finding × Nat) := do
  unless anyImportSelected plan do return (#[], 0)
  match ← Imports.parseHeaderModel normalized with
  | none => return (#[], 0)
  | some header =>
    let closureOf ← if plan.selected.contains "FMT006" then
        let pairs ← Project.importClosures workspace (headerImportNames header)
        pure fun name => (pairs.find? (·.1 == name)).map (·.2)
      else pure fun _ => none
    return importFindingsOfHeader plan closureOf header normalized

/-- Compute every target's import report in one pass: parse all headers, fetch the union of their
import closures in a single no-build graph build (FMT006 only), then project per file. Returns one
`(findings, withheldRedundant)` per snapshot, aligned with `snapshots`. -/
private def computeImportReports (plan : RulePlan) (workspace : Lake.Workspace)
    (snapshots : Array SourceSnapshot) : IO (Array (Array Finding × Nat)) := do
  unless anyImportSelected plan do
    return Array.replicate snapshots.size (#[], 0)
  let headers ← snapshots.mapM fun snapshot => do
    let (normalized, _) := LosslessSource.normalize snapshot.source
    return (normalized, ← Imports.parseHeaderModel normalized)
  let closureOf ← if plan.selected.contains "FMT006" then
      let names := headers.foldl (init := #[]) fun acc (_, header?) =>
        match header? with
        | some header => (headerImportNames header).foldl (init := acc) fun acc name =>
            if acc.contains name then acc else acc.push name
        | none => acc
      let pairs ← Project.importClosures workspace names
      pure fun name => (pairs.find? (·.1 == name)).map (·.2)
    else pure fun _ => none
  return headers.map fun (normalized, header?) =>
    match header? with
    | none => (#[], 0)
    | some header => importFindingsOfHeader plan closureOf header normalized

/-- Project one analysis into the edits a preview or write would apply — one of two independent patches,
keyed on `renderCanonical` (`ruff-11c` RDF-IMPL, `notes/01-model.md` §2):

- **Layout patch** (`format`/`diff`, `renderCanonical`). `base := canonical.text`, the reflowed bytes,
  and the patch carries **no** rule fix. The render is the whole answer: `format` publishes `output` in
  place (`ruff-11d`, `formatFile`; `format --check` previews it), `diff` diffs `normalized` against it.
  A rule fix rides `fix`, never layout.
- **Fix patch** (`fix`; `check` computes it for the report). `base := normalized`, the file's own bytes,
  and the patch carries the admitted fixes from `selected` at **original** coordinates. `fix` validates
  and publishes it; it does not reflow. Because layout and fix never share a coordinate system here, the
  `RFP-SPEC` §6 gap — canonicalizing `namespace     Alpha` deletes four bytes — can no longer move a fix
  off the bytes it was reported against.

The report (`findings`) is `result.findings` (joined with `reportImports`) at original coordinates in
every mode, independent of which patch is built — it is what the user, whose file has not moved, sees.

**Applicability gates the patch, not the report.** Every finding with a fix is reported (with its
effective applicability, already resolved by `plan.findings`), but only the *admitted* fixes enter the
patch: a non-admitted fix is stripped to `none` before `preparePatch`, which then only ever assembles
edits that will actually be published. Admission is `Applicability.admitted unsafeFixes`, the one rule
`fix` and its `check` preview share, so a preview shows exactly what a write would do. -/
private def prepareFile (plan : RulePlan) (renderCanonical unsafeFixes : Bool)
    (reportImports : Array Finding) (withheldRedundant : Nat)
    (snapshot : SourceSnapshot) (analysis : SemanticAnalysis) : Except FileReport PreparedFile := do
  let some result := analysis.result?
    | throw (baseReport snapshot "broken" #[] analysis.diagnostics)
  let (normalized, lineEndings) := LosslessSource.normalize snapshot.source
  -- Import findings (`reportImports`, normalized coordinates) join the engine's findings *before*
  -- selection, so `--select imports`, per-file ignores, and suppression treat them like any rule. FMT005
  -- rides here at original coordinates and needs no canonical recomputation: the fix patch applies it on
  -- `normalized`, and the layout patch carries no fix at all.
  let selected := plan.findings snapshot.relativePath (result.findings ++ reportImports)
  let (findings, suppressed) := projectSuppression result normalized.toUTF8 selected
  -- The fix patch is built from the config-selected findings *unaffected by suppression*: suppression
  -- shapes the report (`findings`), never the bytes a write publishes, so a directive silences a
  -- diagnostic without changing output. Feeding the suppression-projected set here would put the
  -- `FMT900`/`FMT901` removal edits into the patch, so `check` would report a change `fix` never makes;
  -- both stay agreed by ignoring the self-diagnostics for the patch.
  let (base, baseFindings) :=
    match (if renderCanonical then result.canonical? else none) with
    -- Layout patch: reflow only, no rule fix. `canonical?` is populated for any rendering run
    -- (`cacheHitServes`/`availableAnalysis` guarantee it), so a rendering run never falls to the fix arm.
    | some canonical => (canonical.text, (#[] : Array Finding))
    -- Fix patch (`fix`) / report patch (`check`): admitted fixes on the file's own bytes.
    | none => (normalized, selected)
  -- A fix enters the patch only when its rule is fix-selected (`fixable`/`unfixable` axis, `ruff-12`)
  -- *and* its applicability is admitted. A selected-but-unfixable rule is still reported (its finding is
  -- in `findings`); only the patch drops the fix — the same shape as a withheld unsafe fix.
  let admitted := baseFindings.map fun finding =>
    match finding.fix? with
    | some fix =>
      if plan.fixableSelected.contains finding.code && fix.applicability.admitted unsafeFixes then finding
      else { finding with fix? := none }
    | none => finding
  let patch ← match preparePatch base admitted with
    | .ok patch => pure patch
    | .error error =>
      throw (baseReport snapshot "rejected" findings #[toString error])
  -- Counted over reported findings (original coordinates), which are the same rules as `baseFindings`
  -- in the same number, so the coordinate system does not matter to a count.
  let withheldUnsafe := findings.foldl (init := 0) fun total finding =>
    match finding.fix? with
    | some fix => if !fix.applicability.admitted unsafeFixes && fix.applicability == .unsafe then
        total + 1 else total
    | none => total
  return { findings, normalized, lineEndings, patch, withheldUnsafe, suppressed, withheldRedundant }

private inductive PreviewMode where
  | check
  | format
  | diff

private def RunMode.preview? : RunMode → Option PreviewMode
  | .check => some .check
  | .format => some .format
  | .diff => some .diff
  | .fix => none

/-- Mirrors `RunMode.rendersCanonical` for the preview subset; `fix` renders and is not a preview. -/
private def PreviewMode.rendersCanonical : PreviewMode → Bool
  | .check => false
  | .format | .diff => true

private def previewFile (mode : PreviewMode) (plan : RulePlan) (unsafeFixes : Bool)
    (reportImports : Array Finding) (withheldRedundant : Nat)
    (snapshot : SourceSnapshot) (analysis : SemanticAnalysis) : IO FileReport := do
  match prepareFile plan mode.rendersCanonical unsafeFixes reportImports
      withheldRedundant snapshot analysis with
  | .error report => return report
  | .ok prepared =>
    let findings := prepared.findings
    let withheldUnsafe := prepared.withheldUnsafe
    let suppressed := prepared.suppressed
    let withheldRedundant := prepared.withheldRedundant
    match mode with
    | .check =>
      return { (baseReport snapshot (if findings.isEmpty then "clean" else "findings") findings) with
        withheldUnsafe, suppressed, withheldRedundant }
    | .format =>
      if prepared.changed then
        return { (baseReport snapshot "would-format" findings) with
          formatted := some prepared.output, withheldUnsafe, suppressed, withheldRedundant }
      return { (baseReport snapshot "clean" findings) with withheldUnsafe, suppressed, withheldRedundant }
    | .diff =>
      if prepared.changed then
        -- Both sides of the diff are normalized: a CRLF file must not read as every line changed.
        return { (baseReport snapshot "would-diff" findings) with
          diff := some (unifiedDiff snapshot.relativePath prepared.normalized
            prepared.patch.formatted), withheldUnsafe, suppressed, withheldRedundant }
      return { (baseReport snapshot "clean" findings) with withheldUnsafe, suppressed, withheldRedundant }

private def fixFile (run : ExactRun) (plan : RulePlan) (unsafeFixes : Bool)
    (reportImports : Array Finding) (withheldRedundant : Nat)
    (snapshot : SourceSnapshot) (analysis : SemanticAnalysis) : IO FileReport := do
  -- `fix` does not render (`ruff-11c` RDF-IMPL): the patch bases on the file's own `normalized` bytes and
  -- applies the admitted fixes from `selected` — FMT005 among them — at original coordinates. No reflow,
  -- no canonical recomputation.
  match prepareFile plan (renderCanonical := false) unsafeFixes reportImports
      withheldRedundant snapshot analysis with
  | .error report => return report
  | .ok prepared =>
    let findings := prepared.findings
    let withheldUnsafe := prepared.withheldUnsafe
    let suppressed := prepared.suppressed
    let withheldRedundant := prepared.withheldRedundant
    unless prepared.changed do
      return { (baseReport snapshot "clean" findings) with withheldUnsafe, suppressed, withheldRedundant }
    let output := prepared.output
    -- The validator re-elaborates exactly the bytes a write would publish, line endings included.
    -- It renders no canonical text: the question is whether these bytes elaborate, and rendering a
    -- layout for a candidate nothing will print is work with no reader.
    let candidate := snapshot.withSource output
    let validation ← run.analyzeSnapshot candidate (renderCanonical := false) (validator := true)
    if let some report := validationReport snapshot findings validation then
      return report
    match ← publishAtomic snapshot.path snapshot.source output with
    | .error message => return { (baseReport snapshot "rejected" findings #[message]) with
        withheldUnsafe, suppressed, withheldRedundant }
    | .ok _ =>
      return { (baseReport snapshot "fixed" findings) with
        formatted := some output
        written := true
        withheldUnsafe, suppressed, withheldRedundant }

/-- Publish the canonical layout in place (`ruff-11d` FIP-IMPL) — `format`'s default disposition.

Structurally `fixFile` with the *layout* base: it renders the `ruff-11c` layout patch
(`renderCanonical := true`, so `patch.formatted = canonical.text` and the patch carries no rule fix),
short-circuits `clean` when the file already is canonical, validates the reflowed bytes under the exact
module setup, and publishes through `publishAtomic` — the same guarded path (stale-source check + atomic
lossless write) `fix` and `organize` use. A file that does not elaborate is `broken` and never written;
a partial write is impossible. `format` applies no rule fix; those ride `fix`. Status `formatted` +
`written` mirrors `fix`'s `fixed`; the write bytes are `prepared.output`, denormalized to the file's own
line endings, so a CRLF file stays CRLF. -/
private def formatFile (run : ExactRun) (plan : RulePlan) (unsafeFixes : Bool)
    (reportImports : Array Finding) (withheldRedundant : Nat)
    (snapshot : SourceSnapshot) (analysis : SemanticAnalysis) : IO FileReport := do
  match prepareFile plan (renderCanonical := true) unsafeFixes reportImports
      withheldRedundant snapshot analysis with
  | .error report => return report
  | .ok prepared =>
    let findings := prepared.findings
    let withheldUnsafe := prepared.withheldUnsafe
    let suppressed := prepared.suppressed
    let withheldRedundant := prepared.withheldRedundant
    unless prepared.changed do
      return { (baseReport snapshot "clean" findings) with withheldUnsafe, suppressed, withheldRedundant }
    let output := prepared.output
    -- Validate the reflowed bytes exactly as `fix` validates its fixed bytes: the printer is not proven
    -- to preserve elaboration (`RLF-REFLOW` moves bytes across lines), so a layout that fails to
    -- elaborate is rejected, never published. No canonical render — the question is only whether these
    -- bytes elaborate.
    let candidate := snapshot.withSource output
    let validation ← run.analyzeSnapshot candidate (renderCanonical := false) (validator := true)
    if let some report := validationReport snapshot findings validation then
      return report
    match ← publishAtomic snapshot.path snapshot.source output with
    | .error message => return { (baseReport snapshot "rejected" findings #[message]) with
        withheldUnsafe, suppressed, withheldRedundant }
    | .ok _ =>
      return { (baseReport snapshot "formatted" findings) with
        formatted := some output
        written := true
        withheldUnsafe, suppressed, withheldRedundant }

def ExactRun.checkSnapshot (run : ExactRun) (plan : RulePlan)
    (snapshot : SourceSnapshot) : IO FileReport := do
  let analysis ← run.analyzeSnapshot snapshot (renderCanonical := false)
  -- The editor `check` path never applies fixes, so opt-in is irrelevant to its output; it reports
  -- every finding's applicability and withholds nothing itself. It computes its own single-file import
  -- report (batch runs share one closure fetch via `computeImportReports`).
  let (normalized, _) := LosslessSource.normalize snapshot.source
  let (reportImports, withheldRedundant) ← singleImportReport plan run.project.workspace normalized
  previewFile .check plan (unsafeFixes := false) reportImports withheldRedundant snapshot analysis

private def summarize (modeString : String) (files : Array FileReport)
    (failures : Array String := #[]) : RunReport :=
  let findings := files.foldl (fun total file => total + file.findings.size) 0
  let changed := files.foldl (fun total file =>
    if file.status == "findings" || file.status == "would-format" ||
        file.status == "would-diff" || file.status == "fixed" || file.status == "formatted" ||
        file.status == "would-organize" || file.status == "organized" then total + 1 else total) 0
  let written := files.foldl (fun total file => if file.written then total + 1 else total) 0
  let broken := files.foldl (fun total file =>
    if file.status == "broken" then total + 1 else total) 0
  let rejected := files.foldl (fun total file =>
    if file.status == "rejected" then total + 1 else total) 0
  let withheldUnsafe := files.foldl (fun total file => total + file.withheldUnsafe) 0
  let suppressed := files.foldl (fun total file => total + file.suppressed) 0
  let withheldRedundant := files.foldl (fun total file => total + file.withheldRedundant) 0
  { mode := modeString, files, findings, changed, written, broken, rejected, withheldUnsafe,
    suppressed, withheldRedundant, infrastructureFailures := failures }

private def recordPhase (name : String) (started finished : Nat) : IO Unit := do
  if (← IO.getEnv "LEAN_FMT_PROFILE_PHASES") == some "1" then
    IO.eprintln s!"phase.{name}_ms={(finished - started) / 1000000}"

private def recordDuration (name : String) (nanos : Nat) : IO Unit := do
  if (← IO.getEnv "LEAN_FMT_PROFILE_PHASES") == some "1" then
    IO.eprintln s!"phase.{name}_ms={nanos / 1000000}"

/- Execute one immutable user request. This operation owns workspace discovery, exact module
selection, source snapshots, trusted-artifact validation, fallback, deterministic aggregation, and
resource intent. No caller can sequence or retain those mechanisms independently. -/
def execute (request : RunRequest) : IO RunReport := do
  if request.maxMemoryGiB == 0 then
    throw <| IO.userError "--max-memory must provide a nonzero operating envelope"
  let root ← IO.FS.realPath request.root
  let configPath? := request.configPath?.map fun path =>
    if path.isAbsolute then path else root / path
  let config ← FormatterConfig.load root configPath?
  let plan ← match config.rulePlan {
      select := request.select, extendSelect := request.extendSelect, ignore := request.ignore,
      fixable := request.fixable, unfixable := request.unfixable,
      extendFixable := request.extendFixable, preview := request.preview } with
    | .ok plan => pure plan
    | .error message => throw <| IO.userError message
  for notice in plan.notices do IO.eprintln s!"lean-fmt: {notice}"
  let project ← Project.load root config request.files
  recordDuration "workspace_load" project.workspaceLoadNanos
  recordDuration "selection_snapshot" project.selectionNanos
  let snapshots := project.targets
  -- Import findings are computed fresh here, once, before any cache path: FMT005/07 are pure over each
  -- file's header, but FMT006 reads the Lake graph, so none of it is cacheable under a file's own
  -- digest (`computeImportReports`). One shared closure fetch covers every file; the result is threaded
  -- into `previewFile`/`fixFile` so selection and suppression apply to import findings like any rule's.
  let importStarted ← IO.monoNanosNow
  let importReports ← computeImportReports plan project.workspace snapshots
  recordDuration "import_findings" ((← IO.monoNanosNow) - importStarted)
  let application ← IO.appPath
  let epochStarted ← IO.monoNanosNow
  let cache? ← if request.cache then
    ResultCache.open? project.workspace application request.validationLevel
  else
    pure none
  let epochFinished ← IO.monoNanosNow
  recordPhase "cache_epoch" epochStarted epochFinished
  let lookupStarted ← IO.monoNanosNow
  let cached ← match cache? with
    | none => pure (Array.replicate snapshots.size none)
    | some cache => cache.readAll project snapshots
  let lookupFinished ← IO.monoNanosNow
  recordPhase "cache_lookup" lookupStarted lookupFinished
  -- An entry that cannot serve this run is demoted to a miss here, once, so that every path below
  -- treats it as one. A `check` run caches a result with no canonical text; a later `format` hitting
  -- it would otherwise short-circuit straight to "clean" for every file in the project.
  let renderCanonical := request.mode.rendersCanonical
  -- The apply signal (`ruff-11c` RDF-IMPL): only `fix` applies rule fixes, so only `fix` demands the
  -- FMT014 occurrence fold. It is distinct from `renderCanonical` now that layout and fix are split —
  -- `format`/`diff` render but apply nothing; `fix` applies but no longer renders.
  let applies := request.mode == .fix
  -- What this run must actually obtain, rules and mode together. `semantic` is reachable only through
  -- the mode: no rule is `semantic`-tier, so a rendering mode is the sole demander of the notation
  -- fact (`RulePlan.demandedTier`). This is the gating seam — capture runs iff `demanded` reaches it.
  let demanded := plan.demandedTier renderCanonical
  let demandedCaps := plan.demandedCaps renderCanonical applies
  let cached := cached.map fun cached? =>
    cached?.filter (cacheHitServes plan.requiredTier demandedCaps renderCanonical)
  -- A writing `format` (`ruff-11d`) is not served here: it must reach `withExactRun` for the validator
  -- child before it publishes, so it is excluded from both cache-only preview fast paths. `format
  -- --check`, which writes nothing, keeps them.
  if !request.writesFormat && cached.all Option.isSome then
    if let some previewMode := request.mode.preview? then
      let mut files := #[]
      for ((snapshot, cached?), importReport) in (snapshots.zip cached).zip importReports do
        if let some analysis := cached? then
          files := files.push (← previewFile previewMode plan request.unsafeFixes
            importReport.1 importReport.2 snapshot analysis)
      return summarize request.mode.toString files
  let evidenceStarted ← IO.monoNanosNow
  let evidence ← Project.moduleEvidence project
  let evidenceFinished ← IO.monoNanosNow
  recordPhase "module_evidence" evidenceStarted evidenceFinished
  let artifactStarted ← IO.monoNanosNow
  -- The plugin artifact carries `source`+`syntax` but never `semantic` (it is always-on, so capturing
  -- there would tax every build — `ruff-05b` F3/F4). A run that demands `semantic` therefore cannot be
  -- served by it and must re-analyze via `analyzeExact`; fetching it would be wasted work and, worse,
  -- would let `availableAnalysis` render canonical text off a fact-free artifact. Skipping the fetch
  -- both records the gating cost and rejects the `semantic = none` artifact for a `format` run.
  let artifacts ← if demanded == .semantic then
    pure (Array.replicate snapshots.size none)
  else if plan.requiredTier != .source then
    officialArtifacts project.workspace snapshots
  else
    pure (Array.replicate snapshots.size none)
  let artifactFinished ← IO.monoNanosNow
  recordPhase "official_artifacts" artifactStarted artifactFinished
  let available ← (((snapshots.zip cached).zip evidence).zip artifacts).mapM fun
    | (((snapshot, cached?), sourceEvidence), artifact?) =>
      availableAnalysis plan renderCanonical applies sourceEvidence snapshot cached? artifact?
  if !request.writesFormat && available.all Option.isSome then
    if let some previewMode := request.mode.preview? then
      let analyses := available.filterMap id
      let files ← ((snapshots.zip analyses).zip importReports).mapM fun ((snapshot, analysis), ir) =>
        previewFile previewMode plan request.unsafeFixes ir.1 ir.2 snapshot analysis
      if let some cache := cache? then
        cache.writeAll project snapshots available
      return summarize request.mode.toString files
  withExactRun project request.maxMemoryGiB fun exactRun => do
    let mut files := #[]
    let mut failures := #[]
    let mut analyses := #[]
    for ((snapshot, available?), ir) in (snapshots.zip available).zip importReports do
      try
        let analysis ← match available? with
          | some analysis => pure analysis
          | none =>
            exactRun.analyzeSnapshot snapshot renderCanonical
              (captureSemantic := demanded == .semantic)
              (captureOccurrences := demandedCaps.occurrences)
        analyses := analyses.push (some analysis)
        let report ← match request.mode with
          | .fix => fixFile exactRun plan request.unsafeFixes ir.1 ir.2 snapshot analysis
          | .check => previewFile .check plan request.unsafeFixes ir.1 ir.2 snapshot analysis
          -- `format` publishes in place by default (`ruff-11d`); `--check` demotes it to the preview.
          | .format =>
            if request.formatCheck then
              previewFile .format plan request.unsafeFixes ir.1 ir.2 snapshot analysis
            else
              formatFile exactRun plan request.unsafeFixes ir.1 ir.2 snapshot analysis
          | .diff => previewFile .diff plan request.unsafeFixes ir.1 ir.2 snapshot analysis
        files := files.push report
      catch error =>
        analyses := analyses.push none
        let message := toString error
        failures := failures.push s!"{snapshot.relativePath}: {message}"
        files := files.push {
          path := snapshot.relativePath
          status := "infrastructure-failure"
          diagnostics := #[message]
        }
    if let some cache := cache? then
      cache.writeAll project snapshots analyses
    return summarize request.mode.toString files failures

structure OrganizeRequest where
  root : FilePath
  files : Array FilePath
  maxMemoryGiB : Nat := 8
  configPath? : Option FilePath := none
  /-- Report what would change without writing (like `check` for the organizer). -/
  check : Bool := false

/-- The opt-in "organize imports" capability the roadmap owes CLI and LSP, exposing no graph internals
— text in, text out. It rewrites each target's surface header to canonical form: duplicates removed
(FMT005's safe edit) and each blank-line/comment group sorted by module name (FMT007's reorder). The
reorder is *observable to elaboration* (`notes/01-semantics.md` §2), which is why it is opt-in and never
part of unattended `fix`; redundant imports (FMT006) are report-only and are **not** removed here.

Every rewrite that changes a file is validated by re-elaboration before it is written — the same
trusted-artifact discipline `fix` uses (`fixFile`) — so an organized header that fails to elaborate is
rejected, never published. A clean project never constructs the validator. -/
def organize (request : OrganizeRequest) : IO RunReport := do
  if request.maxMemoryGiB == 0 then
    throw <| IO.userError "--max-memory must provide a nonzero operating envelope"
  let root ← IO.FS.realPath request.root
  let configPath? := request.configPath?.map fun path =>
    if path.isAbsolute then path else root / path
  let config ← FormatterConfig.load root configPath?
  let project ← Project.load root config request.files
  let snapshots := project.targets
  -- The canonical header rewrite is pure (no graph): compute every candidate first, and only pay for
  -- the validator if some file actually changes.
  let candidates ← snapshots.mapM fun snapshot => do
    let (normalized, lineEndings) := LosslessSource.normalize snapshot.source
    match ← Imports.parseHeaderModel normalized with
    | none => pure none
    | some header =>
      let output := LosslessSource.denormalize (Imports.organize header normalized) lineEndings
      pure (if output == snapshot.source then none else some output)
  let anyChange := candidates.any Option.isSome
  if request.check || !anyChange then
    let files := (snapshots.zip candidates).map fun (snapshot, candidate?) =>
      baseReport snapshot (if candidate?.isSome then "would-organize" else "clean")
    return summarize "organize" files
  withExactRun project request.maxMemoryGiB fun exactRun => do
    let mut files := #[]
    let mut failures := #[]
    for (snapshot, candidate?) in snapshots.zip candidates do
      match candidate? with
      | none => files := files.push (baseReport snapshot "clean")
      | some output =>
        try
          let candidate := snapshot.withSource output
          let validation ← exactRun.analyzeSnapshot candidate (renderCanonical := false) (validator := true)
          match validation.result? with
          | none => files := files.push (baseReport snapshot "rejected" #[] validation.diagnostics)
          | some _ =>
            match ← publishAtomic snapshot.path snapshot.source output with
            | .error message => files := files.push (baseReport snapshot "rejected" #[] #[message])
            | .ok _ =>
              files := files.push { (baseReport snapshot "organized") with
                formatted := some output, written := true }
        catch error =>
          let message := toString error
          failures := failures.push s!"{snapshot.relativePath}: {message}"
          files := files.push {
            path := snapshot.relativePath
            status := "infrastructure-failure"
            diagnostics := #[message]
          }
    return summarize "organize" files failures

private unsafe def runAnalyzeChild (args : List String) : IO UInt32 := do
  -- The `captureSemantic` flag is a trailing optional argument: a direct 4-argument invocation (the
  -- syntax-only path, and every existing test harness) omits it and captures no semantic fact.
  let (setupPath, snapshotPath, displayPath, maxBytes, captureSemantic) ← match args with
    | [setupPath, snapshotPath, displayPath, maxBytes] =>
      pure (setupPath, snapshotPath, displayPath, maxBytes, "0")
    | [setupPath, snapshotPath, displayPath, maxBytes, captureSemantic] =>
      pure (setupPath, snapshotPath, displayPath, maxBytes, captureSemantic)
    | _ => return 2
  let some maxBytes := maxBytes.toNat?
    | return 2
  Lean.Internal.setMaxMemory maxBytes.toUSize
  let .ok setupJson := Lean.Json.parse (← IO.FS.readFile setupPath)
    | throw <| IO.userError "invalid ModuleSetup JSON"
  let .ok setup := Lean.fromJson? setupJson
    | throw <| IO.userError "invalid ModuleSetup payload"
  let source ← IO.FS.readFile snapshotPath
  -- "0" none, "1" semantic (notations + diagnostics), "2" semantic + the info-tree occurrence fold.
  let envelope ← analyzeExact setup source displayPath
    (captureSemantic := captureSemantic == "1" || captureSemantic == "2")
    (captureOccurrences := captureSemantic == "2")
  IO.println (Lean.toJson envelope).compress
  return 0

private unsafe def runExtractChild (args : List String) : IO UInt32 := do
  let [moduleName, moduleFile, output] := args
    | return 2
  match ← compilerArtifact? moduleName.toName moduleFile with
  | some artifact => writeArtifactAtomic output artifact
  | none =>
    if let some parent := (output : FilePath).parent then
      IO.FS.createDirAll parent
    IO.FS.writeFile output "null"
  return 0

private unsafe def runInspectArtifactChild (args : List String) : IO UInt32 := do
  let [moduleName, moduleFile, sourcePath, maxBytes] := args
    | return 2
  let some maxBytes := maxBytes.toNat?
    | return 2
  Lean.Internal.setMaxMemory maxBytes.toUSize
  let source ← IO.FS.readFile sourcePath
  match ← compilerArtifact? moduleName.toName moduleFile with
  | some artifact =>
    if artifact.validFor moduleName.toName source then
      IO.println "ready"
    else
      IO.println "missing"
  | none => IO.println "missing"
  return 0

private unsafe def measureCacheEpoch (args : List String) : IO UInt32 := do
  let [root] := args
    | return 2
  let root ← IO.FS.realPath root
  let workspaceStarted ← IO.monoNanosNow
  let workspace ← Project.loadWorkspace root
  let workspaceFinished ← IO.monoNanosNow
  let epochStarted ← IO.monoNanosNow
  let cache? ← ResultCache.open? workspace (← IO.appPath)
  let epochFinished ← IO.monoNanosNow
  IO.println s!"phase.workspace_load_ms={(workspaceFinished - workspaceStarted) / 1000000}"
  IO.println s!"phase.cache_epoch_ms={(epochFinished - epochStarted) / 1000000}"
  IO.println s!"cache_enabled={cache?.isSome}"
  return if cache?.isSome then 0 else 1

structure CleanReport where
  root : String
  removed : Bool
  deriving Lean.ToJson

def clean (requestedRoot : FilePath) : IO CleanReport := do
  let root ← IO.FS.realPath requestedRoot
  let cache := root / ".lean-fmt-cache"
  let removed ← cache.pathExists
  if removed then IO.FS.removeDirAll cache
  return { root := root.toString, removed }

structure CompilerStatusRequest where
  root : FilePath := "."
  maxMemoryGiB : Nat := 8

structure CompilerSetupReport where
  schema : String
  package : String
  plugin : String
  facet : String
  toolchain : String
  guidance : Array String
  deriving Lean.ToJson

def compilerSetupReport : CompilerSetupReport := {
  schema := "lean-fmt.compiler-setup.v1"
  package := "lean-fmt"
  plugin := "LeanFmtCompilerPlugin:shared"
  facet := "leanFmtArtifact"
  toolchain := s!"Lean {Lean.versionString} ({Lean.githash})"
  guidance := #[
    "add lean-fmt as a Lake dependency using the source and revision you trust",
    "for dependency alias ALIAS, add `@ALIAS/LeanFmtCompilerPlugin:shared to each formatted lean_lib plugins array",
    "build +MODULE:leanFmtArtifact when an extracted module artifact is required"
  ]
}

structure CompilerModuleStatus where
  path : String
  module : String
  status : String
  deriving Lean.ToJson

structure CompilerStatusReport where
  root : String
  toolchain : String
  modules : Array CompilerModuleStatus
  ready : Nat
  missing : Nat
  unbuilt : Nat
  deriving Lean.ToJson

private def inspectCompilerArtifact (workspace : Lake.Workspace) (application : FilePath)
    (maxBytes : Nat) (snapshot : SourceSnapshot) : IO String := do
  let some mod := snapshot.module?
    | return "unbuilt"
  unless ← withoutProcessOutput <| workspace.checkNoBuild (do mod.olean.fetch) do
    return "unbuilt"
  let output ← runBounded {
    cmd := application.toString
    args := #["__inspect-artifact", mod.name.toString,
      mod.oleanFile.toString, snapshot.path.toString, toString maxBytes]
    env := workspace.augmentedEnvVars.push ⟨"LEAN_NUM_THREADS", some "1"⟩
  } maxBytes
  unless output.exitCode == 0 do
    throw <| IO.userError s!"compiler status child failed for {snapshot.relativePath}: \
      {output.stderr.trimAscii}"
  let status := output.stdout.trimAscii.copy
  unless status == "ready" || status == "missing" do
    throw <| IO.userError s!"compiler status child returned invalid output for \
      {snapshot.relativePath}"
  return status

def compilerStatus (request : CompilerStatusRequest) : IO CompilerStatusReport := do
  unless request.maxMemoryGiB > 0 do
    throw <| IO.userError "--max-memory must provide a nonzero operating envelope"
  let root ← IO.FS.realPath request.root
  let project ← Project.loadAll root
  let application ← IO.appPath
  let maxBytes := request.maxMemoryGiB * 1024 * 1024 * 1024
  let mut statuses := #[]
  for snapshot in project.targets do
    let some mod := snapshot.module?
      | continue
    let status ← inspectCompilerArtifact project.workspace application maxBytes snapshot
    statuses := statuses.push {
      path := snapshot.relativePath
      module := mod.name.toString
      status
    }
  let ready := statuses.foldl (fun total item => if item.status == "ready" then total + 1 else total) 0
  let missing := statuses.foldl (fun total item => if item.status == "missing" then total + 1 else total) 0
  let unbuilt := statuses.foldl (fun total item => if item.status == "unbuilt" then total + 1 else total) 0
  return {
    root := root.toString
    toolchain := s!"Lean {Lean.versionString} ({Lean.githash})"
    modules := statuses
    ready
    missing
    unbuilt
  }

/-- Dispatch only the private subprocess/profiling protocol. Ordinary product commands return
`none` and cannot observe setup paths, module artifacts, or process limits. -/
unsafe def runInternal? (args : List String) : IO (Option UInt32) :=
  match args with
  | "__analyze-exact" :: rest => some <$> runAnalyzeChild rest
  | "__extract-artifact" :: rest => some <$> runExtractChild rest
  | "__inspect-artifact" :: rest => some <$> runInspectArtifactChild rest
  | "__measure-cache-epoch" :: rest => some <$> measureCacheEpoch rest
  | _ => pure none

end LeanFmt.Internal.Application
