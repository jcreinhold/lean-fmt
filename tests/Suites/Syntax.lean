module

public import Test

/-!
# The syntax suite

Port of `tests/fixtures/syntax/run.sh`. The first `syntax`-tier rules (FMT006-FMT011) run against the
compiler projection, not the raw bytes. These fixtures are deliberately *not* built modules: there
is no `.olean`, no module evidence, and no artifact for them, so the exact frontend is the only
path that can project them — `LEAN_FMT_DISABLE_ARTIFACT=1` and
`LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1` make that explicit rather than dependent on whatever the
build tree happens to hold. `--no-cache` keeps each run independent of the last.

Lane: workspace — the preamble clears the root `.lean-fmt-cache`.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace SyntaxSuite

structure Ctx where
  root : System.FilePath
  application : String
  work : System.FilePath

private def sfmtEnv : Array (String × Option String) :=
  #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"), ("LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE", some "1")]

/-- The six syntax-tier rules named explicitly: five are preview and FMT011 is `stable` with
default off, so `--preview` is not what makes the set reachable; naming each code is.
One selector per flag, so a negative fixture is measured against every rule at once. -/
private def allSix : Array String :=
  #["--select", "FMT006", "--select", "FMT007", "--select", "FMT008", "--select", "FMT009",
    "--select", "FMT010", "--select", "FMT011"]

/-- Assert the exact ordered list of finding codes a single-file `check` reports, and that nothing
failed infrastructurally. -/
private def expectCodes (ctx : Ctx) (label fixture : String) (expected : List String)
    (selectors : Array String) : IO Unit := do
  let result ←
    expectExit (if expected.isEmpty then 0 else 1) label ctx.application
        (#["check", "--root", ".", "--json", "--no-cache", "--preview"] ++ selectors ++
          #[s!"tests/fixtures/syntax/{fixture}"])
        (cwd? := some ctx.root) (env := sfmtEnv)
  let report ← parseJson result.stdout label
  let some files :=
    (jsonAt? report [.field "files"]).bind
      (·.getArr?.toOption) | throw <| IO.userError s!"{label}: report has no files"
  ensure (files.size == 1) s!"{label}: report selected {files.size} files"
  let codes :=
    (((jsonAt? files[0]! [.field "findings"]).bind (·.getArr?.toOption)).getD #[]).map
      fun finding => (finding.getObjValAs? String "code").toOption.getD ""
  ensureEq s!"{label}: finding codes changed" expected codes.toList
  let failures := (jsonAt? report [.field "infrastructureFailures"]).bind (·.getArr?.toOption)
  ensure ((failures.map (·.size)) == some 0) s!"{label}: infrastructure failures"
  ensureJsonAt report [.field "broken"] (Lean.toJson (0 : Nat)) label

/-- Each defect fires exactly its own rule, including the `… in`-scoped `set_option` (the same
command node, so a committed dev option fires either way — report-only, so the scoped boundary
raises no byte-safety question). -/
private def testPositives (ctx : Ctx) : IO Unit := do
  expectCodes ctx "fmt008-pos" "NoModuleDoc.lean" ["FMT006"] #["--select", "FMT006"]
  expectCodes ctx "fmt009-pos" "Unclosed.lean" ["FMT007"] #["--select", "FMT007"]
  expectCodes ctx "fmt010-pos" "Duplicates.lean" ["FMT008"] #["--select", "FMT008"]
  expectCodes ctx "fmt011-pos" "Duplicates.lean" ["FMT009"] #["--select", "FMT009"]
  expectCodes ctx "fmt012-pos" "DevOption.lean" ["FMT010"] #["--select", "FMT010"]
  expectCodes ctx "fmt012-scoped-in" "ScopedInOption.lean" ["FMT010"] #["--select", "FMT010"]
  expectCodes ctx "fmt013-pos" "NestedParen.lean" ["FMT011"] #["--select", "FMT011"]

/-- The three fixable rules carry a `.safe` fix whose edits are expressed in original-source
coordinates (the frontend-native canonical layout contract). Pin the applicability and the exact
byte spans: FMT008/009 drop the duplicate instance and its `", "` separator; FMT011 deletes just
the outer parenthesis pair and leaves the inner `(1)`. -/
private def testFixSpans (ctx : Ctx) : IO Unit := do
  let fixOf (label fixture selector : String) : IO Lean.Json := do
    let result ←
      expectExit 1 label ctx.application
          #["check", "--root", ".", "--json", "--no-cache", "--preview", "--select", selector,
            s!"tests/fixtures/syntax/{fixture}"]
          (cwd? := some ctx.root) (env := sfmtEnv)
    let report ← parseJson result.stdout label
    let some finding :=
      (jsonAt? report
        [.field "files", .index 0, .field "findings",
          .index 0]) | throw <| IO.userError s!"{label}: no finding"
    let some fix := jsonAt? finding [.field "fix"] | throw <| IO.userError s!"{label}: no fix"
    return fix
  let pinEdits (fix : Lean.Json) (expected : List (Nat × Nat × String)) (label : String) :
    IO Unit := do
    ensure (((fix.getObjValAs? String "applicability").toOption) == some "safe")
        s!"{label}: fix is not safe"
    let some edits :=
      (jsonAt? fix [.field "edits"]).bind
        (·.getArr?.toOption) | throw <| IO.userError s!"{label}: fix has no edits"
    let got :=
      edits.toList.map fun edit =>
        ((natAt? edit [.field "range", .field "start"]).getD 0,
          (natAt? edit [.field "range", .field "stop"]).getD 0,
          ((jsonAt? edit [.field "replacement"]).bind (·.getStr?.toOption)).getD "<?>")
    ensureEq s!"{label}: edit spans changed" expected got
  pinEdits (← fixOf "fmt010-pos" "Duplicates.lean" "FMT008") [(42, 48, "")] "fmt010-pos"
  pinEdits (← fixOf "fmt011-pos" "Duplicates.lean" "FMT009") [(110, 116, "")] "fmt011-pos"
  pinEdits (← fixOf "fmt013-pos" "NestedParen.lean" "FMT011") [(51, 52, ""), (55, 56, "")]
      "fmt013-pos"

/-- A clean file trips none of the six, and each rule's documented exclusion (catalog 01 §5) stays
silent under all six: no-declaration modules, whole-file `noncomputable section`, dotted and nested
scope closes, `attrKind`-distinct attributes, distinct deriving classes, proof-scaling options,
tuple/ascription/cdot parens, comment-buried defects, quotation data, and custom `(`-reusing
syntax. -/
private def testNegatives (ctx : Ctx) : IO Unit := do
  for (label, fixture) in
    [("clean", "Clean.lean"), ("near-008", "NearNoDecl.lean"), ("near-009", "NearOpenSection.lean"),
      ("near-009-dotted", "EndDotted.lean"), ("near-009-nested", "ScopesBalanced.lean"),
      ("near-010", "NearAttr.lean"), ("near-011", "NearDeriving.lean"),
      ("near-012", "NearOption.lean"), ("near-013", "NearParen.lean"), ("comment", "Comment.lean"),
      ("quote-paren", "QuoteParen.lean"), ("quote-attr", "QuoteAttr.lean"),
      ("custom-syntax", "CustomSyntax.lean")]do
    expectCodes ctx label fixture [] allSix

/-- An unparseable file is `broken`, reported without a crash and without a false finding: a
syntax rule needs a projection, and a file that does not parse has none. -/
private def testMalformed (ctx : Ctx) : IO Unit := do
  let result ←
    expectExit 1 "malformed" ctx.application
        (#["check", "--root", ".", "--json", "--no-cache", "--preview"] ++ allSix ++
          #["tests/fixtures/syntax/Malformed.lean"])
        (cwd? := some ctx.root) (env := sfmtEnv)
  let report ← parseJson result.stdout "malformed"
  ensureJsonAt report [.field "broken"] (Lean.toJson (1 : Nat)) "malformed"
  ensureJsonAt report [.field "findings"] (Lean.toJson (0 : Nat)) "malformed"
  let failures := (jsonAt? report [.field "infrastructureFailures"]).bind (·.getArr?.toOption)
  ensure ((failures.map (·.size)) == some 0) "malformed: infrastructure failures"
  ensure
      (((jsonAt? report [.field "files", .index 0, .field "status"]).bind (·.getStr?.toOption)) ==
        some "broken")
      "malformed: file status changed"

/-- A syntax-tier `.safe` fix is *applied* by `fix`: the edits land in original-source coordinates
and carry no reflow. Assert `fix` writes the corrected bytes and that a re-`check` reports nothing
for that rule — the fix is idempotent. -/
private def fixApplies (ctx : Ctx) (label fixture selector gone present : String) : IO Unit := do
  let probe := ctx.work / s!"fix-{label}.lean"
  copyFile (ctx.root / "tests" / "fixtures" / "syntax" / fixture) probe
  let fixRun ←
    expectExit 0 s!"{label}-fix" ctx.application
        #["check", "--fix", "--root", ".", "--json", "--no-cache", "--preview", "--select",
          selector, probe.toString]
        (cwd? := some ctx.root) (env := sfmtEnv)
  let report ← parseJson fixRun.stdout s!"{label}-fix"
  ensureJsonAt report [.field "written"] (Lean.toJson (1 : Nat)) s!"{label}-fix"
  ensureJsonAt report [.field "changed"] (Lean.toJson (1 : Nat)) s!"{label}-fix"
  ensure
      (((jsonAt? report [.field "files", .index 0, .field "status"]).bind (·.getStr?.toOption)) ==
        some "fixed")
      s!"{label}-fix: file status changed"
  ensureJsonAt report [.field "files", .index 0, .field "written"] (Lean.toJson true)
      s!"{label}-fix"
  let got ← IO.FS.readFile probe
  ensure (!(got.contains gone)) s!"{label}: defect still present after fix"
  ensureContains got present s!"{label}: fixed form absent"
  let recheck ←
    expectExit 0 s!"{label}-recheck" ctx.application
        #["check", "--root", ".", "--json", "--no-cache", "--preview", "--select", selector,
          probe.toString]
        (cwd? := some ctx.root) (env := sfmtEnv)
  let rechecked ← parseJson recheck.stdout s!"{label}-recheck"
  ensureJsonAt rechecked [.field "findings"] (Lean.toJson (0 : Nat)) s!"{label}: not idempotent"

/-- The three fixable rules, each applied and idempotent. -/
private def testFixApplication (ctx : Ctx) : IO Unit := do
  fixApplies ctx "fmt013" "NestedParen.lean" "FMT011" "((1))" "(1)"
  fixApplies ctx "fmt010" "Duplicates.lean" "FMT008" "@[simp, simp]" "@[simp]"
  fixApplies ctx "fmt011" "Duplicates.lean" "FMT009" "deriving Repr, Repr" "deriving Repr"

/-- The inverse half of the split: `format` applies no syntax fix. On the same FMT011 fixture it
reports the finding and may canonicalize command spacing, but leaves `((1))` byte-for-byte, where
`fix` rewrote it to `(1)`. -/
private def testFormatNeverFixes (ctx : Ctx) : IO Unit := do
  let result ←
    expectExit 1 "fmt013-format" ctx.application
        #["format", "--check", "--root", ".", "--json", "--no-cache", "--preview", "--select",
          "FMT011", "tests/fixtures/syntax/NestedParen.lean"]
        (cwd? := some ctx.root) (env := sfmtEnv)
  let report ← parseJson result.stdout "fmt013-format"
  let some file :=
    jsonAt? report [.field "files", .index 0] | throw <| IO.userError "fmt013-format: no file"
  let codes :=
    (((jsonAt? file [.field "findings"]).bind (·.getArr?.toOption)).getD #[]).map fun finding =>
      (finding.getObjValAs? String "code").toOption.getD ""
  ensure (codes.contains "FMT011") "format dropped the report"
  match (file.getObjValAs? String "formatted").toOption with
  | some out =>
    ensureContains out "((1))" "format applied the syntax fix -- it must not"
  | none =>
    pure ()

/-- The adversarial compositions: a fix range abutting a multibyte glyph (every
compiler-produced offset indexes the normalized bytes), and two nested defects whose point
deletions compose in one transaction. -/
private def testAdversarial (ctx : Ctx) : IO Unit := do
  fixApplies ctx "fmt013-utf8" "NestedParenUtf8.lean" "FMT011" "((" "(ϕ)"
  fixApplies ctx "fmt013-triple" "NestedParenTriple.lean" "FMT011" "((" "(1)"

/-- Multi-rule composition: FMT008's and FMT011's deletions live in one coordinate system and one
atomic transaction, so neither shifts the other's bytes; and a second `fix` is a no-op. -/
private def testMultiRuleComposition (ctx : Ctx) : IO Unit := do
  let probe := ctx.work / "fix-mover.lean"
  copyFile (ctx.root / "tests" / "fixtures" / "syntax" / "AttrThenParen.lean") probe
  let selectors := #["--select", "FMT008", "--select", "FMT011"]
  let fixRun ←
    expectExit 0 "mover-fix" ctx.application
        (#["check", "--fix", "--root", ".", "--json", "--no-cache", "--preview"] ++ selectors ++
          #[probe.toString])
        (cwd? := some ctx.root) (env := sfmtEnv)
  let report ← parseJson fixRun.stdout "mover-fix"
  ensureJsonAt report [.field "written"] (Lean.toJson (1 : Nat)) "mover-fix"
  ensureJsonAt report [.field "changed"] (Lean.toJson (1 : Nat)) "mover-fix"
  let got ← IO.FS.readFile probe
  ensure (!(got.contains "((") && !(got.contains ", simp")) "mover not fully composed"
  ensureContains got "(1)" "mover"
  ensureContains got "@[simp]" "mover"
  let refix ←
    expectExit 0 "mover-refix" ctx.application
        (#["check", "--fix", "--root", ".", "--json", "--no-cache", "--preview"] ++ selectors ++
          #[probe.toString])
        (cwd? := some ctx.root) (env := sfmtEnv)
  let refixed ← parseJson refix.stdout "mover-refix"
  ensureJsonAt refixed [.field "written"] (Lean.toJson (0 : Nat)) "second fix was not a no-op"
  ensureJsonAt refixed [.field "changed"] (Lean.toJson (0 : Nat)) "second fix was not a no-op"
  ensure
      (((jsonAt? refixed [.field "files", .index 0, .field "status"]).bind (·.getStr?.toOption)) ==
        some "clean")
      "mover-refix: file status changed"

/-- Pass-order independence: the same two rules selected in either order write byte-identical
results. -/
private def testPassOrderIndependence (ctx : Ctx) : IO Unit := do
  let probeA := ctx.work / "fix-ordera.lean"
  let probeB := ctx.work / "fix-orderb.lean"
  copyFile (ctx.root / "tests" / "fixtures" / "syntax" / "AttrThenParen.lean") probeA
  copyFile (ctx.root / "tests" / "fixtures" / "syntax" / "AttrThenParen.lean") probeB
  discard <|
      expectExit 0 "order-a" ctx.application
        #["check", "--fix", "--root", ".", "--json", "--no-cache", "--preview", "--select",
          "FMT008", "--select", "FMT011", probeA.toString]
        (cwd? := some ctx.root) (env := sfmtEnv)
  discard <|
      expectExit 0 "order-b" ctx.application
        #["check", "--fix", "--root", ".", "--json", "--no-cache", "--preview", "--select",
          "FMT011", "--select", "FMT008", probeB.toString]
        (cwd? := some ctx.root) (env := sfmtEnv)
  ensureEq "pass-order changed the composed bytes" (← IO.FS.readFile probeB)
      (← IO.FS.readFile probeA)

end SyntaxSuite

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  removeDirAll? (root / ".lean-fmt-cache")
  withScratchDir "syntax" fun work => do
      let ctx : SyntaxSuite.Ctx :=
        { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, work }
      let cases : Array Case :=
        #[{ name := "positives", run := SyntaxSuite.testPositives ctx },
          { name := "fix-spans", run := SyntaxSuite.testFixSpans ctx },
          { name := "negatives", run := SyntaxSuite.testNegatives ctx },
          { name := "malformed", run := SyntaxSuite.testMalformed ctx },
          { name := "fix-application", run := SyntaxSuite.testFixApplication ctx },
          { name := "format-never-fixes", run := SyntaxSuite.testFormatNeverFixes ctx },
          { name := "adversarial", run := SyntaxSuite.testAdversarial ctx },
          { name := "multi-rule-composition", run := SyntaxSuite.testMultiRuleComposition ctx },
          { name := "pass-order-independence", run := SyntaxSuite.testPassOrderIndependence ctx }]
      runCases "syntax" cases args
