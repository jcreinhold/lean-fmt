module

public import Test
import all Test.Unit.Cases
import all Test.Unit.Tools

/-!
# The unit-tier runner

What was `LeanFmtTest.lean`'s `main`, split two ways. The ~30 test functions are `Case`s now,
run by the shared harness with per-test names, isolation, and `--list`/`--filter`/`--shard`
selection — one failing test no longer hides the twenty-nine behind it. Two imports carry an
inline FMT004 ignore: the rule's "transitively available" note is the over-approximation its own
message warns about, and removing the import breaks the build. The argv subcommands are
unchanged: they exist for the shell suites (which call back into Lean for artifact verification and
benchmarks), and they keep their exact names, arities, and output until their consuming suites are
ported and absorb them.
-/

open LeanFmt.Test

/-- `doc-properties` is the one legacy subcommand that names a unit case; everything else dispatches
into `Test.Unit.Tools`. -/

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | ["artifact-projection", artifactPath, sourcePath] =>
    Unit.Tools.artifactProjection artifactPath sourcePath
  | ["comment-summary", envelopePath] => Unit.Tools.commentSummaryReport envelopePath
  | ["doc-bench"] => Unit.Tools.docBench
  | ["doc-step-counts"] => Unit.Tools.docStepCounts
  | ["doc-dump"] => Unit.Tools.docDump
  | ["validator-map-negative"] => Unit.Tools.validatorMapNegative
  | ["report-bench"] => Unit.Tools.reportBench
  | ["security-bench"] => Unit.Tools.securityBench
  | ["formatter-header", sourcePath] => Unit.Tools.formatterHeader sourcePath
  | ["doc-properties"] =>
    runCases "lean-fmt-tests" (allCases.filter (·.name == "testDoc")) []
  | ["verify-plugin-artifact", moduleName, sourcePath] => do
    Unit.Tools.verifyPluginArtifact moduleName.toName sourcePath
    IO.println "lean-fmt compiler payload verified"
    return 0
  | ["verify-facet-artifact", path, sourcePath, expectedHash] =>
    match Lake.Hash.ofString? expectedHash with
    | some expectedHash => do
      Unit.Tools.verifyFacetArtifact path sourcePath expectedHash
      IO.println "lean-fmt compiler artifact verified"
      return 0
    | none => do
      IO.eprintln "EXPECTED_HASH must be a Lake content hash"
      return 2
  | ["print-lake-hash", path] => Unit.Tools.printLakeHash path
  | ["verify-official-facet", root, sourcePath] => do
    Unit.Tools.verifyOfficialFacet root sourcePath
    IO.println "lean-fmt registered compiler facet verified"
    return 0
  | _ => runCases "lean-fmt-tests" allCases args
