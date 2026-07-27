module

import all LeanFmt.Progress
public import Test

/-!
# The progress-display unit cases

`LeanFmt.Progress.renderLine` is the pure half of the batch progress display; these cases pin
its format so a cosmetic edit cannot silently change what every cold run shows.
-/

open LeanFmt LeanFmt.Test

namespace LeanFmt.Test.Unit.Progress

private def testRenderLine : IO Unit := do
  -- A half-done run: 50%, half-filled bar, nonzero rate and ETA, current item shown.
  let line := Progress.renderLine "check" 50 100 0 (50 * 1_000_000_000) "A.lean"
  ensure (line.startsWith "check 50%|") "line does not open with label and percent"
  ensure (line.contains "██████████░░░░░░░░░░") "bar is not half filled"
  ensure (line.contains "50/100") "counts missing"
  ensure (line.contains "[0:50<0:50, 1.0it/s] A.lean") "timing, rate, or item wrong"
  -- Degenerate inputs must not panic: no items done, empty item, zero total.
  let start := Progress.renderLine "fix" 0 10 0 (5 * 1_000_000_000) ""
  ensure (start.endsWith "[0:05<--:--, 0.0it/s]") "zero-done ETA should be --:--"
  ensure (!(start.endsWith " ")) "empty item left a trailing space"
  let done := Progress.renderLine "check" 3 3 0 (3 * 1_000_000_000) "B.lean"
  ensure (done.contains "100%|████████████████████| 3/3") "complete run is not full"

/-- The cases this module contributes to the unit runner, in run order. -/
public def cases : Array Case := #[
  { name := "testRenderLine", run := testRenderLine }]

end LeanFmt.Test.Unit.Progress
