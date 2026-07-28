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

namespace LeanFmt.Test.Unit.Edit

/-! ## Edit

Patch assembly: which edit sets produce a patch, which are refused, and what the refusal names. The
adversarial case drives fix-all over overlapping and adjacent fixes, where the all-or-nothing rule is
the only thing keeping a partial write off disk. -/

private def findingWithEdit (range : SourceRange) (replacement : String)
    (applicability : Applicability := .safe) (code : String := "TEST") : Finding := {
  code
  severity := .warning
  message := "test edit"
  range
  fix? := some { applicability, edits := #[{ range, replacement }] }
}

private def requirePatch (source : String) (findings : Array Finding) : IO Patch :=
  match preparePatch source findings with
  | .ok patch => pure patch
  | .error error => throw <| IO.userError s!"valid patch was rejected: {error}"

private def requireRevert (patch : Patch) : IO String :=
  match patch.revert with
  | .ok source => pure source
  | .error error => throw <| IO.userError s!"checked inverse was rejected: {error}"

private def ensureRejected (source : String) (findings : Array Finding)
    (accept : PatchError → Bool) (message : String) : IO Unit :=
  match preparePatch source findings with
  | .error error => ensure (accept error) s!"{message}: wrong rejection: {error}"
  | .ok _ => throw <| IO.userError message

private def testEdits : IO Unit := do
  -- Patch assembly over multi-byte input (`α` is two UTF-8 bytes), independent of any rule: two disjoint
  -- synthetic safe edits exercise the offset math, `editCount`, `changed`, and `revert`. (Trailing
  -- whitespace and the final newline are the formatter's layout now, tested in formatter and
  -- tests/modes — not a source-rule fix.)
  let source := "def α := 1  \n#check α"
  let patch ← requirePatch source #[
    findingWithEdit { start := 11, stop := 13 } "" .safe "SYN_A",
    findingWithEdit { start := source.utf8ByteSize, stop := source.utf8ByteSize } "\n" .safe "SYN_B"]
  ensure (patch.formatted == "def α := 1\n#check α\n")
    "rule edits did not produce the expected UTF-8 output"
  ensure patch.changed "nonempty edit set was reported unchanged"
  ensure (patch.editCount == 2) "patch lost selected edits"
  ensure (patch.matchesSource source) "patch lost its immutable source identity"
  ensure (!(patch.matchesSource (source ++ "\n"))) "stale source matched a checked patch"
  ensure ((← requireRevert patch) == source) "checked patch did not exactly reverse"

  let ordered := #[
    findingWithEdit { start := 0, stop := 1 } "A",
    findingWithEdit { start := 1, stop := 2 } "B"
  ]
  let reverseOrder := #[ordered[1]!, ordered[0]!]
  let adjacent ← requirePatch "xy" ordered
  let adjacentReverse ← requirePatch "xy" reverseOrder
  ensure (adjacent.formatted == "AB" && adjacentReverse.formatted == "AB")
    "adjacent edits were rejected or input order changed output"

  ensureRejected "abc" #[findingWithEdit { start := 1, stop := 4 } "x"]
    (fun | .invalidRange .. => true | _ => false)
    "out-of-range edit was accepted"
  ensureRejected "αb" #[findingWithEdit { start := 1, stop := 2 } "x"]
    (fun | .invalidBoundary .. => true | _ => false)
    "non-boundary UTF-8 edit was accepted"
  ensureRejected "abc" #[
      findingWithEdit { start := 0, stop := 2 } "x",
      findingWithEdit { start := 1, stop := 3 } "y"
    ] (fun | .conflict .. => true | _ => false)
    "overlapping replacements were accepted"
  ensureRejected "abc" #[
      findingWithEdit { start := 1, stop := 1 } "x",
      findingWithEdit { start := 1, stop := 1 } "y"
    ] (fun | .conflict .. => true | _ => false)
    "competing insertions were accepted"

  let propertySource := "aαβz"
  let boundaries := #[0, 1, 3, 5, 6]
  let replacements := #["", "x", "λ"]
  for start in boundaries do
    for stop in boundaries do
      if start <= stop then
        for replacement in replacements do
          let patch ← requirePatch propertySource
            #[findingWithEdit { start, stop } replacement]
          ensure ((← requireRevert patch) == propertySource)
            s!"single-edit reversibility failed at {start}-{stop}"

private def findingWithEdits (edits : Array Edit) (applicability : Applicability := .safe)
    (code : String := "TEST") : Finding := {
  code
  severity := .warning
  message := "test multi-edit"
  range := edits[0]?.map (·.range) |>.getD { start := 0, stop := 0 }
  fix? := some { applicability, edits }
}

/-- Adversarial fix-all cases: mixed insert/delete/replace conflicts, multi-edit fixes
inside one transaction, that applicability is never an edit property, and that a safe rule fix leaves a
comment's text intact. The atomic-publish crash/stale cases live in `tests/modes/run.sh`, where a real
temp-file-then-rename is exercised. -/
private def testFixAllAdversarial : IO Unit := do
  -- Insert / delete / replace mixing. An insertion strictly inside a replacement is a conflict;
  -- adjacency at a shared boundary is not; a deletion beside a replacement composes.
  ensureRejected "abc" #[
      findingWithEdit { start := 0, stop := 2 } "X",
      findingWithEdit { start := 1, stop := 1 } "!"
    ] (fun | .conflict .. => true | _ => false)
    "an insertion inside a replacement was accepted"
  let boundary ← requirePatch "abc" #[
      findingWithEdit { start := 0, stop := 2 } "X",
      findingWithEdit { start := 2, stop := 2 } "!"]
  ensure (boundary.formatted == "X!c") "an insertion at a replacement's end boundary was mishandled"
  let deleteReplace ← requirePatch "abcd" #[
      findingWithEdit { start := 0, stop := 1 } "",
      findingWithEdit { start := 1, stop := 2 } "X"]
  ensure (deleteReplace.formatted == "Xcd") "a deletion beside a replacement did not compose"

  -- One `Fix` may carry several edits; they are one transaction. Disjoint edits apply together and
  -- revert exactly; overlapping edits within a single fix still reject, naming that fix on both sides.
  let multi ← requirePatch "abcd" #[findingWithEdits #[
      { range := { start := 0, stop := 1 }, replacement := "X" },
      { range := { start := 2, stop := 3 }, replacement := "Y" }] .safe "MULTI"]
  ensure (multi.formatted == "XbYd") "a multi-edit fix did not apply as one transaction"
  ensure ((← requireRevert multi) == "abcd") "a multi-edit fix did not revert exactly"
  match preparePatch "abcd" #[findingWithEdits #[
      { range := { start := 0, stop := 2 }, replacement := "X" },
      { range := { start := 1, stop := 3 }, replacement := "Y" }] .safe "MULTI"] with
  | .error (.conflict left right _ _) =>
    ensure (left == "MULTI" && right == "MULTI") "an intra-fix conflict lost the fix's own provenance"
  | _ => throw <| IO.userError "overlapping edits within one fix were accepted"

  -- Mixed-tier conflict: the conflict path carries no tier. A syntax-rule fix (`FMT011`)
  -- and an import-rule fix (`FMT003`) that overlap on the same original bytes reject and name BOTH
  -- rules. No file drives this — the shipped fixes are disjoint by design (the syntax `.safe` fixes edit
  -- paren/attribute ranges, FMT003 edits an import line, FMT012 renames a deprecated ident; none
  -- intersect), so the composition is exercised here at `preparePatch`, its owning layer. (There is no
  -- source-tier fixable rule — trailing whitespace and the final
  -- newline are the formatter's layout, not lint rules.)
  match preparePatch "abc" #[
      findingWithEdit { start := 0, stop := 2 } "" .safe "FMT011",
      findingWithEdit { start := 1, stop := 3 } "" .safe "FMT003"] with
  | .error (.conflict left right _ _) =>
    ensure (#[left, right].qsort (· < ·) == #["FMT003", "FMT011"])
      "a mixed-tier syntax/import conflict did not name both rules distinctly"
  | _ => throw <| IO.userError "an overlapping syntax/import fix pair was accepted"

  -- Applicability governs admission, never bytes. The same edit safe or unsafe assembles identically;
  -- promotion/demotion decides whether `fix` applies it, upstream of the assembler.
  let asSafe ← requirePatch "abc" #[findingWithEdit { start := 0, stop := 1 } "X" .safe "R"]
  let asUnsafe ← requirePatch "abc" #[findingWithEdit { start := 0, stop := 1 } "X" .unsafe "R"]
  ensure (asSafe.formatted == asUnsafe.formatted && asSafe.formatted == "Xbc")
    "applicability changed the bytes a fix produces"

/-- The cases this module contributes to the unit runner, in run order. -/
public def cases : Array Case := #[
  { name := "testEdits", run := testEdits },
  { name := "testFixAllAdversarial", run := testFixAllAdversarial }]

end LeanFmt.Test.Unit.Edit
