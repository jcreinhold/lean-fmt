module

import all LeanFmt.Cache
import all LeanFmt.Config
import all LeanFmt.Edit
import all LeanFmt.Printer
import all LeanFmt.Project
import all LeanFmt.Semantic
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

`check` does not, and that is the roadmap's first bullet rather than an optimization: formatting is a
canonical transformation, not a selectable rule, so it cannot enter rule selection and `check` reports
selected rules. A file that is badly laid out but lint-clean is `check`-clean. Keeping `check` off this
path is also what preserves its source-only fast path, which needs no artifact at all. -/
def RunMode.rendersCanonical : RunMode → Bool
  | .check => false
  | .format | .diff | .fix => true

structure RunRequest where
  mode : RunMode
  root : FilePath
  files : Array FilePath
  maxMemoryGiB : Nat := 8
  cache : Bool := true
  configPath? : Option FilePath := none
  select : Array String := #[]
  ignore : Array String := #[]
  validationLevel : ValidationLevel := .syntax

private abbrev SourceSnapshot := Project.SourceTarget

structure FileReport where
  path : String
  status : String
  findings : Array Finding := #[]
  diagnostics : Array String := #[]
  formatted : Option String := none
  diff : Option String := none
  written : Bool := false
  deriving Lean.ToJson

structure RunReport where
  mode : String
  files : Array FileReport
  findings : Nat
  changed : Nat
  written : Nat
  broken : Nat
  rejected : Nat
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
    (snapshot : SourceSnapshot) (validator := false) : IO AnalysisEnvelope := do
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
      args := #["__analyze-exact", setupPath.toString, sourcePath.toString,
        snapshot.path.toString, toString run.maxBytes]
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

A constant rather than a configuration key, because it cannot change a byte: `Doc.go` reads the margin
only in the `.group`/`.brk` fit test (`Doc.lean:219-229`), and `LeanFmt/Printer.lean` emits no `group`
— only `text`, `hard`, and `verbatim`. Every margin therefore produces identical output, so a
`line-width` option would be a control that steers nothing. `RFP-SPEC` §3 refused it on exactly that
evidence and named the trigger that reverses the refusal: whoever adds the first `group` to the
printer adds the key *and* its cache-identity component in the same commit, because at that moment
this value starts changing output and every cached `CanonicalText` becomes stale under an identity
that never mentioned it. The value 100 matches mathlib's own convention and is otherwise arbitrary. -/
def canonicalWidth : Nat := 100

/-- Render a validated artifact's projection, and re-run the rules against the result.

The rules are re-run rather than reused because canonical text is not lint-clean and its coordinates
are not the file's — see `CanonicalText`.

**Only `source`-tier rules run here, and that is a limit rather than a choice.** The facts available
for canonical text are canonical text: `artifact.source` projects the *original*, so handing it to a
syntax rule alongside the rendered string would measure a rule against one text using another text's
offsets, which is the coordinate-mixing error this codebase has already paid for once. Projecting the
canonical text instead means parsing it, which is a second frontend run per file.

Nothing is skipped today, because every registered rule is `source`-tier. The day one is not, this
becomes wrong silently, so here is the trigger: **whoever adds the first `syntax`-tier rule with a
fix decides what `format` does with it, and `ruff-06`'s `RFX-SPEC` owns that decision** — it is
chartered for "formatter interaction" and fix composition. The choice is between re-projecting
canonical text and applying non-source fixes to the original in a separate pass. `RRE-FINAL` asserts
this limit rather than leaving it to prose. -/
private def renderCanonicalText (raw : String) (artifact : ModuleArtifact) : IO CanonicalText := do
  let normalized := (LosslessSource.normalize raw).1
  let text ← Printer.format artifact.source normalized canonicalWidth
  return { text, findings := runSourceRules text }

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

def ExactRun.analyzeSnapshot (run : ExactRun) (snapshot : SourceSnapshot)
    (renderCanonical : Bool) (validator := false) : IO SemanticAnalysis := do
  canonicalAnalysis snapshot renderCanonical (← run.envelope snapshot validator)

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
private def cacheHitServes (renderCanonical : Bool) (analysis : SemanticAnalysis) : Bool :=
  match analysis.result? with
  | none => true
  | some result => !renderCanonical || result.canonical?.isSome

private def availableAnalysis (plan : RulePlan) (renderCanonical : Bool)
    (evidence : Project.ModuleEvidence)
    (snapshot : SourceSnapshot) (cached? : Option SemanticAnalysis)
    (officialArtifact? : Option ModuleArtifact) : IO (Option SemanticAnalysis) := do
  if let some analysis := cached? then
    if cacheHitServes renderCanonical analysis then
      return some analysis
  if plan.requiredTier == .source && !renderCanonical && evidence == .current then
    -- Source rules index the normalized string, so this shortcut and the artifact path produce
    -- findings in one coordinate system and remain interchangeable in the result cache. They are
    -- also now the same call: `runRules` folds over the one registry either way, so this path can
    -- no longer decide a rule differently from the artifact path. It used to, by passing a literal
    -- `true` where the artifact path passed the artifact's own flag (`notes/01-rule-facts.md` §2).
    -- Gated on `renderCanonical` because it takes no artifact, and canonical text cannot be
    -- rendered without the projection an artifact carries.
    let normalized := (LosslessSource.normalize snapshot.source).1
    return some <| SemanticAnalysis.success normalized (runSourceRules normalized)
  else if let some artifact := officialArtifact? then
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

/-- Project one analysis into the edits a preview or write would apply.

The patch is based on **canonical text** when the mode renders it, and on the file's own normalized
bytes otherwise. This is the whole of the formatter integration: `format` prints `output`, `diff`
diffs `normalized` against it, and `fix` validates and publishes it, so basing the patch canonically
makes all three format without any of them learning that layout exists.

The fixes come from `result.canonical?`'s own findings, never from `result.findings`. Both are the
same rules; they index different strings. `RFP-SPEC` §6 measured the gap — canonicalizing
`namespace     Alpha` deletes four bytes — so a `result.findings` fix applied here would land four
columns off and corrupt the file. `findings` stays original-coordinate because it is what the report
shows the user, whose file has not moved. -/
private def prepareFile (plan : RulePlan) (renderCanonical : Bool) (snapshot : SourceSnapshot)
    (analysis : SemanticAnalysis) : Except FileReport PreparedFile := do
  let some result := analysis.result?
    | throw (baseReport snapshot "broken" #[] analysis.diagnostics)
  let findings := plan.findings snapshot.relativePath result.findings
  let (normalized, lineEndings) := LosslessSource.normalize snapshot.source
  let (base, baseFindings) :=
    match (if renderCanonical then result.canonical? else none) with
    | some canonical => (canonical.text, plan.findings snapshot.relativePath canonical.findings)
    | none => (normalized, findings)
  let patch ← match preparePatch base baseFindings with
    | .ok patch => pure patch
    | .error error =>
      throw (baseReport snapshot "rejected" findings #[toString error])
  return { findings, normalized, lineEndings, patch }

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

private def previewFile (mode : PreviewMode) (plan : RulePlan) (snapshot : SourceSnapshot)
    (analysis : SemanticAnalysis) : IO FileReport := do
  match prepareFile plan mode.rendersCanonical snapshot analysis with
  | .error report => return report
  | .ok prepared =>
    let findings := prepared.findings
    match mode with
    | .check =>
      return baseReport snapshot (if findings.isEmpty then "clean" else "findings") findings
    | .format =>
      if prepared.changed then
        return { (baseReport snapshot "would-format" findings) with
          formatted := some prepared.output }
      return baseReport snapshot "clean" findings
    | .diff =>
      if prepared.changed then
        -- Both sides of the diff are normalized: a CRLF file must not read as every line changed.
        return { (baseReport snapshot "would-diff" findings) with
          diff := some (unifiedDiff snapshot.relativePath prepared.normalized
            prepared.patch.formatted) }
      return baseReport snapshot "clean" findings

private def fixFile (run : ExactRun) (plan : RulePlan) (snapshot : SourceSnapshot)
    (analysis : SemanticAnalysis) : IO FileReport := do
  match prepareFile plan (renderCanonical := true) snapshot analysis with
  | .error report => return report
  | .ok prepared =>
    let findings := prepared.findings
    unless prepared.changed do
      return baseReport snapshot "clean" findings
    let output := prepared.output
    -- The validator re-elaborates exactly the bytes a write would publish, line endings included.
    -- It renders no canonical text: the question is whether these bytes elaborate, and rendering a
    -- layout for a candidate nothing will print is work with no reader.
    let candidate := snapshot.withSource output
    let validation ← run.analyzeSnapshot candidate (renderCanonical := false) (validator := true)
    if let some report := validationReport snapshot findings validation then
      return report
    match ← publishAtomic snapshot.path snapshot.source output with
    | .error message => return baseReport snapshot "rejected" findings #[message]
    | .ok _ =>
      return { (baseReport snapshot "fixed" findings) with
        formatted := some output
        written := true }

def ExactRun.checkSnapshot (run : ExactRun) (plan : RulePlan)
    (snapshot : SourceSnapshot) : IO FileReport := do
  let analysis ← run.analyzeSnapshot snapshot (renderCanonical := false)
  previewFile .check plan snapshot analysis

private def summarize (mode : RunMode) (files : Array FileReport)
    (failures : Array String := #[]) : RunReport :=
  let findings := files.foldl (fun total file => total + file.findings.size) 0
  let changed := files.foldl (fun total file =>
    if file.status == "findings" || file.status == "would-format" ||
        file.status == "would-diff" || file.status == "fixed" then total + 1 else total) 0
  let written := files.foldl (fun total file => if file.written then total + 1 else total) 0
  let broken := files.foldl (fun total file =>
    if file.status == "broken" then total + 1 else total) 0
  let rejected := files.foldl (fun total file =>
    if file.status == "rejected" then total + 1 else total) 0
  { mode := mode.toString, files, findings, changed, written, broken, rejected,
    infrastructureFailures := failures }

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
  let plan ← match config.rulePlan request.select request.ignore with
    | .ok plan => pure plan
    | .error message => throw <| IO.userError message
  let project ← Project.load root config request.files
  recordDuration "workspace_load" project.workspaceLoadNanos
  recordDuration "selection_snapshot" project.selectionNanos
  let snapshots := project.targets
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
  let cached := cached.map fun cached? => cached?.filter (cacheHitServes renderCanonical)
  if cached.all Option.isSome then
    if let some previewMode := request.mode.preview? then
      let mut files := #[]
      for (snapshot, cached?) in snapshots.zip cached do
        if let some analysis := cached? then
          files := files.push (← previewFile previewMode plan snapshot analysis)
      return summarize request.mode files
  let evidenceStarted ← IO.monoNanosNow
  let evidence ← Project.moduleEvidence project
  let evidenceFinished ← IO.monoNanosNow
  recordPhase "module_evidence" evidenceStarted evidenceFinished
  let artifactStarted ← IO.monoNanosNow
  -- A rendering mode needs the projection an artifact carries, whatever the selected rules need.
  let artifacts ← if plan.requiredTier != .source || renderCanonical then
    officialArtifacts project.workspace snapshots
  else
    pure (Array.replicate snapshots.size none)
  let artifactFinished ← IO.monoNanosNow
  recordPhase "official_artifacts" artifactStarted artifactFinished
  let available ← (((snapshots.zip cached).zip evidence).zip artifacts).mapM fun
    | (((snapshot, cached?), sourceEvidence), artifact?) =>
      availableAnalysis plan renderCanonical sourceEvidence snapshot cached? artifact?
  if available.all Option.isSome then
    if let some previewMode := request.mode.preview? then
      let analyses := available.filterMap id
      let files ← (snapshots.zip analyses).mapM fun (snapshot, analysis) =>
        previewFile previewMode plan snapshot analysis
      if let some cache := cache? then
        cache.writeAll project snapshots available
      return summarize request.mode files
  withExactRun project request.maxMemoryGiB fun exactRun => do
    let mut files := #[]
    let mut failures := #[]
    let mut analyses := #[]
    for (snapshot, available?) in snapshots.zip available do
      try
        let analysis ← match available? with
          | some analysis => pure analysis
          | none => exactRun.analyzeSnapshot snapshot renderCanonical
        analyses := analyses.push (some analysis)
        let report ← match request.mode with
          | .fix => fixFile exactRun plan snapshot analysis
          | .check => previewFile .check plan snapshot analysis
          | .format => previewFile .format plan snapshot analysis
          | .diff => previewFile .diff plan snapshot analysis
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
    return summarize request.mode files failures

private unsafe def runAnalyzeChild (args : List String) : IO UInt32 := do
  let [setupPath, snapshotPath, displayPath, maxBytes] := args
    | return 2
  let some maxBytes := maxBytes.toNat?
    | return 2
  Lean.Internal.setMaxMemory maxBytes.toUSize
  let .ok setupJson := Lean.Json.parse (← IO.FS.readFile setupPath)
    | throw <| IO.userError "invalid ModuleSetup JSON"
  let .ok setup := Lean.fromJson? setupJson
    | throw <| IO.userError "invalid ModuleSetup payload"
  let source ← IO.FS.readFile snapshotPath
  let envelope ← analyzeExact setup source displayPath
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
