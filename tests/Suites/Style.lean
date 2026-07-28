module

public import Test

/-!
# The style suite

Port of `tests/fixtures/style/run.sh`. A specification gate: the intended rows of `docs/style.md` are
structurally validated, the frozen intended candidate passes the independent oracle with full structure
preserved, a currently safe style fixed point passes production admission at four widths, and a
multiline literal survives structural declaration layout byte-for-byte.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace Style

/-- The matrix rows cover every family and decision axis, every row is fully spelled, and the doc
mentions every row plus the suppression and width vocabulary. -/
private def testMatrixCoverage (root : System.FilePath) : IO Unit := do
  let doc ← IO.FS.readFile (root / "docs" / "style.md")
  let rowsJson ← parseJson (← IO.FS.readFile (root / "tests" / "fixtures" / "style" / "matrix.json"))
    "style matrix"
  let some rows := rowsJson.getArr?.toOption
    | throw <| IO.userError "style matrix is not an array"
  ensure (rows.size == 19) s!"style matrix has {rows.size} rows, expected 19"
  let mut ids : Array String := #[]
  let mut families : Array String := #[]
  let mut owners : Array String := #[]
  for row in rows do
    let id := (row.getObjValAs? String "id").toOption.getD ""
    ids := ids.push id
    families := families.push ((row.getObjValAs? String "family").toOption.getD "")
    owners := owners.push ((row.getObjValAs? String "owner").toOption.getD "")
    for key in ["flat", "broken", "comment"] do
      let value := (row.getObjValAs? String key).toOption.getD ""
      ensure (!value.trimAscii.isEmpty) s!"style row {id} has an empty {key}"
    ensureContains doc s!"`{id}`" s!"style row {id} missing from docs/style.md"
  ensure (ids.toList.eraseDups.length == ids.toList.length) "style row ids are not unique"
  let required := ["header", "command", "declaration", "term", "collection", "block", "trivia",
    "registry"]
  ensure (required.all fun family => families.contains family &&
      (families.toList.eraseDups.length == required.length))
    s!"style matrix families changed: {families.toList.eraseDups}"
  for owner in ["11", "11b", "12", "12b", "13", "14"] do
    ensure (owners.contains owner) s!"style matrix lost owner {owner}"
  for needle in ["format-ignore-next", "two spaces", "line width"] do
    ensureContains doc needle "docs/style.md"

/-- The frozen intended candidate: admitted by the oracle, changed exactly one file's bytes, and
preserved full structure (no comments in the fixture, so none may appear). -/
private def testIntendedCandidate (root : System.FilePath) (application : String)
    (work : System.FilePath) : IO Unit := do
  let setup ← setupFile root work "tests/fixtures/style/fixtures/PolicyInput.lean"
  let outcome ← Oracle.run root application setup work
    (root / "tests" / "fixtures" / "style" / "fixtures" / "PolicyInput.lean")
    #["python3", "tests/fixtures/style/expected_candidate.py", "tests/fixtures/style/fixtures/Policy.lean"]
  match outcome with
  | .error failure =>
    throw <| IO.userError s!"intended candidate rejected at gate {failure.gate}: {failure.detail}"
  | .ok summary =>
    ensureJsonAt summary [.field "changed"] (Lean.toJson (1 : Nat)) "intended candidate"
    let nodes := (Analyze.natAt? summary [.field "nodes"]).getD 0
    let tokens := (Analyze.natAt? summary [.field "tokens"]).getD 0
    ensure (nodes > 100) s!"intended candidate lost structure: {nodes} nodes"
    ensure (tokens > 50) s!"intended candidate lost tokens: {tokens}"
    ensureJsonAt summary [.field "comments"] (Lean.toJson (0 : Nat)) "intended candidate"

/-- A currently safe style fixed point passes production admission at 20/40/80/100: canonical
render, no validation failure, exactly two renders. -/
private def testNativeSafeWidth (root : System.FilePath) (application : String)
    (work : System.FilePath) (width : Nat) : IO Unit := do
  let setup ← setupFile root work "tests/fixtures/style/fixtures/NativeSafe.lean"
  let report ← analyzeExact root application setup
    "tests/fixtures/style/fixtures/NativeSafe.lean" "NativeSafe.lean" s!"4:{width}"
  let (canonical, _) ← canonical report s!"native-safe width {width}"
  ensureJsonAt canonical [.field "validation", .field "renders"] (Lean.toJson (2 : Nat))
    s!"native-safe width {width}"

/-- Structural declaration layout preserves a multiline literal byte-for-byte. -/
private def testUnsafeLiteral (root : System.FilePath) (application : String)
    (work : System.FilePath) : IO Unit := do
  let setup ← setupFile root work "tests/fixtures/style/fixtures/UnsafeLiteral.lean"
  let report ← analyzeExact root application setup
    "tests/fixtures/style/fixtures/UnsafeLiteral.lean" "UnsafeLiteral.lean" "4:100"
  let (_, text) ← canonical report "unsafe-literal"
  ensureContains text "\"alpha   \n  beta\"" "unsafe-literal"

end Style

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
  withScratchDir "style" fun work => do
    let cases : Array Case := #[
      { name := "matrix-coverage", run := Style.testMatrixCoverage root },
      { name := "intended-candidate", run := Style.testIntendedCandidate root application work },
      { name := "native-safe-20", run := Style.testNativeSafeWidth root application work 20 },
      { name := "native-safe-40", run := Style.testNativeSafeWidth root application work 40 },
      { name := "native-safe-80", run := Style.testNativeSafeWidth root application work 80 },
      { name := "native-safe-100", run := Style.testNativeSafeWidth root application work 100 },
      { name := "unsafe-literal", run := Style.testUnsafeLiteral root application work }
    ]
    runCases "style" cases args
