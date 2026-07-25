module

import Test.Harness

/-!
# Golden files

Byte-exact comparison of a produced artifact against a committed recording — what the shell suites
did with `cmp`, plus the two things `cmp` never gave them: a recorded-update mode and a first
difference offset in the failure.

`UPDATE_GOLDEN=1` rewrites instead of comparing. That is an explicit, loud, opt-in act (the rewrite
is announced on stderr and the file shows up in `git diff`), not a flag that can leak into CI: the
workflow never sets it, so a golden that drifts fails there exactly as `cmp` did.

The comparison is over bytes, not decoded text, because the goldens pin *byte* stability
(`notes/01-report-formats.md` §8.1) and a UTF-8 decode hiccup must be a mismatch, not an exception
from the wrong layer.
-/

namespace LeanFmt.Test

/-- Compare `actual` byte-for-byte against the golden recording at `path`. With `UPDATE_GOLDEN=1`
in the environment, record instead. -/
public def ensureGolden (path : System.FilePath) (actual : String) : IO Unit := do
  if (← IO.getEnv "UPDATE_GOLDEN") == some "1" then
    if let some parent := path.parent then
      IO.FS.createDirAll parent
    IO.FS.writeBinFile path actual.toUTF8
    IO.eprintln s!"UPDATE_GOLDEN: rewrote {path}"
    return
  unless (← path.pathExists) do
    throw <| IO.userError s!"golden file missing: {path} (record it with UPDATE_GOLDEN=1)"
  let expected ← IO.FS.readBinFile path
  let actualBytes := actual.toUTF8
  unless expected == actualBytes do
    let shared := min expected.size actualBytes.size
    let mut offset := 0
    while offset < shared && expected.get! offset == actualBytes.get! offset do
      offset := offset + 1
    throw <| IO.userError s!"golden mismatch: {path}\n  first difference at byte {offset} \
      (golden is {expected.size} bytes, actual is {actualBytes.size})"

end LeanFmt.Test
