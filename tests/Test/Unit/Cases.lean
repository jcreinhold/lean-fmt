module

public import Test

import Test.Unit.Cache
import Test.Unit.Config
import Test.Unit.Digest
import Test.Unit.Edit
import Test.Unit.Imports
import Test.Unit.Layout
import Test.Unit.Lsp
import Test.Unit.Progress
import Test.Unit.Rules
import Test.Unit.Semantic
import Test.Unit.Source

/-!
# The unit tier's case list

Every unit case, concatenated module by module, shared by both executables: the unit
runner (`Test.Unit`, the `lean-fmt-tests` executable) and the orchestrator (`Test.Runner`, the
`test-suites` executable).

Two of these imports carried an inline FMT004 ignore for as long as the rule read Lake's *build*
closure: `Edit` and `Layout` are transitively imported, privately, so they were reported as
redundant and removing either broke the build. The rule reads the export closure now and neither
fires, so the workaround is gone rather than merely quieter.
-/

open LeanFmt.Test

/-- Every unit case, concatenated module by module. -/
def allCases : Array Case :=
  Unit.Digest.cases ++ Unit.Rules.cases ++ Unit.Imports.cases ++ Unit.Lsp.cases ++
                Unit.Edit.cases ++
              Unit.Config.cases ++
            Unit.Cache.cases ++
          Unit.Source.cases ++
        Unit.Semantic.cases ++
      Unit.Layout.cases ++
    Unit.Progress.cases
