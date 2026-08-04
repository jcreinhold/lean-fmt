module

public import Test

import all LeanFmt.Formatter
import all LeanFmt.Validator

/-!
# The validator suite

Port of `tests/validator/run.sh`. Production admission: a candidate is canonical only after a fresh
parse, structural comparison, logical-comment comparison, complete source maps, and a byte-identical
second rendering. The mutated candidates come from `tests/fixtures/formatter/candidate.py`, the deliberately
foreign adversary — it stays Python and the suite pipes through it, so the validator is still
exercised by output nobody in this repo controls.

`reparse-agrees` pins the one thing the fast path could break: the reparsed and elaborated routes
must produce the same bytes. A failure there means reparsing the candidate under the original run's
parser contexts admitted a different layout, and the fast path must come out.

Also absorbs the unit exe's `validator-map-negative` subcommand (this suite was its only
consumer): the six defect maps, plus the complete map that must be admitted.

Lane: parallel — everything runs in a scratch dir; the `FormatterAdapterFixtures` library build in
the preamble is Lake-cached.
-/

open LeanFmt LeanFmt.Internal
open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace ValidatorSuite

structure Ctx where
  root : System.FilePath
  application : String
  work : System.FilePath

/-- `candidate.py <mode>` on stdin, returning the `formatted` field of its JSON reply. -/
private def candidate (ctx : Ctx) (mode source : String) : IO String := do
  let label := s!"candidate.py {mode}"
  let result ←
    expectExit 0 label "python3"
        #[(ctx.root / "tests" / "fixtures" / "formatter" / "candidate.py").toString, mode]
        (input? := some source) (cwd? := some ctx.root)
  let json ← parseJson result.stdout label
  let some formatted :=
    (json.getObjValAs? String
        "formatted").toOption | throw <| IO.userError s!"{label}: no `formatted` field"
  return formatted

/-- `__validate-candidate` against the setup file for `source`, returning the parsed result. -/
private def validateCandidate (ctx : Ctx) (setup source candidatePath : System.FilePath)
    (label : String) : IO Lean.Json := do
  let result ←
    expectExit 0 label ctx.application
        #["__validate-candidate", setup.toString, source.toString, candidatePath.toString,
          "source.lean", "100"]
        (cwd? := some ctx.root)
  parseJson result.stdout label

/-- One rejected mutation: canonical absent, `failure.gate` exactly the expected one. -/
private def testGate (ctx : Ctx) (fixture mode expected : String) : IO Unit := do
  let label := s!"{mode} rejected by {expected}"
  let source := ctx.work / s!"{mode}-source.lean"
  copyFile (ctx.root / "tests" / "fixtures" / "formatter" / "fixtures" / fixture) source
  let setup ← setupFile ctx.root ctx.work source.toString
  let mutated ← candidate ctx mode (← IO.FS.readFile source)
  let candidatePath := ctx.work / s!"{mode}-candidate.lean"
  writeFile candidatePath mutated
  let result ← validateCandidate ctx setup source candidatePath label
  ensure ((jsonAt? result [.field "canonical"]).isNone) s!"{label}: canonical escaped"
  ensureJsonAt result [.field "failure", .field "gate"] (Lean.toJson expected) label

/-- The admission proof: the custom-command candidate is canonical after one frontend and two
renders, the validation ledger is exact, the source map tiles the output, and both logical comments
survive exactly once.

`frontendRuns` is 1 because the candidate is reparsed under the original run's own parser contexts;
`reparsedCommands` counts what that confirmed, and this fixture has two commands after its header. -/
private def testAdmission (ctx : Ctx) : IO Unit := do
  let label := "admission"
  let source := ctx.work / "Accepted.lean"
  writeFile source
      "module\n\nimport AdapterSyntax\n\nopen AdapterSyntax\n\n-- custom lead\n\
     explicit_command selectedName -- custom trail\n"
  let setup ← setupFile ctx.root ctx.work source.toString
  let envelope ← analyzeExact ctx.root ctx.application setup source.toString "Accepted.lean" "4:80"
  ensure (((jsonAt? envelope [.field "diagnostics"]).bind (·.getArr?.toOption)).getD #[]).isEmpty
      s!"{label}: unexpected diagnostics"
  ensure ((jsonAt? envelope [.field "validationFailure"]).isNone)
      s!"{label}: validationFailure present"
  ensure ((jsonAt? envelope [.field "formatDraft"]).isNone)
      s!"{label}: unvalidated draft escaped validated operation"
  let some canonicalJson :=
    jsonAt? envelope [.field "canonical"] | throw <| IO.userError s!"{label}: no canonical"
  ensureJsonAt canonicalJson [.field "metrics", .field "frontendRuns"] (Lean.toJson (1 : Nat)) label
  let expectedValidation :=
    Lean.Json.mkObj
      [("frontendRuns", Lean.toJson (1 : Nat)), ("renders", Lean.toJson (2 : Nat)),
        ("structuralComparisons", Lean.toJson (1 : Nat)),
        ("idempotencePasses", Lean.toJson (1 : Nat)), ("reparsedCommands", Lean.toJson (2 : Nat))]
  ensureJsonAt canonicalJson [.field "validation"] expectedValidation label
  let some text :=
    (canonicalJson.getObjValAs? String
        "text").toOption | throw <| IO.userError s!"{label}: canonical has no text"
  let some marks :=
    (jsonAt? canonicalJson [.field "sourceMap"]).bind
      (·.getArr?.toOption) | throw <| IO.userError s!"{label}: canonical has no sourceMap"
  let mut sourcePos := 0
  let mut outputPos := 0
  for mark in marks do
    ensureJsonAt mark [.field "source", .field "start"] (Lean.toJson sourcePos) label
    ensureJsonAt mark [.field "output", .field "start"] (Lean.toJson outputPos) label
    sourcePos := natAt? mark [.field "source", .field "stop"] |>.getD 0
    outputPos := natAt? mark [.field "output", .field "stop"] |>.getD 0
  ensureEq s!"{label}: source map does not tile the output" text.utf8ByteSize outputPos
  ensureEq s!"{label}: custom lead count" 1 ((text.splitOn "custom lead").length - 1)
  ensureEq s!"{label}: custom trail count" 1 ((text.splitOn "custom trail").length - 1)

/-- The fast path did not change the answer. One source admitted twice: once with the candidate
reparsed under the original run's parser contexts, once with `LEAN_FMT_DISABLE_CANDIDATE_REPARSE=1`
forcing the second frontend. Text and source map must be byte-identical.

The ledgers must *differ*, and that half is the load-bearing one: comparing outputs alone would pass
just as well if the hook did nothing and both runs elaborated. -/
private def testReparseAgrees (ctx : Ctx) : IO Unit := do
  let label := "reparse agrees"
  let source := ctx.work / "Agreed.lean"
  writeFile source
      "module\n\nimport AdapterSyntax\n\nopen AdapterSyntax\n\n-- custom lead\n\
     explicit_command selectedName -- custom trail\n"
  let setup ← setupFile ctx.root ctx.work source.toString
  let admit (env : Array (String × Option String)) (what : String) : IO (Lean.Json × Nat) := do
    let envelope ←
      analyzeExact ctx.root ctx.application setup source.toString "Agreed.lean" "4:80" (env := env)
    let some canonical :=
      jsonAt? envelope
        [.field "canonical"] | throw <| IO.userError s!"{label}: {what} produced no canonical"
    let some runs :=
      natAt? canonical
        [.field "validation",
          .field
            "frontendRuns"] | throw <| IO.userError s!"{label}: {what} reported no frontendRuns"
    return (canonical, runs)
  let (reparsed, reparsedRuns) ← admit #[] "the reparsed run"
  let (elaborated, elaboratedRuns) ←
    admit #[("LEAN_FMT_DISABLE_CANDIDATE_REPARSE", some "1")] "the elaborated run"
  ensureEq s!"{label}: reparsed frontendRuns" 1 reparsedRuns
  ensureEq s!"{label}: elaborated frontendRuns" 2 elaboratedRuns
  let some elaboratedText :=
    jsonAt? elaborated
      [.field "text"] | throw <| IO.userError s!"{label}: the elaborated run has no text"
  let some elaboratedMap :=
    jsonAt? elaborated
      [.field "sourceMap"] | throw <| IO.userError s!"{label}: the elaborated run has no sourceMap"
  ensureJsonAt reparsed [.field "text"] elaboratedText label
  ensureJsonAt reparsed [.field "sourceMap"] elaboratedMap label

/-- A candidate that does not parse is rejected by the diagnostics gate, before any structural
comparison runs. -/
private def testMalformed (ctx : Ctx) : IO Unit := do
  let label := "malformed candidate"
  let source := ctx.work / "malformed-source.lean"
  copyFile (ctx.root / "tests" / "fixtures" / "formatter" / "fixtures" / "Contract.lean") source
  let setup ← setupFile ctx.root ctx.work source.toString
  let candidatePath := ctx.work / "malformed-candidate.lean"
  writeFile candidatePath "module\n\ndef broken :=\n"
  let result ← validateCandidate ctx setup source candidatePath label
  ensureJsonAt result [.field "failure", .field "gate"] (Lean.toJson "diagnostics") label

/-- A formatter exception stays a typed refusal: the adapter fixture's `throwing_command` raises,
and the envelope carries `formatFailure.detail`, not a crash and not a canonical. -/
private def testThrowing (ctx : Ctx) : IO Unit := do
  let label := "throwing fixture"
  let source := ctx.work / "Throwing.lean"
  writeFile source "module\n\nimport AdapterSyntax\n\nopen AdapterSyntax\n\nthrowing_command\n"
  let setup ← setupFile ctx.root ctx.work source.toString
  let envelope ← analyzeExact ctx.root ctx.application setup source.toString "Throwing.lean" "4"
  ensure ((jsonAt? envelope [.field "canonical"]).isNone) s!"{label}: canonical escaped"
  ensureJsonAt envelope [.field "formatFailure", .field "detail"]
      (Lean.toJson "adapter fixture formatter failure") label

/-- Absorbed from the unit exe's `validator-map-negative`: one complete map is admitted, and the
six defect maps (missing tail, overlapping, out-of-order, inverted source, inverted output, short
output) are each rejected by the sourceMap gate. -/
private def testMapNegative : IO Unit := do
  let base : FormatDraft :=
    { text := "abc"
      headerContract := #[]
      commentContract := #[]
      metrics := default
      sourceDigest := ""
      sourceBytes := 3
      headerStop := 0
      terminalStop := 3
      sourceMap := #[{ source := ⟨0, 3⟩, output := ⟨0, 3⟩ }] }
  ensure (Validator.validateMap base).isOk "a complete source map was rejected"
  let defects : Array (String × FormatDraft) :=
    #[("missing source tail", { base with sourceMap := #[{ source := ⟨0, 2⟩, output := ⟨0, 3⟩ }] }),
      ("overlapping source units",
        { base with
          sourceMap :=
            #[{ source := ⟨0, 2⟩, output := ⟨0, 2⟩ }, { source := ⟨1, 3⟩, output := ⟨2, 3⟩ }] }),
      ("out-of-order source units",
        { base with
          sourceMap :=
            #[{ source := ⟨1, 2⟩, output := ⟨0, 1⟩ }, { source := ⟨0, 1⟩, output := ⟨1, 2⟩ },
              { source := ⟨2, 3⟩, output := ⟨2, 3⟩ }] }),
      ("inverted source unit",
        { base with sourceMap := #[{ source := ⟨2, 1⟩, output := ⟨0, 3⟩ }] }),
      ("inverted output unit",
        { base with sourceMap := #[{ source := ⟨0, 3⟩, output := ⟨2, 1⟩ }] }),
      ("short output tail", { base with sourceMap := #[{ source := ⟨0, 3⟩, output := ⟨0, 2⟩ }] })]
  ensureEq "validator-map-negative case count" 6 defects.size
  for (label, defect) in defects do
    match Validator.validateMap defect with
    | .error failure =>
      ensure (failure.gate == .sourceMap) s!"{label}: wrong source-map rejection gate"
    | .ok _ =>
      throw <| IO.userError s!"an invalid source map was admitted: {label}"

end ValidatorSuite

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  -- The admission and throwing fixtures import the adapter syntax library.
  discard <|
      expectExit 0 "lake build FormatterAdapterFixtures" "lake"
        #["build", "FormatterAdapterFixtures"] (cwd? := some root)
  withScratchDir "validator" fun work => do
      let ctx : ValidatorSuite.Ctx :=
        { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, work }
      let mutations : Array (String × String × String) :=
        #[("Contract.lean", "drop-block-comment", "comments"),
          ("Contract.lean", "move-trailing-comment", "comments"),
          ("Contract.lean", "duplicate-doc-comment", "structure"),
          ("TermParentage.lean", "term-reassociate", "structure"),
          ("TacticParentage.lean", "tactic-reassociate", "structure"),
          ("Contract.lean", "change-imports", "header"),
          ("Contract.lean", "move-terminal", "terminal"),
          ("Contract.lean", "second-pass-drift", "idempotence")]
      let cases : Array Case :=
        #[{ name := "admission", run := ValidatorSuite.testAdmission ctx },
              { name := "reparse-agrees", run := ValidatorSuite.testReparseAgrees ctx }] ++
            (mutations.map fun (fixture, mode, gate) =>
              ({ name := mode, run := ValidatorSuite.testGate ctx fixture mode gate } : Case)) ++
          #[{ name := "malformed-diagnostics", run := ValidatorSuite.testMalformed ctx },
            { name := "throwing-refusal", run := ValidatorSuite.testThrowing ctx },
            { name := "map-negative", run := ValidatorSuite.testMapNegative }]
      runCases "validator" cases args
