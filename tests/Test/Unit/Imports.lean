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

/-! ## Imports

The import rules over headers written out in full: what counts as a duplicate, what counts as
redundant, and what ordering the rule asks for. Header shape is the whole input, so the cases spell
the headers rather than borrow a file. -/

/-- Parse a surface header, refusing the `none` (parser-message) case the caller never intends. -/
private def parseHeader! (source : String) : IO Imports.HeaderModel := do
  match ← Imports.parseHeaderModel source with
  | some header =>
    return header
  | none =>
    throw <| IO.userError s!"header did not parse: {source}"

/-- `FMT003`/`FMT004`/`FMT005` and the organizer, tested directly — import rules live outside the
`RuleImpl` engine, so the `runRulesOf` seam does not reach them; the
header rules are pure functions of the parsed surface header, and `redundantFindings` is pure over the
header plus a caller-supplied closure that stands in for the Lake graph. -/
private def testImports : IO Unit := do
  -- The surface header carries the modifier spelling, not the abstract import: `import all A` and
  -- `import A` are distinct statements, so neither is the other's duplicate (`notes` §3).
  let dup ← parseHeader! "import Foo.A\nimport Foo.A\n"
  let dupFindings := Imports.duplicateFindings dup "import Foo.A\nimport Foo.A\n"
  ensure (dupFindings.map (·.code) == #["FMT003"])
      "exact duplicate did not fire FMT003 exactly once"
  ensure (dupFindings[0]!.fix?.map (·.applicability) == some .safe)
      "the duplicate-removal fix is not safe"
  -- The safe fix deletes the *later* whole line (the second `import Foo.A`, bytes [13, 26)).
  ensure
      (dupFindings[0]!.fix?.map (·.edits) ==
        some #[{ range := { start := 13, stop := 26 }, replacement := "" }])
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
  ensure
      ((Imports.orderFindings unordered "import Foo.B\nimport Foo.A\n").map (·.code) == #["FMT005"])
      "out-of-order imports in one group did not fire FMT005"
  ensure ((Imports.orderFindings unordered "import Foo.B\nimport Foo.A\n")[0]!.fix?.isNone)
      "FMT005 must be report-only (no fix)"
  let grouped ← parseHeader! "import Foo.B\n\nimport Foo.A\n"
  ensure (Imports.orderFindings grouped "import Foo.B\n\nimport Foo.A\n").isEmpty
      "imports in different blank-line groups were wrongly reported out of order"
  -- FMT005 under `canonical` follows the organizer's order key — modifier bucket, then prefix
  -- sub-block (default groups Lean/Mathlib), then module path — across blank lines, stopping at
  -- comments. The grouped reading stays the default.
  let subblocks ← parseHeader! "import Lake.A\nimport Mathlib.B\n"
  let subblockSource := "import Lake.A\nimport Mathlib.B\n"
  ensure
      ((Imports.orderFindings subblocks subblockSource .canonical).map (·.message) ==
        #["import Mathlib.B is out of order (after Lake.A)"])
      "a sub-block violation did not fire FMT005 under the canonical layout"
  ensure (Imports.orderFindings subblocks subblockSource).isEmpty
      "the canonical sub-block order wrongly fired under the default grouped layout"
  let buckets ← parseHeader! "module\n\nimport Lean.B\n\npublic import Lean.A\n"
  ensure
      ((Imports.orderFindings buckets "module\n\nimport Lean.B\n\npublic import Lean.A\n"
            .canonical).size ==
        1)
      "a bucket descending across a blank line did not fire FMT005 under the canonical layout"
  let metaTail ← parseHeader! "module\n\nimport Lean.B\n\nmeta import Lean.A\n"
  ensure
      (Imports.orderFindings metaTail "module\n\nimport Lean.B\n\nmeta import Lean.A\n"
          .canonical).isEmpty
      "the meta bucket at the end wrongly fired FMT005 under the canonical layout"
  let commentGap ← parseHeader! "import Lake.A\n-- pinned\nimport Lean.B\n"
  ensure
      (Imports.orderFindings commentGap "import Lake.A\n-- pinned\nimport Lean.B\n"
          .canonical).isEmpty
      "a comment-ended region wrongly fired FMT005 under the canonical layout"
  -- FMT004: `Foo.B` is reachable via `Foo.A`'s closure, so the plain `import Foo.B` is a candidate.
  let redundant ← parseHeader! "import Foo.A\nimport Foo.B\n"
  let closure : Lean.Name → Option (Array Lean.Name) := fun name =>
    if name == `Foo.A then some #[`Foo.B] else none
  let (redFindings, redWithheld) := Imports.redundantFindings redundant closure
  ensure (redFindings.map (·.code) == #["FMT004"])
      "a transitively-covered import did not fire FMT004"
  ensure (redFindings[0]!.fix?.isNone) "FMT004 must be report-only (no fix)"
  ensure (redWithheld == 0) "a plain covered import was wrongly withheld"
  -- Withholding: `import all Foo.B` under a `module` marker exposes data reachability cannot reason
  -- about, so it is withheld (counted), never reported.
  let withheld ← parseHeader! "module\nimport Foo.A\nimport all Foo.B\n"
  let (whFindings, whCount) := Imports.redundantFindings withheld closure
  ensure (whFindings.isEmpty)
      "an `import all` redundancy candidate was reported rather than withheld"
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
  ensure
      (Imports.organize (← parseHeader! twoGroups) twoGroups ==
        "import Foo.A\nimport Foo.D\n-- section\nimport Foo.B\nimport Foo.Z\n")
      "the organizer did not sort each comment-delimited group while preserving the comment"
  -- A trailing inline comment forces a boundary: the two imports are not reordered across it.
  let trailing := "import Foo.B -- note\nimport Foo.A\n"
  ensure (Imports.organize (← parseHeader! trailing) trailing == trailing)
      "the organizer reordered across a trailing comment or dropped it"
  -- A modifier rides on the sliced statement bytes through a reorder (`import all` needs `module`).
  let modifier := "module\nimport all Foo.B\nimport Foo.A\n"
  ensure
      (Imports.organize (← parseHeader! modifier) modifier ==
        "module\nimport Foo.A\nimport all Foo.B\n")
      "the organizer dropped a modifier while reordering"
  -- A `prelude` file has no phantom `Init`: the surface model sees only the written imports (`notes` §1a).
  let prelude ← parseHeader! "prelude\nimport Foo.A\n"
  ensure (prelude.hasPrelude && prelude.imports.map (·.module) == #[`Foo.A])
      "the prelude header model does not match the written imports"

/-- The canonical layout (`import-layout = "canonical"`), pinned against the kan-proofs script's
own test suite — bucket order, contiguous sub-blocks, trailing comments, idempotence — plus the
refusal cases the script never faces because it never moves a line across a comment. -/
private def testCanonicalLayout : IO Unit := do
  let canon (source : String) (groups : Array String := Imports.defaultImportGroups) : IO String :=
    do
    let header ← parseHeader! source
    return Imports.organize header source .canonical groups
  -- Sorts alphabetically within a bucket.
  let sortMe := "import Mathlib.B\nimport Mathlib.A\n\nsection\nend section\n"
  ensure ((← canon sortMe) == "import Mathlib.A\nimport Mathlib.B\n\nsection\nend section\n")
      "canonical layout did not sort within a bucket"
  -- Sub-blocks order Lean, Mathlib, then other — contiguous, no blank lines between them
  -- (the script's own suite pins contiguous sub-blocks).
  let subblocks := "import KanProofs.Foo\nimport Mathlib.X\nimport Lean\n\ndef x := 0\n"
  ensure
      ((← canon subblocks) == "import Lean\nimport Mathlib.X\nimport KanProofs.Foo\n\ndef x := 0\n")
      "canonical layout did not order Lean/Mathlib/other sub-blocks contiguously"
  -- Buckets separate with one blank line: `public import`, `import all`, `import`; the `module`
  -- marker and the body are preserved with one blank line on each side of the region.
  let buckets :=
    "module\nimport KanProofs.Z\npublic import KanProofs.A\nimport all KanProofs.M\n\
      import Mathlib.B\npublic import Mathlib.A\n\nnoncomputable section\n"
  ensure
      ((← canon buckets) ==
        "module\n\npublic import Mathlib.A\npublic import KanProofs.A\n\nimport all KanProofs.M\n\n\
        import Mathlib.B\nimport KanProofs.Z\n\nnoncomputable section\n")
      "canonical layout did not separate the modifier buckets"
  -- A `meta` variant sits directly after its non-`meta` counterpart, in its own bucket.
  let metaCase :=
    "module\nmeta import Foo.M\nimport Foo.A\npublic meta import Foo.PM\npublic import Foo.P\n"
  ensure
      ((← canon metaCase) ==
        "module\n\npublic import Foo.P\n\npublic meta import Foo.PM\n\nimport Foo.A\n\n\
        meta import Foo.M\n")
      "canonical layout did not place meta variants after their counterparts"
  -- A trailing `--` comment rides with its import through the sort.
  let commented := "import Mathlib.B -- shake: keep\nimport Mathlib.A\n\ndef x := 0\n"
  ensure
      ((← canon commented) == "import Mathlib.A\nimport Mathlib.B -- shake: keep\n\ndef x := 0\n")
      "canonical layout dropped or misplaced a trailing comment"
  -- Dedup transfers a dropped duplicate's trailing comment to the survivor.
  let dupComment := "import Foo.A\nimport Foo.A -- shake: keep\n\ndef x := 0\n"
  ensure ((← canon dupComment) == "import Foo.A -- shake: keep\n\ndef x := 0\n")
      "canonical layout dropped a duplicate's trailing comment"
  -- A standalone comment line ends the region: the import below it is body and stays put,
  -- and the rewrite is idempotent.
  let region := "import Foo.B\n-- section\nimport Foo.A\ndef x := 0\n"
  let rewritten ← canon region
  ensure (rewritten == "import Foo.B\n\n-- section\nimport Foo.A\ndef x := 0\n")
      "canonical layout moved an import below a standalone comment"
  ensure ((← canon rewritten) == rewritten) "canonical layout was not idempotent"
  -- A block comment trailing an import refuses the whole file (reordering around a possibly
  -- multi-line comment can drop text), and the refusal leaves the bytes unchanged.
  let blockComment := "import Foo.A /- note -/\nimport Foo.B\n\ndef x := 0\n"
  ensure ((Imports.canonicalize (← parseHeader! blockComment) blockComment).isNone)
      "canonical layout did not refuse a trailing block comment"
  ensure ((← canon blockComment) == blockComment) "a refused canonical rewrite changed the file"
  -- A custom `import-groups` list replaces the Lean/Mathlib defaults.
  let custom := "import Foo.B\nimport Std.A\nimport Lean.X\n\ndef x := 0\n"
  ensure ((← canon custom #["Std"]) == "import Std.A\nimport Foo.B\nimport Lean.X\n\ndef x := 0\n")
      "canonical layout ignored a custom import-groups list"
  -- A missing trailing newline stays missing.
  let noNewline := "import Mathlib.B\nimport Mathlib.A\n\ndef y := 0"
  ensure ((← canon noNewline) == "import Mathlib.A\nimport Mathlib.B\n\ndef y := 0")
      "canonical layout changed the file's trailing-newline status"
  -- `organizeCandidate?` agrees: none on an already-canonical header, some on a drifted one,
  -- and the grouped default never rewrites buckets.
  let canonicalText := "module\n\npublic import Mathlib.A\n\nimport Mathlib.B\n\ndef y := 0\n"
  ensure ((← Imports.organizeCandidate? canonicalText .canonical).isNone)
      "organizeCandidate? rewrote an already-canonical header"
  ensure ((← Imports.organizeCandidate? canonicalText).isNone)
      "organizeCandidate? rewrote a grouped-clean header"
  ensure ((← Imports.organizeCandidate? buckets .canonical) == some (← canon buckets))
      "organizeCandidate? disagreed with the organizer under the canonical layout"

/-- The cases this module contributes to the unit runner, in run order. -/
public def cases : Array Case :=
  #[{ name := "testImports", run := testImports },
    { name := "testCanonicalLayout", run := testCanonicalLayout }]

end LeanFmt.Test.Unit.Imports
