module

public import Test

/-!
# The security-bench suite

Port of `tests/security/bench.sh`: source-security scan cost, asserted rather than
asserted-about. `FMT001` is one pass over the byte array and `FMT002` one fold over the
codepoints, so each is O(n) by construction — but a note cannot notice a regression, and this
can.

**Growth ratios, not wall-clock budgets.** A machine-time threshold would be a number invented
here that fails on a slow machine while catching nothing. A ratio across an 8x size step
separates linear (8x) from quadratic (64x) by a factor far outside timing noise; the bound of 20
is 2.5x the linear prediction and under a third of the quadratic one. The measurement is
`lean-fmt-tests security-bench`, which times `runSourceRules` on scan-clean inputs of doubling
size in one process.

Lane: parallel, slow (a timing measurement over 20 MB inputs).
-/

open LeanFmt.Test

namespace SecurityBench

structure Row where
  bytes : Nat
  ms : Float
  findings : Nat

/-- The bench prints decimal milliseconds (`9.787833`); parse them without a JSON detour. -/
private def parseFloat (s : String) : Option Float := do
  match s.splitOn "." with
  | [whole] =>
    return (← whole.toNat?).toFloat
  | [whole, frac] =>
    let divisor := (List.replicate frac.length 10).foldl (· * ·) 1
    return (← whole.toNat?).toFloat + (← frac.toNat?).toFloat / divisor.toFloat
  | _ =>
    none

private def rows (output : String) : IO (Std.HashMap String Row) := do
  let mut table : Std.HashMap String Row := { }
  for line in output.splitOn "\n" |>.filter (· != "")do
    let fields := line.splitOn " "
    let some label :=
      fields.head? | throw <| IO.userError s!"security-bench emitted a malformed line: {line}"
    let value (key : String) : Option String :=
      (fields.filterMap fun field =>
          if field.startsWith s!"{key}=" then some ((field.drop (key.length + 1)).toString)
          else none).head?
    let some bytes :=
      (value "bytes").bind
        String.toNat? | throw <| IO.userError s!"security-bench row {label} carries no bytes: {line}"
    let some ms :=
      (value "ms").bind
        parseFloat | throw <| IO.userError s!"security-bench row {label} carries no ms: {line}"
    let findings := ((value "findings").bind String.toNat?).getD 0
    table := table.insert label { bytes, ms, findings }
  return table

/-- §growth: the 8x-step ratio must stay under 20 — 2.5x the linear prediction, under a third of
the quadratic one. -/
private def gateGrowth (rows : Std.HashMap String Row) : IO Unit := do
  let some lo := rows["clean-1x"]? | throw <| IO.userError "missing clean-1x measurement"
  let some hi := rows["clean-8x"]? | throw <| IO.userError "missing clean-8x measurement"
  let ratio := hi.ms / lo.ms
  ensure (ratio ≤ 20.0)
      s!"clean scan: {ratio}x over {hi.bytes / lo.bytes}x size, over the 20x bound — not linear"

/-- §flatness: per-byte cost must not jump between adjacent doublings — a superlinear kink could
still pass the 8x-step bound if a later step compensated. -/
private def gateFlatness (rows : Std.HashMap String Row) (report : Bool := true) : IO Unit := do
  let mut previous? : Option Float := none
  for label in ["clean-1x", "clean-2x", "clean-4x", "clean-8x"]do
    let some row := rows[label]? | throw <| IO.userError s!"missing {label} measurement"
    let ns := row.ms * 1000000.0 / row.bytes.toFloat
    if report then
      IO.println s!"  info {label} {ns} ns/byte"
    if let some previous := previous? then
      ensure (ns ≤ previous * 1.6)
          s!"{label}: per-byte cost jumped {ns / previous}x from the previous size —           a superlinear kink"
    previous? := some ns

/-- §findings: the dense input must produce findings in this single process — proof the scans
fired at scale, not that they were fast. -/
private def gateFindings (rows : Std.HashMap String Row) : IO Unit := do
  let some dense := rows["dense"]? | throw <| IO.userError "missing dense measurement"
  ensure (dense.findings > 0)
      "the dense input produced no findings; the scans did not fire at scale"

/-- The gates must be able to fail: crafted tables each breaking one property, accepted by no
gate. A gate that cannot fail reports a healthy tree exactly as convincingly as `pure ()` does. -/
private def testGatesDiscriminate : IO Unit := do
  let row (bytes : Nat) (ms : Float) (findings : Nat := 0) : Row := { bytes, ms, findings }
  let healthy : Std.HashMap String Row :=
    Std.HashMap.ofList
      [("clean-1x", row 1000000 10.0), ("clean-2x", row 2000000 20.0),
        ("clean-4x", row 4000000 40.0), ("clean-8x", row 8000000 80.0),
        ("dense", row 300000 90.0 30000)]
  gateGrowth healthy
  gateFlatness healthy (report := false)
  gateFindings healthy
  let quadratic := healthy.insert "clean-8x" (row 8000000 640.0)
  ensure (← throws (gateGrowth quadratic)) "the growth gate accepted a quadratic scan"
  let kink := healthy.insert "clean-4x" (row 4000000 90.0)
  ensure (← throws (gateFlatness kink (report := false)))
      "the flatness gate accepted a superlinear kink"
  ensure (← throws (gateFindings (healthy.insert "dense" (row 300000 90.0 0))))
      "the findings gate accepted a scan that never fired"
where throws (action : IO Unit) : IO Bool :=
    (try
      action;
      pure false
    catch _ =>
      pure true)

end SecurityBench

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let output ←
    expectExit 0 "security-bench" (root / ".lake" / "build" / "bin" / "lean-fmt-tests").toString
        #["security-bench"] (cwd? := some root) (timeoutMs := some 1800000)
  IO.println output.stdout
  let rows ← SecurityBench.rows output.stdout
  let cases : Array Case :=
    #[{ name := "gates-discriminate", run := SecurityBench.testGatesDiscriminate },
      { name := "growth-is-linear", run := SecurityBench.gateGrowth rows },
      { name := "per-byte-cost-is-flat", run := SecurityBench.gateFlatness rows },
      { name := "findings-fire-at-scale", run := SecurityBench.gateFindings rows }]
  runCases "security-bench" cases args
