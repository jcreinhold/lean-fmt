module

public import LeanFmt.Analysis
public import LeanFmt.Application
public import LeanFmt.ArtifactStore
public import LeanFmt.Cache
public import LeanFmt.Cli
public import LeanFmt.Comments
public import LeanFmt.Config
public import LeanFmt.Discovery
public import LeanFmt.Doc
public import LeanFmt.Edit
public import LeanFmt.Formatter.NativeLayout
public import LeanFmt.Imports
public import LeanFmt.LanguageServer
public import LeanFmt.Rules
public import LeanFmt.Suppression
public import Test

import all LeanFmt.Analysis
import all LeanFmt.Application
import all LeanFmt.ArtifactStore
import all LeanFmt.Cache
import all LeanFmt.Cli
import all LeanFmt.Comments
import all LeanFmt.Config
import all LeanFmt.Discovery
import all LeanFmt.Doc
import all LeanFmt.Edit
import all LeanFmt.Formatter.NativeLayout
import all LeanFmt.Imports
import all LeanFmt.LanguageServer
import all LeanFmt.Rules
import all LeanFmt.Suppression

import Lean.Data.Lsp

open LeanFmt LeanFmt.Internal

namespace LeanFmt.Test.Unit.Imports

/-- Parse a surface header, refusing the `none` (parser-message) case the caller never intends. -/
private def parseHeader! (source : String) : IO Imports.HeaderModel := do
  match ← Imports.parseHeaderModel source with
  | some header => return header
  | none => throw <| IO.userError s!"header did not parse: {source}"

/-- `FMT003`/`FMT004`/`FMT005` and the organizer, tested directly — import rules live outside the
`RuleImpl` engine, so the `runRulesOf` seam does not reach them; the
header rules are pure functions of the parsed surface header, and `redundantFindings` is pure over the
header plus a caller-supplied closure that stands in for the Lake graph. -/
private def testImports : IO Unit := do
  -- The surface header carries the modifier spelling, not the abstract import: `import all A` and
  -- `import A` are distinct statements, so neither is the other's duplicate (`notes` §3).
  let dup ← parseHeader! "import Foo.A\nimport Foo.A\n"
  let dupFindings := Imports.duplicateFindings dup "import Foo.A\nimport Foo.A\n"
  ensure (dupFindings.map (·.code) == #["FMT003"]) "exact duplicate did not fire FMT003 exactly once"
  ensure (dupFindings[0]!.fix?.map (·.applicability) == some .safe)
    "the duplicate-removal fix is not safe"
  -- The safe fix deletes the *later* whole line (the second `import Foo.A`, bytes [13, 26)).
  ensure (dupFindings[0]!.fix?.map (·.edits) == some #[{ range := { start := 13, stop := 26 }, replacement := "" }])
    "the duplicate fix does not delete the later line"

  -- `import all` is valid header syntax only under a `module` marker.
  let notDupSrc := "module\nimport Foo.A\nimport all Foo.A\n"
  let notDup ← parseHeader! notDupSrc
  ensure (Imports.duplicateFindings notDup notDupSrc).isEmpty
    "`import A` and `import all A` were wrongly treated as duplicates"

  -- A literal `import Init` twice is a surface duplicate — it is the phantom `Init` the abstract list
  -- injects that a surface rule can never see, not a written one (`notes` §1a).
  let dupInit ← parseHeader! "import Init\nimport Init\n"
  ensure ((Imports.duplicateFindings dupInit "import Init\nimport Init\n").size == 1)
    "a literal repeated `import Init` did not fire FMT003"

  -- FMT005 fires within one group; a blank line is a group boundary the canonical order never crosses.
  let unordered ← parseHeader! "import Foo.B\nimport Foo.A\n"
  ensure ((Imports.orderFindings unordered "import Foo.B\nimport Foo.A\n").map (·.code) == #["FMT005"])
    "out-of-order imports in one group did not fire FMT005"
  ensure ((Imports.orderFindings unordered "import Foo.B\nimport Foo.A\n")[0]!.fix?.isNone)
    "FMT005 must be report-only (no fix)"
  let grouped ← parseHeader! "import Foo.B\n\nimport Foo.A\n"
  ensure (Imports.orderFindings grouped "import Foo.B\n\nimport Foo.A\n").isEmpty
    "imports in different blank-line groups were wrongly reported out of order"

  -- FMT004: `Foo.B` is reachable via `Foo.A`'s closure, so the plain `import Foo.B` is a candidate.
  let redundant ← parseHeader! "import Foo.A\nimport Foo.B\n"
  let closure : Lean.Name → Option (Array Lean.Name) := fun name =>
    if name == `Foo.A then some #[`Foo.B] else none
  let (redFindings, redWithheld) := Imports.redundantFindings redundant closure
  ensure (redFindings.map (·.code) == #["FMT004"]) "a transitively-covered import did not fire FMT004"
  ensure (redFindings[0]!.fix?.isNone) "FMT004 must be report-only (no fix)"
  ensure (redWithheld == 0) "a plain covered import was wrongly withheld"

  -- Withholding: `import all Foo.B` under a `module` marker exposes data reachability cannot reason
  -- about, so it is withheld (counted), never reported.
  let withheld ← parseHeader! "module\nimport Foo.A\nimport all Foo.B\n"
  let (whFindings, whCount) := Imports.redundantFindings withheld closure
  ensure (whFindings.isEmpty) "an `import all` redundancy candidate was reported rather than withheld"
  ensure (whCount == 1) "the withheld-redundancy count was not recorded"
  ensure (!Imports.redundancyEligible withheld withheld.imports[1]!)
    "`import all` was judged redundancy-eligible"

  -- The organizer: dedup composed with per-group sort, everything else preserved. Text in, text out.
  let sortMe := "import Foo.B\nimport Foo.A\n"
  ensure (Imports.organize (← parseHeader! sortMe) sortMe == "import Foo.A\nimport Foo.B\n")
    "the organizer did not sort a group by module name"
  let dedupMe := "import Foo.A\nimport Foo.A\n"
  ensure (Imports.organize (← parseHeader! dedupMe) dedupMe == "import Foo.A\n")
    "the organizer did not remove a duplicate"

  -- Header rewrites preserve comments, modifiers, and group boundaries.
  -- A comment is a group boundary: each group sorts independently and the comment survives verbatim.
  let twoGroups := "import Foo.D\nimport Foo.A\n-- section\nimport Foo.Z\nimport Foo.B\n"
  ensure (Imports.organize (← parseHeader! twoGroups) twoGroups ==
      "import Foo.A\nimport Foo.D\n-- section\nimport Foo.B\nimport Foo.Z\n")
    "the organizer did not sort each comment-delimited group while preserving the comment"
  -- A trailing inline comment forces a boundary: the two imports are not reordered across it.
  let trailing := "import Foo.B -- note\nimport Foo.A\n"
  ensure (Imports.organize (← parseHeader! trailing) trailing == trailing)
    "the organizer reordered across a trailing comment or dropped it"
  -- A modifier rides on the sliced statement bytes through a reorder (`import all` needs `module`).
  let modifier := "module\nimport all Foo.B\nimport Foo.A\n"
  ensure (Imports.organize (← parseHeader! modifier) modifier ==
      "module\nimport Foo.A\nimport all Foo.B\n")
    "the organizer dropped a modifier while reordering"

  -- A `prelude` file has no phantom `Init`: the surface model sees only the written imports (`notes` §1a).
  let prelude ← parseHeader! "prelude\nimport Foo.A\n"
  ensure (prelude.hasPrelude && prelude.imports.map (·.module) == #[`Foo.A])
    "the prelude header model does not match the written imports"

/-- The cases this module contributes to the unit runner, in run order. -/
public def cases : Array Case := #[
  { name := "testImports", run := testImports }]

end LeanFmt.Test.Unit.Imports
