module

public import Test

import all Test.Unit.Cache

/-!
# The cache suite: entry-granularity cache invalidation

The claim under test is the one `LeanFmt/Cache/Spec.lean` proved over a pure decision function: an
entry is served only when its source **and its grammar** are current, and an edit invalidates the
entries that depend on it and no others.

This runs against `tests/fixtures/cache/project`, a self-contained Lean package, and not against the
lean-fmt repository itself. Editing any `LeanFmt/*.lean` rebuilds the `lean-fmt` binary, which
moves `formatter`, which feeds `baseDigest`, which *names the index file* — so a self-hosted
measurement invalidates everything for a reason that has nothing to do with the property being
measured. A separate package holds the formatter fixed and lets one variable move at a time.

The fixture's import graph:

    Notation  (declares `notation:65 a " <+> " b`)
       ^
       |
     User  ---> Wide <--- Other          Leaf   (nothing imports it)

`lakefile.lean` is a sixth target, keyed by the conservative whole-workspace artifact digest; it
misses on *any* rebuild. Every expected count below includes it.

The strongest assertion is `probe`'s stale-hit oracle: the cached run and the `--no-cache` run
against the same build state must produce byte-identical reports, so *what* was served is checked,
not only how much. The cached run is always the first `check` after the edit, or an intervening run
would have rewritten the entry that was supposed to be caught serving stale.
-/

open LeanFmt.Test

namespace CacheSuite

/-- Everything a case needs, resolved once in the preamble. `pristine` holds a snapshot of the
fixture's `Fixture/` directory — §7 adds, deletes, and renames modules, so the whole directory is
snapshotted rather than three named files. -/
structure Ctx where
  root : System.FilePath
  project : System.FilePath
  fmt : String
  pristine : System.FilePath
  total : Nat

/-- One profiled `check` against the fixture project. The children inherit `runProc`'s scrubbed
search paths: the host repo's traces once rode `lake test`'s exported `LEAN_PATH` into this
fixture's epoch, and a stale restored build on the ubuntu-22.04-arm release leg rewrote one
mid-run and grew a second index. The fixture's world is its lakefile and the toolchain. -/
private def profiledCheck (ctx : Ctx) (args : Array String := #[]) : IO ProcResult :=
  runProc ctx.fmt (#["check"] ++ args) (cwd? := some ctx.project) (env :=
    #[("LEAN_FMT_PROFILE_PHASES", some "1")])

/-- Entries served from cache on one `check`. -/
private def served (ctx : Ctx) : IO Nat := do
  statFrom (← profiledCheck ctx).stderr "served"

/-- Total targets discovered. Expectations are written relative to this rather than to a literal,
so adding a fixture module does not silently turn a real assertion into arithmetic maintenance. -/
private def targets (ctx : Ctx) : IO Nat := do
  statFrom (← profiledCheck ctx).stderr "targets"

private def rebuild (ctx : Ctx) (label : String := "fixture rebuild") : IO Unit := do
  discard <|
      expectExit 0 label "lake" #["build"] (cwd? := some ctx.project) (env :=
        #[("LEAN_NUM_THREADS", some "1")])

/-- For the shapes that deliberately break the build. -/
private def rebuildBroken (ctx : Ctx) (label : String) : IO Unit := do
  let result ←
    runProc "lake" #["build"] (cwd? := some ctx.project) (env := #[("LEAN_NUM_THREADS", some "1")])
  ensure (result.exitCode != 0) s!"{label}: expected the fixture build to fail"

/-- Restore sources *and* build outputs. Removing a source does not remove its `.olean`: Lake
leaves orphaned artifacts behind, and the whole-workspace fallback digest is computed over the
build directory, so restoring only the sources would measure against a polluted baseline. This
cost one wrong expectation before it was caught. Ends with a warming run so the next `probe`
measures the state it intends to. -/
private def restoreFixture (ctx : Ctx) : IO Unit := do
  removeDirAll? (ctx.project / "Fixture")
  removeDirAll? (ctx.project / ".lake" / "build")
  copyTree (ctx.pristine / "Fixture") (ctx.project / "Fixture")
  rebuild ctx "fixture restore rebuild"
  discard <| served ctx

/-- The `*.json` index files under the results cache. -/
private partial def collectJson (dir : System.FilePath) (acc : Array System.FilePath) :
    IO (Array System.FilePath) := do
  if !(← dir.isDir) then
    return acc
  let mut acc := acc
  for entry in ← dir.readDir do
    if ← entry.path.isDir then
      acc ← collectJson entry.path acc
    else if entry.path.extension == some "json" then
      acc := acc.push entry.path
  return acc

private def indexFiles (ctx : Ctx) : IO (Array System.FilePath) :=
  collectJson (ctx.project / ".lean-fmt-cache" / "results") #[]

/-- The tail of the formatter's epoch forensics log, for failure messages: when an index-count
or served-count assertion fails on a platform nobody else reproduces, the moved epoch component
is in this log rather than in a theory. Empty when `LEAN_FMT_DEBUG_CACHE` was not set. -/
private def epochTail (ctx : Ctx) : IO String := do
  try
    let contents ← IO.FS.readFile (ctx.project / ".lean-fmt-cache" / "epoch.log")
    let lines := (contents.splitOn "\n").dropLast
    let tail := lines.drop (lines.length - 42)
    -- Indented throughout: the runner's digest keeps indented follower lines after a failure
    -- and drops unindented ones, so an unindented header would end the capture exactly here.
    return s!"\n  epoch log tail:\n{"\n  ".intercalate tail}"
  catch _ =>
    return "\n  (no epoch log; LEAN_FMT_DEBUG_CACHE was not set)"

private def indexCount (ctx : Ctx) : IO Nat := do
  return (← indexFiles ctx).size

/-- The stale-hit oracle: run the cached path and the `--no-cache` path against the same build
state and require byte-identical reports and exit codes. Returns the served count of the cached
run so a caller asserts granularity and correctness from one pair of runs. -/
private def probe (ctx : Ctx) (label : String) : IO Nat := do
  let cached ← profiledCheck ctx #["--json"]
  let uncached ← runProc ctx.fmt #["check", "--json", "--no-cache"] (cwd? := some ctx.project)
  ensure (cached.exitCode == uncached.exitCode)
      s!"{label}: cached exit {cached.exitCode}, --no-cache exit {uncached.exitCode}"
  ensure (cached.stdout == uncached.stdout)
      s!"{label}: STALE HIT -- cached report differs from --no-cache"
  statFrom cached.stderr "served"

/-- Restore one fixture file from the pristine snapshot and rewarm, as the sections do between
probes. -/
private def restoreFile (ctx : Ctx) (name : String) : IO Unit := do
  copyFile (ctx.pristine / "Fixture" / name) (ctx.project / "Fixture" / name)
  rebuild ctx
  discard <| served ctx

private def leaf (ctx : Ctx) : System.FilePath :=
  ctx.project / "Fixture" / "Leaf.lean"

private def wide (ctx : Ctx) : System.FilePath :=
  ctx.project / "Fixture" / "Wide.lean"

private def testColdAndWarm (ctx : Ctx) : IO Unit := do
  ensureEq "cold run serves nothing" 0 (← served ctx)
  ensureEq "unchanged warm run serves every target" ctx.total (← served ctx)
  ensureEq "one index file after warming" 1 (← indexCount ctx)
  let servedCount ← probe ctx "unchanged tree"
  ensureEq "unchanged tree still serves everything under the oracle" ctx.total servedCount

/-- Pre-release schema replacement is deletion, not migration: a v3 index must decode to no usable
entries and the next run repopulates from scratch. -/
private def testSchemaReplacement (ctx : Ctx) : IO Unit := do
  let files ← indexFiles ctx
  let some index := files[0]? | throw <| IO.userError "no cache index to rewrite"
  let parsed ← parseJson (← IO.FS.readFile index) "cache index"
  IO.FS.writeFile index ((parsed.setObjVal! "schema" "lean-fmt.result-cache.v3").compress)
  ensureEq "a v3 index is an unconditional miss" 0 (← served ctx)
  ensureEq "the replacement index serves every target" ctx.total (← served ctx)

/-- Wipe the cache while preserving the epoch forensics log: the log is evidence across the
whole suite run, not cache state any case owns. -/
private def wipeCache (ctx : Ctx) : IO Unit := do
  let logPath := ctx.project / ".lean-fmt-cache" / "epoch.log"
  let log? ←
    (try
        pure (some (← IO.FS.readFile logPath))
      catch _ =>
        pure none)
  removeDirAll? (ctx.project / ".lean-fmt-cache")
  if let some log := log? then
    IO.FS.createDirAll (ctx.project / ".lean-fmt-cache")
    IO.FS.writeFile logPath log

/-- Two cold writers may race on the same atomic index, but neither may publish partial JSON or
leave the cache unable to serve the complete identical selection. -/
private def testConcurrentColdWriters (ctx : Ctx) : IO Unit := do
  wipeCache ctx
  let runWriter : IO ProcResult :=
    runProc ctx.fmt #["check", "--output-format", "concise"] (cwd? := some ctx.project)
  let taskA ← IO.asTask runWriter Task.Priority.dedicated
  let taskB ← IO.asTask runWriter Task.Priority.dedicated
  let a ← IO.ofExcept taskA.get
  let b ← IO.ofExcept taskB.get
  ensure (a.exitCode ≤ 1 && b.exitCode ≤ 1)
      s!"concurrent cold cache writers failed: {a.exitCode}/{b.exitCode}"
  ensureEq "a warm run after concurrent writers serves every target" ctx.total (← served ctx)

/-- §2. A module with no dependents invalidates only itself (and the always-missing lakefile).
Guards the property the old whole-project source walk destroyed: under it, editing one of 112 files
left 0 entries hitting, because `environment` folded project source bytes into the index
*filename* and renamed it. -/
private def testLeafEdit (ctx : Ctx) : IO Unit := do
  writeFile (leaf ctx) ((← IO.FS.readFile (leaf ctx)) ++ "\n-- entry-granularity probe\n")
  rebuild ctx
  let servedCount ← probe ctx "edit of a module with no dependents"
  ensureEq "editing a module with no dependents invalidates it and the lakefile only"
      (ctx.total - 2) servedCount
  restoreFile ctx "Leaf.lean"

/-- §3. A comment-only edit to a widely-imported module does not invalidate its dependents. Lake's
outputs are content-addressed, so a comment does not move `importAllArts` and the dependents'
grammar is provably unchanged — a precision property an mtime-based key could not have. -/
private def testCommentOnlyEdit (ctx : Ctx) : IO Unit := do
  writeFile (wide ctx) ((← IO.FS.readFile (wide ctx)) ++ "\n-- comment only\n")
  rebuild ctx
  let servedCount ← probe ctx "comment-only edit to a dependency"
  ensureEq s!"comment-only edit to a dependency leaves dependents cached{← epochTail ctx}"
      (ctx.total - 2) servedCount
  restoreFile ctx "Wide.lean"

/-- A `--no-validate` publication never becomes persistent cache evidence. A rebuilt leaf edit
gives the bypass its admitted frontier; the run bypasses and reports it, and the write boundary
refuses the bypassed analysis audibly (`cache_write_refused_bypassed`). The default `format`
over the same bytes must then *revalidate* — a stored bypass would be served back instead,
reporting `validationBypassed=1` with no `candidate_reparse` line. -/
private def testBypassNeverStored (ctx : Ctx) : IO Unit := do
  writeFile (leaf ctx) ((← IO.FS.readFile (leaf ctx)) ++ "\n-- bypass storage probe\n")
  rebuild ctx
  let args := #["format", "--json", "Fixture/Leaf.lean"]
  let bypassed ←
    runProc ctx.fmt (args ++ #["--no-validate"]) (cwd? := some ctx.project) (env :=
        #[("LEAN_FMT_PROFILE_PHASES", some "1")])
  ensureEq "bypass probe: --no-validate format exit" 0 bypassed.exitCode
  ensureContains bypassed.stderr "cache.candidate_validation_bypass="
      "bypass probe: the bypass did not fire"
  ensureContains bypassed.stderr "cache.cache_write_refused_bypassed="
      "bypass probe: the write refusal was not counted"
  let bypassedReport ← parseJson bypassed.stdout "bypass probe"
  ensureJsonAt bypassedReport [.field "validationBypassed"] (Lean.toJson (1 : Nat)) "bypass probe"
  let exact ←
    runProc ctx.fmt args (cwd? := some ctx.project) (env :=
        #[("LEAN_FMT_PROFILE_PHASES", some "1")])
  ensureEq "bypass probe: default format exit" 0 exact.exitCode
  let exactReport ← parseJson exact.stdout "bypass probe"
  ensureJsonAt exactReport [.field "validationBypassed"] (Lean.toJson (0 : Nat))
      "bypass probe: the default run published on someone else's validation"
  ensureContains exact.stderr "cache.candidate_reparse="
      "bypass probe: the default run did not revalidate -- the bypassed candidate was served"
  restoreFile ctx "Leaf.lean"

/-- §4. A semantic edit to a widely-imported module invalidates its dependents. -/
private def testSemanticEdit (ctx : Ctx) : IO Unit := do
  let source ← IO.FS.readFile (wide ctx)
  ensure (source.contains "def wideValue : Nat := 2") "§4 fixture is not in its baseline state"
  writeFile (wide ctx) (source.replace "def wideValue : Nat := 2" "def wideValue : Nat := 42")
  rebuild ctx
  let servedCount ← probe ctx "semantic edit to a dependency"
  ensureEq "semantic edit to a dependency invalidates Wide, User, Other, lakefile" (ctx.total - 4)
      servedCount
  restoreFile ctx "Wide.lean"

/-- §5. The open-grammar hazard: editing only a `notation` re-analyzes its *users*, whose bytes
never changed. This is the case a source-digest-only key cannot see, and the reason
`CacheIdentity` carries `closure` at all. `Other` and `Leaf` must keep hitting — catching the
hazard must not mean invalidating the world.

Mutation-checked: with `closureDigest?` returning a constant, this run serves one
entry more than expected, and the extra entry is `User` — a stale hit on byte-identical source
under a changed grammar, which `probe` catches independently of the count. -/
private def testNotationEdit (ctx : Ctx) : IO Unit := do
  let userPath := ctx.project / "Fixture" / "User.lean"
  let userBefore ← sha256 userPath
  let notationPath := ctx.project / "Fixture" / "Notation.lean"
  let notationSource ← IO.FS.readFile notationPath
  -- Assert the *precondition*, not just the postcondition: a fixture already left in the edited
  -- state would make the replace a no-op that a postcondition-only guard still accepts.
  ensure (notationSource.contains "b => a + b") "§5 fixture is not in its baseline state"
  writeFile notationPath
      (notationSource.replace "notation:65 a \" <+> \" b => a + b"
        "notation:65 a \" <+> \" b => a * b")
  ensure ((← IO.FS.readFile notationPath).contains "b => a * b") "§5 notation edit did not apply"
  rebuild ctx
  ensureEq "User's bytes are untouched by the notation edit" userBefore (← sha256 userPath)
  let servedCount ← probe ctx "notation-only edit"
  ensureEq "a notation edit invalidates Notation, User, lakefile -- and nothing else"
      (ctx.total - 3) servedCount

/-- §6. Revisions do not accumulate index files: five rebuild-and-check cycles have run above, and
a per-revision index would have left one orphan each. -/
private def testIndexBounded (ctx : Ctx) : IO Unit := do
  ensureEq s!"index file count is still 1 after five revisions{← epochTail ctx}" 1
      (← indexCount ctx)

/-- §7.1. A module added. It is new, so it misses; nothing else should. -/
private def testModuleAdded (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  writeFile (ctx.project / "Fixture" / "Added.lean")
      "module\n\npublic section\n\ndef addedValue : Nat := 9\n"
  rebuild ctx
  let servedCount ← probe ctx "module added"
  ensureEq "adding a module invalidates the new module and the lakefile only" (ctx.total + 1 - 2)
      servedCount

/-- §7.2. A module deleted from the middle of a closure. `User` and `Other` import `Wide`, so the
build breaks; the point is that neither is served a result computed under the module that
vanished. -/
private def testModuleDeleted (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  IO.FS.removeFile (wide ctx)
  rebuildBroken ctx "module deleted"
  let servedCount ← probe ctx "module deleted mid-closure"
  ensureEq "deleting an imported module invalidates its dependents" (ctx.total - 1 - 2) servedCount

/-- §7.3. An import edge added. `Other` gains an import; nothing imports `Other`, so nothing
cascades. -/
private def testImportEdgeAdded (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  let otherPath := ctx.project / "Fixture" / "Other.lean"
  let other ← IO.FS.readFile otherPath
  ensure ((other.splitOn "import Fixture.Wide").length == 2)
      "§7.3 fixture does not import Wide exactly once"
  writeFile otherPath
      (other.replace "import Fixture.Wide" "import Fixture.Wide\nimport Fixture.Notation")
  rebuild ctx
  let servedCount ← probe ctx "import edge added"
  ensureEq "adding an import edge invalidates the importer and the lakefile only" (ctx.total - 2)
      servedCount

/-- §7.4. A module renamed. The old entry is orphaned inside the index; the new name is cold. -/
private def testModuleRenamed (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  IO.FS.rename (leaf ctx) (ctx.project / "Fixture" / "Renamed.lean")
  rebuild ctx
  let servedCount ← probe ctx "module renamed"
  ensureEq s!"renaming a module invalidates the new name and the lakefile only{← epochTail ctx}"
      (ctx.total - 2) servedCount
  let indexes ← indexFiles ctx
  -- Mtimes name the case that created each file: a second index means the epoch moved, and
  -- when it moved is the difference between a rename defect and an environment that flaps.
  let mut descriptions : Array String := #[]
  for index in indexes do
    let info ← index.metadata
    descriptions := descriptions.push s!"{index} (size {info.byteSize}, mtime {info.modified.sec})"
  ensure (indexes.size == 1)
      s!"a rename does not create a second index:\n  {"
\n  ".intercalate descriptions.toList}{← epochTail ctx}"

/-- §7.5. A change visible only to normalization: LF to CRLF, identical normalized text. It still
misses: every compiler-produced offset indexes `raw.crlfToLf`, so the *analysis* is unchanged, but
`format` and `fix` denormalize back to the file's own line endings when they publish, so the raw
bytes are part of what an entry promises. Missing is the conservative direction and costs one
recomputation. -/
private def testCrlfOnlyChange (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  let source ← IO.FS.readFile (leaf ctx)
  ensure (!(source.contains '\r')) "fixture is not LF-only"
  writeFile (leaf ctx) (source.replace "\n" "\r\n")
  rebuild ctx
  let servedCount ← probe ctx "CRLF-only change"
  ensureEq s!"a CRLF-only change invalidates that file alone{← epochTail ctx}" (ctx.total - 1)
      servedCount

/-- §7.6. The `choice`-node and `#exit` modules stay served across an unrelated edit. Both are
inside every count above; this asserts they are actually *served* rather than quietly failing into
recomputation on every run, which would make their presence decorative. -/
private def testChoiceAndExit (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  writeFile (leaf ctx) ((← IO.FS.readFile (leaf ctx)) ++ "\n-- unrelated\n")
  rebuild ctx
  let servedCount ← probe ctx "choice and #exit modules across an unrelated edit"
  ensureEq "an unrelated edit leaves the choice and #exit modules cached" (ctx.total - 2)
      servedCount

/-- The cache epoch, both directions.

**A touched binary is not a new formatter.** Identity is the binary's content, so a new
modification time changes nothing and every entry still serves. It used to be (path, size, mtime),
and the consequence was that any CI job rebuilding lean-fmt started cold every run for a binary
that behaved identically -- `docs/ci.md` carried a whole section of workarounds for it.

**A moved search path is a new epoch**, because precedence decides what a module's imports
resolve to. Nothing serves, and the new index does not accumulate beside the old ones without
bound: originally nothing collected indexes at all, and three epoch changes left four files and
kept climbing.

The search path is what drives the epoch here because a formatter with different *bytes* cannot be
staged -- `ctx.fmt` is the repository's own binary, and a modified copy of an ad-hoc signed
executable does not run. -/
private def testEpochChange (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  ensureEq "warm before the epoch moves" ctx.total (← served ctx)
  discard <| expectExit 0 "touch the formatter binary" "touch" #["-m", ctx.fmt]
  ensureEq "a touched formatter orphaned the cache" ctx.total (← probe ctx "formatter touch")
  -- The extra entry need not exist: an absent search-path root is recorded as the fact that it is
  -- absent, which moves the digest the same way a present one does.
  let epochRun (tag : String) : IO Nat := do
    -- The deliberate opt-out of `runProc`'s scrub, and the only one in the suite: this case
    -- exists to move the search path, and the boundary suite enumerates it for exactly that
    -- reason. The move is precisely this directory and nothing the host exported.
    let extra := ctx.pristine / s!"epoch-{tag}"
    let result ←
      runProc ctx.fmt #["check"] (cwd? := some ctx.project) (env :=
          #[("LEAN_FMT_PROFILE_PHASES", some "1"), ("LEAN_PATH", some extra.toString)])
    statFrom result.stderr "served"
  ensureEq "a moved search path served stale entries" 0 (← epochRun "1")
  for tag in ["2", "3", "4", "5", "6", "7"]do
    discard <| epochRun tag
  ensureEq "the survivors are the live index plus the retained three" 4 (← indexCount ctx)

/-- An orphaned artifact in a dependency root must not disable the cache.

The sibling of the absent-root defect this fixture's `dep` package already exists for, one step
further along: the directory is *present* and holds an `.olean` with no `.trace` beside it. Every
artifact under a dependency root used to have to validate or the whole workspace got no cache at
all, silently, because a disabled cache is a supported outcome.

Measured on `mathlib4`: 8,408 `.olean` files, 8,407 `.trace` files. The one orphan Lake left behind
rather than pruned (`Counterexamples/SorgenfreyLine.olean`) cost every project depending on that
checkout its entire result cache — 63 of 63 targets re-analyzed on every run.

The orphan must also be *covered*, not merely tolerated: rewriting its bytes moves the epoch, so
nothing serves afterwards. Coverage is what the refusal was protecting, and it is why this asserts
both directions.

It is also where the epoch's per-root memo is held to its stamp: this is the one case with a
dependency root whose contents this suite can change, so it asserts that an unchanged root
reproduces its epoch and that a rewrite keeping the artifact's size still moves it.

`finally` because leaving the directory behind would break the next run's absent-root
precondition. -/
private def testOrphanedDependencyArtifact (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  ensureEq "warm before the orphan appears" ctx.total (← served ctx)
  let depBuild := ctx.root / "tests" / "fixtures" / "cache" / "dep" / ".lake"
  let depLib := depBuild / "build" / "lib" / "lean"
  let orphan := depLib / "Orphan.olean"
  try
    IO.FS.createDirAll depLib
    writeFile orphan "not a real olean, and no trace beside it\n"
    -- The root going from absent to present is itself an epoch move, so this run is cold for a
    -- reason that has nothing to do with the orphan. Assert it rather than warm past it silently.
    ensureEq "a dependency root appearing did not move the epoch" 0 (← served ctx)
    ensureEq "an orphaned dependency artifact disabled the cache" ctx.total
        (← probe ctx "orphaned dependency artifact")
    writeFile orphan "different bytes, same absent trace\n"
    ensureEq "a changed untraced artifact served stale entries" 0 (← served ctx)
    -- The epoch memoizes each dependency root against a stamp that only stats, so both arms of
    -- that memo are asserted here. An unchanged root must reproduce the epoch it hashed...
    ensureEq "a memoized dependency root did not reproduce its epoch" ctx.total (← served ctx)
    -- ...and a rewrite the stamp could only catch by modification time must still move it.
    writeFile orphan "DIFFERENT BYTES, same absent trace\n"
    ensureEq "a same-size rewrite of a dependency artifact served stale entries" 0 (← served ctx)
  finally
    removeDirAll? depBuild

/-- A toolchain mismatch is a hard error, not a silent re-key. -/
private def testToolchainMismatch (ctx : Ctx) : IO Unit := do
  let toolchain := ctx.project / "lean-toolchain"
  let backup ← IO.FS.readFile toolchain
  writeFile toolchain "leanprover/lean4:v0.0.0\n"
  -- Restore before asserting: the assertion throws, and the fixture must not stay tampered.
  let result ← runProc ctx.fmt #["check", "--json"] (cwd? := some ctx.project)
  writeFile toolchain backup
  ensureEq "a toolchain mismatch exits 2" 2 result.exitCode

/-- §8. The minimum-storage rule on write: a full-project write prunes entries no run can ask
for again. A deleted module's entry dies on the next full-project write; a rejection verdict
lives exactly while the header on disk still organizes to the stored candidate. -/
private def testLiveSetPrune (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  -- Baseline: the first write into an empty index has nothing to prune. (A fully-served check
  -- never reaches `writeAll` — there is nothing new to store — so pruning always happens at the
  -- first non-served full-project write.)
  wipeCache ctx
  ensureEq "a fresh cache's first write prunes nothing" 0
      (← statFrom (← profiledCheck ctx).stderr "entries_pruned")
  -- Dead entries drop at the first write that can know: `Leaf`'s entry is orphaned by the
  -- deletion and `Wide`'s is superseded by the edit; the edit is what forces the write. The
  -- rebuild also moves the whole-workspace artifact digest, so the lakefile's old entry is the
  -- third — it is keyed by that digest and misses on *any* rebuild by design.
  IO.FS.removeFile (leaf ctx)
  let wideContents ← IO.FS.readFile (wide ctx)
  writeFile (wide ctx) (wideContents ++ "\n-- prune-test touch\n")
  rebuild ctx "leaf deleted, wide touched"
  ensureEq "the orphaned and superseded entries are pruned" 3
      (← statFrom (← profiledCheck ctx).stderr "entries_pruned")
  -- A rejection verdict is a live entry: sabotage `User`'s header (disordered, unknown module),
  -- organize stores the verdict, and the next full-project write prunes only the pre-sabotage
  -- `User` entry — the verdict's candidate is still this header's candidate.
  restoreFixture ctx
  wipeCache ctx
  discard <| profiledCheck ctx
  let userPath := ctx.project / "Fixture" / "User.lean"
  let user ← IO.FS.readFile userPath
  writeFile userPath
      (user.replace "import Fixture.Wide" "import Fixture.Wide\nimport Fixture.NoSuchModule")
  let rejected ←
    runProc ctx.fmt #["organize", "--json", "Fixture/User.lean"] (cwd? := some ctx.project)
  ensure (rejected.exitCode == 1)
      s!"the sabotaged header was not rejected:\n{rejected.stdout}\n{rejected.stderr}"
  ensureEq "the old entry dies but the verdict lives" 1
      (← statFrom (← profiledCheck ctx).stderr "entries_pruned")
  let second ←
    runProc ctx.fmt #["organize", "--json", "Fixture/User.lean"] (cwd? := some ctx.project) (env :=
        #[("LEAN_FMT_PROFILE_PHASES", some "1")])
  ensure (second.exitCode == 1) s!"the served verdict changed the outcome:\n{second.stdout}"
  ensureEq "the verdict survived the full-project prune" 1 (← statFrom second.stderr "verdict_hits")

/-- §15. The trace characterization, hermetically: a fully-built tree passes, a partial rebuild
that leaves every importer's expectations stale refuses — naming the repairing build, computed
from the stale importers — and a full rebuild repairs it. The unit tier exercises the same gate
against whatever the real tree holds; this proves the gate's verdicts against a tree whose
freshness is controlled one variable at a time.

It needs its own generated project: the cache fixture is a *legacy* (pre-`module`) package,
whose traces record only `importArts` — `importAllArts` exists under the module system. Three
modules, two import edges, so rebuilding the one importee stales every pair. -/
private def testTraceCharacterization (ctx : Ctx) : IO Unit := do
  withTempDir fun project => do
      copyFile (ctx.root / "lean-toolchain") (project / "lean-toolchain")
      writeFile (project / "lakefile.lean")
          "import Lake\nopen Lake DSL\n\npackage probe\n\n@[default_target]\n\
        lean_lib Probe where\n  globs := #[Glob.submodules `Probe]\n"
      IO.FS.createDirAll (project / "Probe")
      writeFile (project / "Probe" / "A.lean") "module\n\npublic def a := 0\n"
      -- `import all`: an `importAllArts` expectation is recorded per *all*-import only — a plain
      -- `import` records the narrower `importArts`. The cache's currency consumes `importAllArts`,
      -- so the probe imports the way `LeanFmt/*.lean` does.
      writeFile (project / "Probe" / "B.lean") "module\nimport all Probe.A\n\ndef b := a\n"
      writeFile (project / "Probe" / "C.lean") "module\nimport all Probe.A\n\ndef c := a + 1\n"
      let lake (label : String) (targets : Array String := #[]) : IO Unit := do
        discard <|
            expectExit 0 label "lake" (#["build"] ++ targets) (cwd? := some project) (env :=
              #[("LEAN_NUM_THREADS", some "1")])
      let traceRoot := project / ".lake" / "build" / "lib" / "lean"
      lake "characterization baseline"
      Unit.Cache.characterizeLakeTraces traceRoot
      -- A semantic edit, not comment-only: Lake must rerun the job and rewrite the trace, which a
      -- content-identical rebuild is not guaranteed to do.
      writeFile (project / "Probe" / "A.lean") "module\n\npublic def a := 0\n\npublic def a' := 1\n"
      lake "importee-only rebuild" #["Probe.A"]
      let rejected ←
        try
          Unit.Cache.characterizeLakeTraces traceRoot
          pure ""
        catch error =>
          pure error.toString
      ensure (rejected.contains "lake build" && rejected.contains "Probe.B")
          s!"a fully-stale sample did not refuse with the repairing build: {rejected}"
      lake "characterization repair"
      Unit.Cache.characterizeLakeTraces traceRoot

private def cases (ctx : Ctx) : Array Case :=
  #[{ name := "cold-and-warm", run := testColdAndWarm ctx },
    { name := "schema-replacement", run := testSchemaReplacement ctx },
    { name := "concurrent-cold-writers", run := testConcurrentColdWriters ctx },
    { name := "leaf-edit", run := testLeafEdit ctx },
    { name := "comment-only-edit", run := testCommentOnlyEdit ctx },
    { name := "bypass-never-stored", run := testBypassNeverStored ctx },
    { name := "semantic-edit", run := testSemanticEdit ctx },
    { name := "notation-edit", run := testNotationEdit ctx },
    { name := "index-bounded", run := testIndexBounded ctx },
    { name := "module-added", run := testModuleAdded ctx },
    { name := "module-deleted", run := testModuleDeleted ctx },
    { name := "import-edge-added", run := testImportEdgeAdded ctx },
    { name := "module-renamed", run := testModuleRenamed ctx },
    { name := "crlf-only-change", run := testCrlfOnlyChange ctx },
    { name := "live-set-prune", run := testLiveSetPrune ctx },
    { name := "choice-and-exit", run := testChoiceAndExit ctx },
    { name := "epoch-change", run := testEpochChange ctx },
    { name := "orphaned-dependency-artifact", run := testOrphanedDependencyArtifact ctx },
    { name := "toolchain-mismatch", run := testToolchainMismatch ctx },
    { name := "trace-characterization", run := testTraceCharacterization ctx }]

end CacheSuite

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let project := root / "tests" / "fixtures" / "cache" / "project"
  let fmt := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  ensure (← (root / ".lake" / "build" / "bin" / "lean-fmt").pathExists)
      "lean-fmt binary not built; run 'lake build' first"
  -- Precondition for the absent-search-path-root regression: `tests/fixtures/cache/dep` is
  -- required by the fixture and imported by nothing, so Lake never builds its library and this
  -- directory never exists -- while still being on the workspace's `LEAN_PATH`. That is mathlib's
  -- `Cli` shape, and it disabled the cache for entire projects. Guard the precondition, or a
  -- future build that happens to create the directory turns all of that into decoration silently.
  ensure
      (!(←
          (root / "tests" / "fixtures" / "cache" / "dep" / ".lake" / "build" / "lib" /
                "lean").pathExists))
      "tests/fixtures/cache/dep has been built; the absent-search-path-root coverage is no longer real"
  withTempDir fun pristine => do
      copyTree (project / "Fixture") (pristine / "Fixture")
      -- The fixture needs its own `lean-toolchain` -- `lean-fmt` reads one from the project root --
      -- but a committed copy would drift from the repository's. Generate it instead, so there is
      -- one source of truth. It is gitignored.
      copyFile (root / "lean-toolchain") (project / "lean-toolchain")
      removeDirAll? (project / ".lake" / "build")
      let ctx0 : CacheSuite.Ctx := { root, project, fmt, pristine, total := 0 }
      CacheSuite.rebuild ctx0
      removeDirAll? (project / ".lean-fmt-cache")
      let total ← CacheSuite.targets ctx0
      removeDirAll? (project / ".lean-fmt-cache")
      ensure (total >= 8) s!"fixture lost targets: discovered only {total}"
      let ctx : CacheSuite.Ctx := { ctx0 with total }
      let cleanup : IO Unit := do
        -- Restore the fixture to pristine even when a case failed: sources, cache, and build
        -- outputs, so the next run (and the human's tree) start clean.
        removeDirAll? (project / "Fixture")
        copyTree (pristine / "Fixture") (project / "Fixture")
        removeDirAll? (project / ".lean-fmt-cache")
        copyFile (root / "lean-toolchain") (project / "lean-toolchain")
        try
          CacheSuite.rebuild ctx "post-suite fixture restore"
        catch _ =>
          pure ()
      let code ←
        try
          runCases "cache" (CacheSuite.cases ctx) args
        catch error =>
          cleanup
          throw error
      cleanup
      return code
