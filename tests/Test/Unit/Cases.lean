module

public import Test
import Test.Unit.Cache
import Test.Unit.Config
import Test.Unit.Digest
import Test.Unit.Edit -- lean-fmt: ignore[FMT004]
import Test.Unit.Imports
import Test.Unit.Layout -- lean-fmt: ignore[FMT004]
import Test.Unit.Lsp
import Test.Unit.Progress
import Test.Unit.Rules
import Test.Unit.Semantic
import Test.Unit.Source

/-!
# The unit tier's case list

Every unit case, concatenated module by module, shared by both executables: the unit
runner (`Test.Unit`, the `lean-fmt-tests` executable) and the orchestrator (`Test.Runner`, the
`test-suites` executable). Two imports carry an inline FMT004 ignore: the rule's "transitively
available" note is the over-approximation its own message warns about, and removing the import
breaks the build.
-/

open LeanFmt.Test

/-- Every unit case, concatenated module by module. -/
def allCases : Array Case :=
  Unit.Digest.cases ++ Unit.Rules.cases ++ Unit.Imports.cases ++ Unit.Lsp.cases ++
    Unit.Edit.cases ++ Unit.Config.cases ++ Unit.Cache.cases ++ Unit.Source.cases ++
    Unit.Semantic.cases ++ Unit.Layout.cases ++ Unit.Progress.cases
