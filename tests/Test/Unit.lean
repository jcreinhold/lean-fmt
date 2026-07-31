module

public import Test

import all Test.Unit.Cases
import all Test.Unit.Tools

/-!
# The unit-tier runner

What was `LeanFmtTest.lean`'s `main`, split two ways. The ~30 test functions are `Case`s now,
run by the shared harness with per-test names, isolation, and `--list`/`--filter`/`--shard`
selection — one failure no longer hides the other twenty-nine. The argv subcommands keep their
exact names, arities, and output until their consuming shell suites are ported and absorb them.
-/

open LeanFmt.Test

/-- Legacy argv subcommands dispatch into `Test.Unit.Tools`; anything else runs the shared case
list. -/

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | ["artifact-projection", artifactPath, sourcePath] =>
    Unit.Tools.artifactProjection artifactPath sourcePath
  | ["doc-bench"] => Unit.Tools.docBench
  | ["doc-step-counts"] => Unit.Tools.docStepCounts
  | ["doc-dump"] => Unit.Tools.docDump
  | ["report-bench"] => Unit.Tools.reportBench
  | ["security-bench"] => Unit.Tools.securityBench
  | ["formatter-header", sourcePath] => Unit.Tools.formatterHeader sourcePath
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
