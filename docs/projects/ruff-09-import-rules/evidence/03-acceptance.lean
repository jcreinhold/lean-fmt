module

/-
RIR-FINAL acceptance characterization. Reproduce with:

    lake env lean docs/projects/ruff-09-import-rules/evidence/03-acceptance.lean

Captured output: `03-acceptance.txt`. This pins the header-rewrite invariants the roadmap's completion
contract names (`roadmap.md` line 19: "Import rewrites preserve header comments, attributes/modifiers,
blank-group policy, and file-local syntax behavior"), exercised against the shipped `RIR-IMPL` code
(`LeanFmt/Imports.lean`) rather than argued. It imports the private import layer directly, so it is a
`module` file; it is evidence, not tracked production code.

Each case parses a surface header, runs the organizer and the three diagnostics, and checks the output
against a written expectation. `ok`/`FAIL` is printed per case; any `FAIL` is a real regression.
-/

import all LeanFmt.Imports

open LeanFmt.Internal
open LeanFmt.Internal.Imports (organize duplicateFindings orderFindings redundantFindings
  parseHeaderModel redundancyEligible)

/-- Show a string with newlines made visible, so a captured transcript pins exact bytes. -/
def vis (s : String) : String := s.replace "\n" "\\n"

/-- Parse `src`'s header, or panic — every case here is an accepted module header. -/
def header! (src : String) : IO Imports.HeaderModel := do
  let some h ← parseHeaderModel src | throw (IO.userError s!"header did not parse: {vis src}")
  return h

/-- Run the organizer and report whether it matched the expectation. -/
def checkOrganize (name src expected : String) : IO Unit := do
  let h ← header! src
  let got := organize h src
  let status := if got == expected then "ok  " else "FAIL"
  IO.println s!"[{status}] organize/{name}"
  if got != expected then
    IO.println s!"        expected: {vis expected}"
    IO.println s!"        got:      {vis got}"

/-- Report a finding-count expectation for one diagnostic. -/
def checkCount (name : String) (got expected : Nat) : IO Unit := do
  let status := if got == expected then "ok  " else "FAIL"
  IO.println s!"[{status}] {name}: {got} (expected {expected})"

def main : IO Unit := do
  IO.println "== RIR-FINAL header-rewrite acceptance =="

  -- A. A comment is a group boundary: each blank/comment-delimited group is sorted independently, and
  --    the comment survives verbatim between the two sorted groups. Blank-group policy preserved.
  checkOrganize "comment-delimits-groups"
    "module\nimport Delta\nimport Alpha\n-- middle section\nimport Zeta\nimport Beta\n"
    "module\nimport Alpha\nimport Delta\n-- middle section\nimport Beta\nimport Zeta\n"

  -- B. A trailing inline comment forces a group boundary, so the two imports are NOT reordered across
  --    it and the comment is preserved — order-significant safety and comment preservation together.
  checkOrganize "trailing-comment-no-reorder"
    "module\nimport Bravo -- inline note\nimport Alpha\n"
    "module\nimport Bravo -- inline note\nimport Alpha\n"

  -- C. Modifiers ride on the sliced statement bytes: reorder by module name keeps `all` on its import.
  checkOrganize "modifier-preserved-on-reorder"
    "module\nimport all Bravo\nimport Alpha\n"
    "module\nimport Alpha\nimport all Bravo\n"

  -- D. `prelude` (and the `module` marker) are outside the import region and preserved verbatim.
  checkOrganize "prelude-preserved"
    "module\nprelude\nimport Bravo\nimport Alpha\n"
    "module\nprelude\nimport Alpha\nimport Bravo\n"

  -- E. A blank line between two groups is preserved as-is; each group sorts within itself.
  checkOrganize "blank-group-preserved"
    "module\nimport Delta\nimport Charlie\n\nimport Bravo\nimport Alpha\n"
    "module\nimport Charlie\nimport Delta\n\nimport Alpha\nimport Bravo\n"

  -- F. An exact duplicate is removed by the organizer; nothing after the header moves.
  checkOrganize "duplicate-removed"
    "module\nimport Alpha\nimport Alpha\n\ndef body : Nat := 0\n"
    "module\nimport Alpha\n\ndef body : Nat := 0\n"

  -- G. A duplicate whose later line carries a trailing comment: the organizer removes the redundant
  --    statement but the comment (trivia after the dropped leaf) is preserved in the tail — no comment
  --    is dropped. Documented behavior: the surviving line inherits the trailing comment.
  checkOrganize "duplicate-with-comment-keeps-comment"
    "module\nimport Alpha\nimport Alpha -- why twice\n"
    "module\nimport Alpha -- why twice\n"

  IO.println "-- diagnostics --"

  -- FMT005 fires once on the exact duplicate and its fix is safe (the line is solely the import).
  let dup ← header! "module\nimport Alpha\nimport Alpha\n"
  let dupF := duplicateFindings dup "module\nimport Alpha\nimport Alpha\n"
  checkCount "FMT005 count" dupF.size 1
  checkCount "FMT005 has-safe-fix" (dupF.filter (·.fix?.isSome)).size 1

  -- A duplicate whose second line carries a comment is report-only (fix would drop the comment).
  let dupC ← header! "module\nimport Alpha\nimport Alpha -- keep\n"
  let dupCF := duplicateFindings dupC "module\nimport Alpha\nimport Alpha -- keep\n"
  checkCount "FMT005 comment count" dupCF.size 1
  checkCount "FMT005 comment report-only" (dupCF.filter (·.fix?.isNone)).size 1

  -- FMT007 fires within a group but never across a comment/blank boundary, and never carries a fix.
  let ord ← header! "module\nimport Bravo\nimport Alpha\n"
  let ordF := orderFindings ord "module\nimport Bravo\nimport Alpha\n"
  checkCount "FMT007 count" ordF.size 1
  checkCount "FMT007 no-fix" (ordF.filter (·.fix?.isNone)).size 1
  let ordSplit ← header! "module\nimport Bravo\n-- section\nimport Alpha\n"
  let ordSplitF := orderFindings ordSplit "module\nimport Bravo\n-- section\nimport Alpha\n"
  checkCount "FMT007 across-comment count" ordSplitF.size 0

  -- FMT006 withholding: an `import all` line is never a redundancy candidate even inside the closure.
  let redH ← header! "module\nimport Alpha\nimport all Beta\n"
  let closure : Lean.Name → Option (Array Lean.Name) := fun n =>
    if n == `Alpha then some #[`Beta] else some #[]
  let (redF, withheld) := redundantFindings redH closure
  checkCount "FMT006 reported" redF.size 0
  checkCount "FMT006 withheld" withheld 1
  checkCount "FMT006 all-ineligible"
    (if redundancyEligible redH redH.imports[1]! then 1 else 0) 0

  IO.println "== done =="

#eval main
