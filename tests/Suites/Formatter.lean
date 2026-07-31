module

public import Test
public import Test.Oracle

/-!
# The formatter suite

Port of `tests/fixtures/formatter/run.sh`: the frontend-native formatter contract. Thirteen injected
negative gates, each a candidate-shaped lie `tests/fixtures/formatter/candidate.py` tells on purpose, and
the identity baseline with its pinned digest. The oracle is `Test.Oracle` (the port of
`oracle.py`); the candidate stays Python — the admission protocol must keep facing an adversary
this repo does not control.

Lane: parallel — the analyzer probes run against the borrowed Clean.lean setup in a scratch dir.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze (natAt?)

namespace Formatter

structure Ctx where
  root : System.FilePath
  application : String
  setup : System.FilePath
  work : System.FilePath

private def candidateCmd (ctx : Ctx) (mode : String) : Array String :=
  #["python3", (ctx.root / "tests" / "fixtures" / "formatter" / "candidate.py").toString, mode]

/-- One injected negative gate: the oracle must reject the candidate, naming exactly this gate. -/
private def testGate (ctx : Ctx) (fixture mode gate : String) : IO Unit := do
  let label := s!"{mode} rejected by {gate}"
  let outcome ←
    LeanFmt.Test.Oracle.run ctx.root ctx.application ctx.setup ctx.work
        (ctx.root / "tests" / "fixtures" / "formatter" / "fixtures" / fixture)
        (candidateCmd ctx mode)
  match outcome with
  | .ok summary =>
    throw <| IO.userError s!"{label}: the oracle accepted the candidate: {summary.compress}"
  | .error failure =>
    ensureEq s!"{label}: wrong gate" gate failure.gate

/-- The identity baseline: the identity candidate is admitted with zero changes, and the summary
digest is the pinned one — the digest input recipe (sorted keys, compact separators, NUL, then
the formatted bytes) is frozen across the Python and Lean oracles. -/
private def testIdentity (ctx : Ctx) : IO Unit := do
  let outcome ←
    LeanFmt.Test.Oracle.run ctx.root ctx.application ctx.setup ctx.work
        (ctx.root / "tests" / "fixtures" / "formatter" / "fixtures" / "Contract.lean")
        (candidateCmd ctx "identity")
  match outcome with
  | .error failure =>
    throw <| IO.userError s!"identity rejected by {failure.gate}: {failure.detail}"
  | .ok summary =>
    IO.println summary.compress
    ensureJsonAt summary [.field "status"] (Lean.toJson "ok") "identity"
    ensureJsonAt summary [.field "changed"] (Lean.toJson (0 : Nat)) "identity"
    ensureJsonAt summary [.field "reflowedUnits"] (Lean.toJson (0 : Nat)) "identity"
    let nodes := natAt? summary [.field "nodes"] |>.getD 0
    let tokens := natAt? summary [.field "tokens"] |>.getD 0
    ensure (nodes > 0 && tokens > 0) "identity: empty projection"
    ensureJsonAt summary [.field "comments"] (Lean.toJson (3 : Nat)) "identity"
    ensureJsonAt summary [.field "digest"]
        (Lean.toJson "de426c98ee255b1e5d3b4c030a1d0aa7bcf060a694e456ecc91db6a9556cbc09") "identity"

end Formatter

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  withScratchDir "formatter" fun work => do
      let setup ← LeanFmt.Test.Analyze.setupFile root work "tests/fixtures/check/Clean.lean"
      let ctx : Formatter.Ctx :=
        { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, setup,
          work }
      -- A supplied candidate (the old script's `"$@"` branch): any non-flag argument means the
      -- whole argv is one candidate command to admit against the Contract fixture.
      if args.any (!·.startsWith "--") then
        let outcome ←
          LeanFmt.Test.Oracle.run root ctx.application setup work
              (root / "tests" / "fixtures" / "formatter" / "fixtures" / "Contract.lean")
              args.toArray
        match outcome with
        | .ok summary =>
          IO.println summary.compress
        | .error failure =>
          IO.eprintln s!"rejected by {failure.gate}: {failure.detail}"
          return 1
        return 0
      let gates : Array (String × String × String) :=
        #[("Contract.lean", "drop-block-comment", "comments-payload"),
          ("Contract.lean", "move-trailing-comment", "comments-ownership"),
          ("Contract.lean", "duplicate-doc-comment", "comments-payload"),
          ("TermParentage.lean", "term-reassociate", "structure"),
          ("TacticParentage.lean", "tactic-reassociate", "structure"),
          ("Contract.lean", "change-imports", "imports"),
          ("Contract.lean", "move-terminal", "terminal"),
          ("Contract.lean", "stale-artifact", "stale-artifact"),
          ("Contract.lean", "wrong-environment", "environment"),
          ("Contract.lean", "second-pass-drift", "idempotence"),
          ("Contract.lean", "unsupported", "unsupported"),
          ("Contract.lean", "cancelled", "cancellation"),
          ("Contract.lean", "overlap-map", "source-map")]
      let cases : Array Case :=
        gates.map fun (fixture, mode, gate) =>
          ({ name := mode, run := Formatter.testGate ctx fixture mode gate } : Case)
      let cases := cases ++ #[{ name := "identity", run := Formatter.testIdentity ctx }]
      runCases "formatter" cases args
