module

public import Test

/-!
# The cache suite: entry-granularity cache invalidation

Port of `tests/cache/run.sh`. The claim under test is the one `LeanFmt/Cache/Spec.lean` proved
over a pure decision function: an entry is served only when its
source **and its grammar** are current, and an edit invalidates the entries that depend on it and
no others.

This runs against `tests/cache/project`, a self-contained Lean package, and not against the
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

/-- The `cache.<key>=N` stat one `check` emits on stderr under `LEAN_FMT_PROFILE_PHASES=1`.
Missing or malformed is a failure, not a zero — the old script's empty-variable arithmetic error. -/
private def statFrom (stderr key : String) : IO Nat := do
  let statPrefix := s!"cache.{key}="
  for line in stderr.splitOn "\n" do
    if line.startsWith statPrefix then
      match (line.drop statPrefix.length).toNat? with
      | some n => return n
      | none => throw <| IO.userError s!"unparseable stat line: {line}"
  throw <| IO.userError s!"missing {statPrefix} in the check's stderr:\n{stderr}"

/-- One profiled `check` against the fixture project. -/
private def profiledCheck (ctx : Ctx) (args : Array String := #[]) : IO ProcResult :=
  runProc ctx.fmt (#["check"] ++ args) (cwd? := some ctx.project)
    (env := #[("LEAN_FMT_PROFILE_PHASES", some "1")])

/-- Entries served from cache on one `check`. -/
private def served (ctx : Ctx) : IO Nat := do
  statFrom (← profiledCheck ctx).stderr "served"

/-- Total targets discovered. Expectations are written relative to this rather than to a literal,
so adding a fixture module does not silently turn a real assertion into arithmetic maintenance. -/
private def targets (ctx : Ctx) : IO Nat := do
  statFrom (← profiledCheck ctx).stderr "targets"

private def rebuild (ctx : Ctx) (label : String := "fixture rebuild") : IO Unit := do
  discard <| expectExit 0 label "lake" #["build"] (cwd? := some ctx.project)
    (env := #[("LEAN_NUM_THREADS", some "1")])

/-- For the shapes that deliberately break the build. -/
private def rebuildBroken (ctx : Ctx) (label : String) : IO Unit := do
  let result ← runProc "lake" #["build"] (cwd? := some ctx.project)
    (env := #[("LEAN_NUM_THREADS", some "1")])
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
  if !(← dir.isDir) then return acc
  let mut acc := acc
  for entry in ← dir.readDir do
    if ← entry.path.isDir then
      acc ← collectJson entry.path acc
    else if entry.path.extension == some "json" then
      acc := acc.push entry.path
  return acc

private def indexFiles (ctx : Ctx) : IO (Array System.FilePath) :=
  collectJson (ctx.project / ".lean-fmt-cache" / "results") #[]

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

private def leaf (ctx : Ctx) : System.FilePath := ctx.project / "Fixture" / "Leaf.lean"
private def wide (ctx : Ctx) : System.FilePath := ctx.project / "Fixture" / "Wide.lean"

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
  let some index := files[0]?
    | throw <| IO.userError "no cache index to rewrite"
  let parsed ← parseJson (← IO.FS.readFile index) "cache index"
  IO.FS.writeFile index ((parsed.setObjVal! "schema" "lean-fmt.result-cache.v3").compress)
  ensureEq "a v3 index is an unconditional miss" 0 (← served ctx)
  ensureEq "the replacement index serves every target" ctx.total (← served ctx)

/-- Two cold writers may race on the same atomic index, but neither may publish partial JSON or
leave the cache unable to serve the complete identical selection. -/
private def testConcurrentColdWriters (ctx : Ctx) : IO Unit := do
  removeDirAll? (ctx.project / ".lean-fmt-cache")
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
Guards the property the old whole-project source walk destroyed: before this stack, editing one of
112 files left 0 entries hitting, because `environment` folded project source bytes into the index
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
  ensureEq "comment-only edit to a dependency leaves dependents cached" (ctx.total - 2) servedCount
  restoreFile ctx "Wide.lean"

/-- §4. A semantic edit to a widely-imported module invalidates its dependents. -/
private def testSemanticEdit (ctx : Ctx) : IO Unit := do
  let source ← IO.FS.readFile (wide ctx)
  ensure (source.contains "def wideValue : Nat := 2") "§4 fixture is not in its baseline state"
  writeFile (wide ctx) (source.replace "def wideValue : Nat := 2" "def wideValue : Nat := 42")
  rebuild ctx
  let servedCount ← probe ctx "semantic edit to a dependency"
  ensureEq "semantic edit to a dependency invalidates Wide, User, Other, lakefile"
    (ctx.total - 4) servedCount
  restoreFile ctx "Wide.lean"

/-- §5. The open-grammar hazard: editing only a `notation` re-analyzes its *users*, whose bytes
never changed. This is the case a source-digest-only key cannot see, and the reason
`CacheIdentity` carries `closure` at all. `Other` and `Leaf` must keep hitting — catching the
hazard must not mean invalidating the world.

Mutation-checked in the old script: with `closureDigest?` returning a constant, this run serves one
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
  writeFile notationPath (notationSource.replace
    "notation:65 a \" <+> \" b => a + b" "notation:65 a \" <+> \" b => a * b")
  ensure ((← IO.FS.readFile notationPath).contains "b => a * b") "§5 notation edit did not apply"
  rebuild ctx
  ensureEq "User's bytes are untouched by the notation edit" userBefore (← sha256 userPath)
  let servedCount ← probe ctx "notation-only edit"
  ensureEq "a notation edit invalidates Notation, User, lakefile -- and nothing else"
    (ctx.total - 3) servedCount

/-- §6. Revisions do not accumulate index files: five rebuild-and-check cycles have run above, and
a per-revision index would have left one orphan each. -/
private def testIndexBounded (ctx : Ctx) : IO Unit := do
  ensureEq "index file count is still 1 after five revisions" 1 (← indexCount ctx)

/-- §7.1. A module added. It is new, so it misses; nothing else should. -/
private def testModuleAdded (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  writeFile (ctx.project / "Fixture" / "Added.lean")
    "module\n\npublic section\n\ndef addedValue : Nat := 9\n"
  rebuild ctx
  let servedCount ← probe ctx "module added"
  ensureEq "adding a module invalidates the new module and the lakefile only"
    (ctx.total + 1 - 2) servedCount

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
  writeFile otherPath (other.replace "import Fixture.Wide"
    "import Fixture.Wide\nimport Fixture.Notation")
  rebuild ctx
  let servedCount ← probe ctx "import edge added"
  ensureEq "adding an import edge invalidates the importer and the lakefile only"
    (ctx.total - 2) servedCount

/-- §7.4. A module renamed. The old entry is orphaned inside the index; the new name is cold. -/
private def testModuleRenamed (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  IO.FS.rename (leaf ctx) (ctx.project / "Fixture" / "Renamed.lean")
  rebuild ctx
  let servedCount ← probe ctx "module renamed"
  ensureEq "renaming a module invalidates the new name and the lakefile only"
    (ctx.total - 2) servedCount
  ensureEq "a rename does not create a second index" 1 (← indexCount ctx)

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
  ensureEq "a CRLF-only change invalidates that file alone" (ctx.total - 1) servedCount

/-- §7.6. The `choice`-node and `#exit` modules stay served across an unrelated edit. Both are
inside every count above; this asserts they are actually *served* rather than quietly failing into
recomputation on every run, which would make their presence decorative. -/
private def testChoiceAndExit (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  writeFile (leaf ctx) ((← IO.FS.readFile (leaf ctx)) ++ "\n-- unrelated\n")
  rebuild ctx
  let servedCount ← probe ctx "choice and #exit modules across an unrelated edit"
  ensureEq "an unrelated edit leaves the choice and #exit modules cached" (ctx.total - 2) servedCount

/-- §8. Epoch changes still invalidate everything, and indexes stay bounded. The index name is a
digest of the epoch, not of project sources. A formatter rebuild is an epoch change: `formatter`
is the binary's path, size, and mtime. Touch to *now*, not to a fixed stamp — a fixed stamp is
idempotent, so a rerun could leave the epoch unmoved and report a rerun as a cache defect. Runs
last because it deliberately leaves the epoch moved. -/
private def testEpochChange (ctx : Ctx) : IO Unit := do
  restoreFixture ctx
  ensureEq "warm before the epoch moves" ctx.total (← served ctx)
  discard <| expectExit 0 "touch the formatter binary" "touch" #["-m", ctx.fmt]
  let servedCount ← probe ctx "formatter rebuild"
  ensureEq "a formatter rebuild invalidates every entry" 0 servedCount
  -- Repeated epoch changes must not grow the directory without bound. Originally nothing
  -- collected indexes at all: three simulated rebuilds left four files, and it kept climbing.
  for stamp in ["203001010001", "203001010002", "203001010003", "203001010004", "203001010005",
      "203001010006"] do
    discard <| expectExit 0 "stamp the formatter binary" "touch" #["-m", "-t", stamp, ctx.fmt]
    discard <| served ctx
  ensureEq "the survivors are the live index plus the retained three" 4 (← indexCount ctx)

/-- A toolchain mismatch is a hard error, not a silent re-key. -/
private def testToolchainMismatch (ctx : Ctx) : IO Unit := do
  let toolchain := ctx.project / "lean-toolchain"
  let backup ← IO.FS.readFile toolchain
  writeFile toolchain "leanprover/lean4:v0.0.0\n"
  -- Restore before asserting: the assertion throws, and the fixture must not stay tampered.
  let result ← runProc ctx.fmt #["check", "--json"] (cwd? := some ctx.project)
  writeFile toolchain backup
  ensureEq "a toolchain mismatch exits 2" 2 result.exitCode

private def cases (ctx : Ctx) : Array Case := #[
  { name := "cold-and-warm", run := testColdAndWarm ctx },
  { name := "schema-replacement", run := testSchemaReplacement ctx },
  { name := "concurrent-cold-writers", run := testConcurrentColdWriters ctx },
  { name := "leaf-edit", run := testLeafEdit ctx },
  { name := "comment-only-edit", run := testCommentOnlyEdit ctx },
  { name := "semantic-edit", run := testSemanticEdit ctx },
  { name := "notation-edit", run := testNotationEdit ctx },
  { name := "index-bounded", run := testIndexBounded ctx },
  { name := "module-added", run := testModuleAdded ctx },
  { name := "module-deleted", run := testModuleDeleted ctx },
  { name := "import-edge-added", run := testImportEdgeAdded ctx },
  { name := "module-renamed", run := testModuleRenamed ctx },
  { name := "crlf-only-change", run := testCrlfOnlyChange ctx },
  { name := "choice-and-exit", run := testChoiceAndExit ctx },
  { name := "epoch-change", run := testEpochChange ctx },
  { name := "toolchain-mismatch", run := testToolchainMismatch ctx }
]

end CacheSuite

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let project := root / "tests" / "cache" / "project"
  let fmt := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  ensure (← (root / ".lake" / "build" / "bin" / "lean-fmt").pathExists)
    "lean-fmt binary not built; run 'lake build' first"
  -- Precondition for the absent-search-path-root regression: `tests/cache/dep` is
  -- required by the fixture and imported by nothing, so Lake never builds its library and this
  -- directory never exists -- while still being on the workspace's `LEAN_PATH`. That is mathlib's
  -- `Cli` shape, and it disabled the cache for entire projects. Guard the precondition, or a
  -- future build that happens to create the directory turns all of that into decoration silently.
  ensure (!(← (root / "tests" / "cache" / "dep" / ".lake" / "build" / "lib" / "lean").pathExists))
    "tests/cache/dep has been built; the absent-search-path-root coverage is no longer real"
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
      try CacheSuite.rebuild ctx "post-suite fixture restore" catch _ => pure ()
    let code ← try
      runCases "cache" (CacheSuite.cases ctx) args
    catch error =>
      cleanup
      throw error
    cleanup
    return code
