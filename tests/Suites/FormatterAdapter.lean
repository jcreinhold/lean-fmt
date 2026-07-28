module

public import Test

/-!
# The formatter-adapter suite

Port of `tests/fixtures/formatter-adapter/run.sh`: actual imported syntax through the production exact
formatter. Descriptor-derived roots are structural syntax islands; explicitly registered roots
enter the live registry. Both are admitted only after structural validation and idempotence.

Lane: parallel — generated fixtures live in the scratch dir and the `FormatterAdapterFixtures`
build in the preamble is Lake-cached.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace FormatterAdapter

structure Ctx where
  root : System.FilePath
  application : String
  work : System.FilePath

private def adapterInput : String :=
  "module\n\nimport AdapterSyntax\n\nopen AdapterSyntax\n\nset_option pp.unicode false\n\n\
   /- adapter block payload -/\n\
   descriptor_command narrow := [twice(1), twice(2), twice(3), twice(4), twice(5), twice(6), \
   twice(7), twice(8)]\n\n\
   explicit_command       selectedName -- adapter trailing payload\n\n\
   def tacticProbe : True := by\n  -- adapter tactic payload\n  adapter_exact True.intro\n\n\
   def optionProbe : Nat → Nat := fun value => value\n\n\
   macro \"adapter_twice\" value:term : term => `($value + $value)\n\n\
   local notation \"adapterUnit\" => (1 : Nat)\n\n\
   def quotationMacroProbe : Nat := adapter_twice adapterUnit\n\n\
   def parserCategoryProbe : Nat := item_term(selectedName)\n"

/-- The wide and narrow runs of the adapter input: every root kind admitted, comments preserved,
the source map tiling the artifact's normalized bytes, and the output width-sensitive. -/
private def testMetrics (ctx : Ctx) : IO Unit := do
  let source := ctx.work / "AdapterInput.lean"
  writeFile source adapterInput
  let setup ← setupFile ctx.root ctx.work source.toString
  let envelope ← analyzeExact ctx.root ctx.application setup source.toString
    "AdapterInput.lean" "4:100"
  let narrowEnvelope ← analyzeExact ctx.root ctx.application setup source.toString
    "AdapterInput.lean" "4:32"
  let (canonical, output) ← Analyze.canonical envelope "adapter"
  let (_, narrowOutput) ← Analyze.canonical narrowEnvelope "adapter narrow"
  ensure (narrowOutput != output) "narrow and wide outputs agree; width sensitivity lost"
  let metric (key : String) : Nat := natAt? canonical [.field "metrics", .field key] |>.getD 0
  ensureEq "adapter: frontendRuns" 1 (metric "frontendRuns")
  ensure (metric "commands" >= 10) s!"adapter: commands {metric "commands"}"
  ensureEq "adapter: nativeDocuments != commands" (metric "commands") (metric "nativeDocuments")
  ensure (metric "alignedTokens" > metric "commands") "adapter: alignedTokens"
  ensure (metric "nativeCommentLeaves" > 0) "adapter: nativeCommentLeaves"
  ensure (metric "registryNodes" > metric "alignedTokens") "adapter: registryNodes"
  ensure (metric "explicitDocuments" > 0) "adapter: explicitDocuments"
  ensure (metric "descriptorDocuments" > 0) "adapter: descriptorDocuments"
  ensureEq "adapter: commentOwners" 3 (metric "commentOwners")
  ensure (metric "nativeEvents" > 0) "adapter: nativeEvents"
  ensureJsonAt canonical [.field "validation", .field "structuralComparisons"]
    (Lean.toJson (1 : Nat)) "adapter"
  ensureJsonAt canonical [.field "validation", .field "idempotencePasses"]
    (Lean.toJson (1 : Nat)) "adapter"
  ensureContains output "explicit_command selectedName" "adapter: explicit root lost"
  ensure (!(output.contains "explicit_command       selectedName"))
    "adapter: alignment whitespace survived"
  ensureContains output "twice(" "adapter: descriptor root lost"
  ensureContains output "adapter_exact" "adapter: tactic root lost"
  ensureContains output "Nat → Nat" "adapter: unicode option not honored"
  ensureContains output "macro \"adapter_twice\"" "adapter: macro lost"
  ensureContains output "`(" "adapter: quotation lost"
  ensureContains output "local notation \"adapterUnit\"" "adapter: local notation lost"
  ensureContains output "item_term(selectedName)" "adapter: parser category lost"
  for payload in ["adapter block payload", "adapter trailing payload", "adapter tactic payload"] do
    ensureEq s!"adapter: {payload} count" 1 ((output.splitOn payload).length - 1)
  let some marks := (jsonAt? canonical [.field "sourceMap"]).bind (·.getArr?.toOption)
    | throw <| IO.userError "adapter: no sourceMap"
  let mut sourceCursor := 0
  let mut outputCursor := 0
  for mark in marks do
    ensureJsonAt mark [.field "source", .field "start"] (Lean.toJson sourceCursor) "adapter map"
    ensureJsonAt mark [.field "output", .field "start"] (Lean.toJson outputCursor) "adapter map"
    sourceCursor := natAt? mark [.field "source", .field "stop"] |>.getD 0
    outputCursor := natAt? mark [.field "output", .field "stop"] |>.getD 0
  ensureEq "adapter: source map does not reach the artifact's normalized bytes"
    (natAt? envelope [.field "artifact", .field "normalizedBytes"] |>.getD 0) sourceCursor
  ensureEq "adapter: source map does not tile the output" output.utf8ByteSize outputCursor

/-- A formatter exception surfaces a typed hard failure with kind, category, range, and trace. -/
private def testThrowing (ctx : Ctx) : IO Unit := do
  let source := ctx.work / "Throwing.lean"
  writeFile source "module\n\nimport AdapterSyntax\n\nopen AdapterSyntax\n\nthrowing_command\n"
  let setup ← setupFile ctx.root ctx.work source.toString
  let envelope ← analyzeExact ctx.root ctx.application setup source.toString
    "Throwing.lean" "4:100"
  ensure ((jsonAt? envelope [.field "canonical"]).isNone) "throwing: canonical escaped"
  let failure := (jsonAt? envelope [.field "formatFailure"]).getD .null
  let kind := ((jsonAt? failure [.field "trace", .field "kind"]).bind (·.getStr?.toOption)).getD ""
  ensureContains kind "throwingCommand" "throwing: kind"
  -- The old Python's `in` over `trace.resolution` was dict-key membership, not a substring.
  ensure ((jsonAt? failure [.field "trace", .field "resolution", .field "explicit"]).isSome)
    "throwing: resolution lost the explicit category"
  let detail := ((failure.getObjValAs? String "detail").toOption).getD ""
  ensureContains detail "adapter fixture formatter failure" "throwing: detail"
  let start := natAt? failure [.field "range", .field "start"] |>.getD 0
  let stop := natAt? failure [.field "range", .field "stop"] |>.getD 0
  ensure (stop > start) "throwing: empty range"

/-- An unsafe extension token's normalization is replaced by the original payload. -/
private def testInvalid (ctx : Ctx) : IO Unit := do
  let source := ctx.work / "Invalid.lean"
  writeFile source "module\n\nimport AdapterSyntax\n\nopen AdapterSyntax\n\ninvalid_command\n"
  let setup ← setupFile ctx.root ctx.work source.toString
  let envelope ← analyzeExact ctx.root ctx.application setup source.toString "Invalid.lean" "4:100"
  let (_, output) ← Analyze.canonical envelope "invalid"
  ensureContains output "invalid_command" "invalid: payload lost"
  ensure (!(output.contains "\ndef\n")) "invalid: normalization leaked"
  ensureJsonAt envelope [.field "canonical", .field "metrics", .field "normalizedTokens"]
    (Lean.toJson (1 : Nat)) "invalid"

/-- A formatter-only token insertion is a typed alignment refusal. -/
private def testExtraToken (ctx : Ctx) : IO Unit := do
  let source := ctx.work / "ExtraToken.lean"
  writeFile source "module\n\nimport AdapterSyntax\n\nopen AdapterSyntax\n\nextra_token_command\n"
  let setup ← setupFile ctx.root ctx.work source.toString
  let envelope ← analyzeExact ctx.root ctx.application setup source.toString
    "ExtraToken.lean" "4:100"
  ensure ((jsonAt? envelope [.field "canonical"]).isNone) "extra token: canonical escaped"
  let failure := (jsonAt? envelope [.field "formatFailure"]).getD .null
  let detail := ((failure.getObjValAs? String "detail").toOption).getD ""
  ensureContains detail "extra text leaf" "extra token: detail"
  let kind := ((jsonAt? failure [.field "trace", .field "kind"]).bind (·.getStr?.toOption)).getD ""
  ensure (kind.endsWith "extraTokenCommand") s!"extra token: kind {kind}"

end FormatterAdapter

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  discard <| expectExit 0 "lake build FormatterAdapterFixtures" "lake"
    #["build", "FormatterAdapterFixtures"] (cwd? := some root)
  withScratchDir "formatter-adapter" fun work => do
    let ctx : FormatterAdapter.Ctx :=
      { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, work }
    let cases : Array Case := #[
      { name := "adapter-metrics", run := FormatterAdapter.testMetrics ctx },
      { name := "throwing", run := FormatterAdapter.testThrowing ctx },
      { name := "invalid", run := FormatterAdapter.testInvalid ctx },
      { name := "extra-token", run := FormatterAdapter.testExtraToken ctx }
    ]
    runCases "formatter-adapter" cases args
