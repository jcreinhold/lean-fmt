module

import all LeanFmt.ArtifactStore
import all LeanFmt.Analysis
import all LeanFmt.Application
import all LeanFmt.Cache
import all LeanFmt.Comments
import all LeanFmt.Config
import all LeanFmt.Doc
import all LeanFmt.Edit
import all LeanFmt.Imports
import all LeanFmt.Printer
import all LeanFmt.Rules
import all LeanFmt.Service
import all LeanFmt.Suppression

open LeanFmt LeanFmt.Internal LeanFmt.Internal.Service

private def ensure (condition : Bool) (message : String) : IO Unit :=
  unless condition do
    throw <| IO.userError message

private def testDigests : IO Unit := do
  ensure (toString (Digest.ofString "") ==
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    "SHA-256 empty-string vector failed"
  ensure (toString (Digest.ofString "abc") ==
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    "SHA-256 abc vector failed"
  ensure (toString (Digest.ofString
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    "SHA-256 multi-block vector failed"
  ensure (Digest.parse? (toString (Digest.ofString "abc"))).isSome
    "valid SHA-256 digest was rejected"
  ensure (Digest.parse?
    "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD").isNone
    "uppercase digest was accepted"
  ensure (Digest.parse? "abc").isNone "truncated digest was accepted"

/- Rules run on the normalized source, never on the file's bytes. That is not a convenience: the
parser normalizes before it assigns any offset, so findings measured against raw bytes would land in
a different coordinate system than the projection they share an artifact with. -/
private def testRules : IO Unit := do
  let raw := "def x := 1  \r\n#check x\t"
  let (normalized, lineEndings) := LosslessSource.normalize raw
  ensure (lineEndings == .crlf) "a CRLF source was not recognized as CRLF"
  ensure (normalized == "def x := 1  \n#check x\t") "normalization is not crlfToLf"
  ensure (LosslessSource.denormalize normalized lineEndings == raw)
    "denormalize is not the inverse of normalize on accepted source"
  ensure ((LosslessSource.normalize normalized) == (normalized, .lf))
    "normalization is not idempotent"

  let findings := runSourceRules normalized
  ensure (findings.map (·.code) == #["FMT001", "FMT001", "FMT002"])
    "rule ordering or coverage changed"
  ensure (findings[0]!.range == { start := 10, stop := 12 })
    "trailing-whitespace range is not byte-exact in normalized coordinates"
  ensure (findings[1]!.range == { start := 21, stop := 22 })
    "EOF trailing-whitespace range is not byte-exact"
  ensure (findings[2]!.range == { start := 22, stop := 22 })
    "final-newline insertion range is not byte-exact"
  -- Ordering is `findingOrder`'s, not the registry's. The two agree here by accident of two rules,
  -- which is exactly why the sort exists: the assertion above must keep holding when a rule whose
  -- findings land earlier is registered later.
  ensure (findings.map (·.range.start) == #[10, 21, 22])
    "findings are not sorted by position"
  -- Every shipped fix is safe by the byte-level argument in `notes/01-model.md` §1: FMT001/FMT002
  -- edit trivia the lexer cannot see, so they apply by default.
  ensure (findings.all fun f => (f.fix?.map (·.applicability)) == some .safe)
    "a shipped rule produced a non-safe fix"

/-- `FMT003`/`FMT004`: forbidden control bytes and suspicious bidirectional controls. A control byte
or bidi mark only reaches accepted source inside a string literal or comment (bare occurrences are
parse errors, `notes/01-catalog.md` §2), so those are the positions exercised here; ranges are
byte-exact in normalized coordinates and both rules are report-only. -/
private def testSourceSecurityRules : IO Unit := do
  let ctl (n : Nat) : String := String.ofList [Char.ofNat n]
  -- NUL inside a string literal, RLO (U+202E) inside a line comment.
  let src := "def s := \"a" ++ ctl 0x00 ++ "b\"\n-- x" ++ ctl 0x202e ++ "y\n"
  let security := (runSourceRules src).filter fun f => f.code == "FMT003" || f.code == "FMT004"
  ensure (security.map (·.code) == #["FMT003", "FMT004"])
    "control/bidi coverage or sort order changed"
  ensure (security.all fun f => f.fix?.isNone)
    "a source-security rule produced a fix; both are report-only by construction"
  ensure (security.all fun f => f.severity == .warning) "source-security severity changed"
  ensure (security[0]!.range == { start := 11, stop := 12 } &&
      security[0]!.message == "forbidden control byte U+0000")
    "FMT003 range or message is not byte-exact"
  ensure (security[1]!.range == { start := 19, stop := 22 } &&
      security[1]!.message == "suspicious bidirectional control U+202E")
    "FMT004 range is not the mark's exact three-byte span, or its message changed"
  -- A two-byte mark (ALM U+061C) gets a two-byte range: width is the scalar's, not a constant.
  let alm := (runSourceRules ("-- " ++ ctl 0x061c ++ "\n")).filter (·.code == "FMT004")
  ensure (alm.size == 1 && alm[0]!.range == { start := 3, stop := 5 } &&
      alm[0]!.message == "suspicious bidirectional control U+061C")
    "FMT004 width or zero-padded hex is wrong for a two-byte mark"
  -- DEL (0x7F) is forbidden; TAB (0x09) and LF (0x0A) are not.
  ensure (((runSourceRules ("-- " ++ ctl 0x7f ++ "\n")).filter (·.code == "FMT003")).size == 1)
    "DEL (0x7F) was not flagged as a forbidden control byte"
  ensure ((runSourceRules "def a := 1\n\tx := 2\n").all fun f => f.code != "FMT003" && f.code != "FMT004")
    "TAB or LF was flagged as a forbidden control byte"

/- Property/fuzz boundary test for the two source-security scans.

The live scans are checked differentially against an *independent* oracle: FMT003 by an explicit byte
predicate, FMT004 by explicit codepoint-list membership — neither reuses `Rules.lean`'s private
`isForbiddenControl`/`isBidiControl`, so a drift in either the byte set or the offset arithmetic fails
here. The oracle sorts by the same (start, stop, code) key `findingOrder` uses, so the comparison also
pins the sort. Inputs are generated by a deterministic LCG over a pool that mixes forbidden controls,
allowed controls (TAB/LF), every bidi width, safe ASCII, and safe multibyte scalars up to four bytes,
so a mark's byte offset must be carried correctly for the ranges to line up. The scan is a pure
function of the string — acceptance decides only which strings can *reach* it, never what it computes —
so feeding arbitrary generated strings tests strictly more than accepted source would. -/
private def testSourceSecurityProperties : IO Unit := do
  let forbidden (n : Nat) : Bool := (n < 0x20 && n != 0x09 && n != 0x0a) || n == 0x7f
  let bidiSet : List Nat :=
    [0x061c, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069]
  -- Independent expectation: FMT003 per forbidden byte, FMT004 per bidi scalar, in findingOrder.
  let oracle (s : String) : Array (String × Nat × Nat) := Id.run do
    let mut acc : Array (String × Nat × Nat) := #[]
    let bytes := s.toUTF8
    for i in [0:bytes.size] do
      if forbidden (bytes.get! i).toNat then acc := acc.push ("FMT003", i, i + 1)
    let mut pos := 0
    for c in s.toList do
      if bidiSet.contains c.toNat then acc := acc.push ("FMT004", pos, pos + c.utf8Size)
      pos := pos + c.utf8Size
    return acc.qsort fun a b =>
      if a.2.1 != b.2.1 then a.2.1 < b.2.1
      else if a.2.2 != b.2.2 then a.2.2 < b.2.2
      else a.1 < b.1
  let actual (s : String) : Array (String × Nat × Nat) :=
    (runSourceRules s).filterMap fun f =>
      if f.code == "FMT003" || f.code == "FMT004" then some (f.code, f.range.start, f.range.stop)
      else none
  let check (s : String) : IO Unit := do
    ensure (actual s == oracle s)
      "a source-security scan disagreed with the independent oracle on a generated input"
    ensure ((runSourceRules s).all fun f =>
        (f.code != "FMT003" && f.code != "FMT004") || f.fix?.isNone)
      "a source-security rule emitted a fix on a generated input; both are report-only"
  -- Pool: forbidden controls, allowed controls, every bidi width, safe ASCII, safe 2/3/4-byte scalars.
  let pool : Array Nat :=
    #[0x00, 0x07, 0x1b, 0x1f, 0x7f, 0x09, 0x0a,
      0x061c, 0x200f, 0x202a, 0x202e, 0x2066, 0x2069,
      0x41, 0x20, 0x30, 0x22, 0x2f, 0xe9, 0x4e2d, 0x1f600]
  let mut seed : Nat := 0x9e3779b9
  for _ in [0:120] do
    seed := (seed * 1103515245 + 12345) % 2147483648
    let len := seed % 48
    let mut s := ""
    for _ in [0:len] do
      seed := (seed * 1103515245 + 12345) % 2147483648
      s := s.push (Char.ofNat pool[seed % pool.size]!)
    check s
  -- Targeted edges the LCG need not hit: empty, all-forbidden run, control adjacent to a bidi mark,
  -- and a mark at the final byte position.
  check ""
  check (String.ofList (List.replicate 8 (Char.ofNat 0x00)))
  check (String.ofList [Char.ofNat 0x00, Char.ofNat 0x202e, Char.ofNat 0x1b])
  check (String.ofList [Char.ofNat 0x41, Char.ofNat 0x4e2d, Char.ofNat 0x202e])

/-- Parse a surface header, refusing the `none` (parser-message) case the caller never intends. -/
private def parseHeader! (source : String) : IO Imports.HeaderModel := do
  match ← Imports.parseHeaderModel source with
  | some header => return header
  | none => throw <| IO.userError s!"header did not parse: {source}"

/-- `FMT005`/`FMT006`/`FMT007` and the organizer, tested directly — import rules live outside the
`RuleImpl` engine (`notes/01-semantics.md` §1b, §7), so the `runRulesOf` seam does not reach them; the
header rules are pure functions of the parsed surface header, and `redundantFindings` is pure over the
header plus a caller-supplied closure that stands in for the Lake graph. -/
private def testImports : IO Unit := do
  -- The surface header carries the modifier spelling, not the abstract import: `import all A` and
  -- `import A` are distinct statements, so neither is the other's duplicate (`notes` §3).
  let dup ← parseHeader! "import Foo.A\nimport Foo.A\n"
  let dupFindings := Imports.duplicateFindings dup "import Foo.A\nimport Foo.A\n"
  ensure (dupFindings.map (·.code) == #["FMT005"]) "exact duplicate did not fire FMT005 exactly once"
  ensure (dupFindings[0]!.fix?.map (·.applicability) == some .safe)
    "the duplicate-removal fix is not safe"
  -- The safe fix deletes the *later* whole line (the second `import Foo.A`, bytes [13, 26)).
  ensure (dupFindings[0]!.fix?.map (·.edits) == some #[{ range := { start := 13, stop := 26 }, replacement := "" }])
    "the duplicate fix does not delete the later line"

  -- `import all` is valid header syntax only under a `module` marker.
  let notDupSrc := "module\nimport Foo.A\nimport all Foo.A\n"
  let notDup ← parseHeader! notDupSrc
  ensure (Imports.duplicateFindings notDup notDupSrc).isEmpty
    "`import A` and `import all A` were wrongly treated as duplicates"

  -- A literal `import Init` twice is a surface duplicate — it is the phantom `Init` the abstract list
  -- injects that a surface rule can never see, not a written one (`notes` §1a).
  let dupInit ← parseHeader! "import Init\nimport Init\n"
  ensure ((Imports.duplicateFindings dupInit "import Init\nimport Init\n").size == 1)
    "a literal repeated `import Init` did not fire FMT005"

  -- FMT007 fires within one group; a blank line is a group boundary the canonical order never crosses.
  let unordered ← parseHeader! "import Foo.B\nimport Foo.A\n"
  ensure ((Imports.orderFindings unordered "import Foo.B\nimport Foo.A\n").map (·.code) == #["FMT007"])
    "out-of-order imports in one group did not fire FMT007"
  ensure ((Imports.orderFindings unordered "import Foo.B\nimport Foo.A\n")[0]!.fix?.isNone)
    "FMT007 must be report-only (no fix)"
  let grouped ← parseHeader! "import Foo.B\n\nimport Foo.A\n"
  ensure (Imports.orderFindings grouped "import Foo.B\n\nimport Foo.A\n").isEmpty
    "imports in different blank-line groups were wrongly reported out of order"

  -- FMT006: `Foo.B` is reachable via `Foo.A`'s closure, so the plain `import Foo.B` is a candidate.
  let redundant ← parseHeader! "import Foo.A\nimport Foo.B\n"
  let closure : Lean.Name → Option (Array Lean.Name) := fun name =>
    if name == `Foo.A then some #[`Foo.B] else none
  let (redFindings, redWithheld) := Imports.redundantFindings redundant closure
  ensure (redFindings.map (·.code) == #["FMT006"]) "a transitively-covered import did not fire FMT006"
  ensure (redFindings[0]!.fix?.isNone) "FMT006 must be report-only (no fix)"
  ensure (redWithheld == 0) "a plain covered import was wrongly withheld"

  -- Withholding: `import all Foo.B` under a `module` marker exposes data reachability cannot reason
  -- about, so it is withheld (counted), never reported.
  let withheld ← parseHeader! "module\nimport Foo.A\nimport all Foo.B\n"
  let (whFindings, whCount) := Imports.redundantFindings withheld closure
  ensure (whFindings.isEmpty) "an `import all` redundancy candidate was reported rather than withheld"
  ensure (whCount == 1) "the withheld-redundancy count was not recorded"
  ensure (!Imports.redundancyEligible withheld withheld.imports[1]!)
    "`import all` was judged redundancy-eligible"

  -- The organizer: dedup composed with per-group sort, everything else preserved. Text in, text out.
  let sortMe := "import Foo.B\nimport Foo.A\n"
  ensure (Imports.organize (← parseHeader! sortMe) sortMe == "import Foo.A\nimport Foo.B\n")
    "the organizer did not sort a group by module name"
  let dedupMe := "import Foo.A\nimport Foo.A\n"
  ensure (Imports.organize (← parseHeader! dedupMe) dedupMe == "import Foo.A\n")
    "the organizer did not remove a duplicate"

  -- A `prelude` file has no phantom `Init`: the surface model sees only the written imports (`notes` §1a).
  let prelude ← parseHeader! "prelude\nimport Foo.A\n"
  ensure (prelude.hasPrelude && prelude.imports.map (·.module) == #[`Foo.A])
    "the prelude header model does not match the written imports"

private def testServiceProtocol : IO Unit := do
  let health := Lean.Json.parse
    "{\"id\":{\"client\":1},\"method\":\"health\"}" |>.toOption.bind fun json =>
      decodeRequest json |>.toOption
  match health with
  | some (.health (.obj id)) =>
    ensure (((id.get? "client").bind fun value => (Lean.Json.getNat? value).toOption) == some 1)
      "service changed an object request id"
  | _ => throw <| IO.userError "service rejected a valid health request"
  let analyze := Lean.Json.parse
    "{\"id\":2,\"method\":\"analyze\",\"path\":\"A.lean\",\"version\":3,\"source\":\"module\\n\"}"
    |>.toOption.bind fun json => decodeRequest json |>.toOption
  match analyze with
  | some (.analyze (.num _) "A.lean" 3 "module\n") => pure ()
  | _ => throw <| IO.userError "service rejected a valid analyze request"
  ensure (versionAccepted none 0) "service rejected the first version"
  ensure (versionAccepted (some 3) 4) "service rejected a newer version"
  ensure (!(versionAccepted (some 3) 3)) "service accepted a duplicate version"
  ensure (!(versionAccepted (some 3) 2)) "service accepted an older version"
  ensure ((Lean.Json.parse "{\"id\":1,\"method\":\"unknown\"}" |>.toOption.bind fun json =>
    decodeRequest json |>.toOption).isNone) "service accepted an unknown method"

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
  let source := "def α := 1  \n#check α"
  let patch ← requirePatch source (runSourceRules source)
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

/-- Adversarial fix-all cases for `RFX-FINAL`: mixed insert/delete/replace conflicts, multi-edit fixes
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

  -- Applicability governs admission, never bytes. The same edit safe or unsafe assembles identically;
  -- promotion/demotion decides whether `fix` applies it, upstream of the assembler.
  let asSafe ← requirePatch "abc" #[findingWithEdit { start := 0, stop := 1 } "X" .safe "R"]
  let asUnsafe ← requirePatch "abc" #[findingWithEdit { start := 0, stop := 1 } "X" .unsafe "R"]
  ensure (asSafe.formatted == asUnsafe.formatted && asSafe.formatted == "Xbc")
    "applicability changed the bytes a fix produces"

  -- Comment loss: FMT001 strips trailing whitespace even when it trails comment text, but the
  -- comment's content survives. A safe fix edits trivia, never a comment.
  let commented := "def x := 1 -- c  \n"
  let patch ← requirePatch commented (runSourceRules commented)
  ensure (patch.formatted == "def x := 1 -- c\n") "FMT001 did not strip only the trailing whitespace"
  ensure (("def x := 1 -- c\n".splitOn "-- c").length == 2) "the comment text was lost by a safe fix"

private def testConfig : IO Unit := do
  let directory ← IO.FS.createTempDir
  let configPath := directory / "lean-fmt.toml"
  try
    IO.FS.writeFile configPath "\
include = [\"LeanFmt/**/*.lean\", \"Main.lean\"]\n\
exclude = [\"LeanFmt/Generated/**\"]\n\
select = [\"text\"]\n\
ignore = [\"FMT002\"]\n\
[per-file-ignores]\n\
\"LeanFmt/Legacy/*.lean\" = [\"FMT001\"]\n"
    let config ← FormatterConfig.load directory
    ensure (config.includesPath "LeanFmt/Internal/File.lean")
      "recursive include pattern did not match"
    ensure (config.includesPath "Main.lean") "root-file include pattern did not match"
    ensure (!(config.includesPath "LeanFmt/Generated/File.lean"))
      "exclude pattern did not win"
    ensure (!(config.includesPath "Other.lean")) "unmatched path was included"
    let .ok plan := config.rulePlan #[] #[]
      | throw <| IO.userError "valid configured selectors were rejected"
    ensure (plan.activeCount == 1) "configured ignore did not win"
    let findings := runSourceRules "def x := 1  "
    ensure ((plan.findings "LeanFmt/File.lean" findings).map (·.code) == #["FMT001"])
      "configured selector projection was wrong"
    ensure ((plan.findings "LeanFmt/Legacy/File.lean" findings).isEmpty)
      "per-file ignore did not win"
    let .ok cliPlan := config.rulePlan #["FMT002"] #["FMT001"]
      | throw <| IO.userError "valid CLI selectors were rejected"
    ensure (cliPlan.activeCount == 1 &&
      (cliPlan.findings "Main.lean" findings).map (·.code) == #["FMT002"])
      "CLI selection did not replace config selection or ignore precedence changed"
    ensure (match config.rulePlan #["UNKNOWN"] #[] with | .error _ => true | .ok _ => false)
      "unknown CLI selector was accepted"
    -- `security` resolves through the same registry-derived category machinery as `text` — no
    -- hardcoded category list — and the two categories are disjoint.
    let bidi := runSourceRules ("-- x" ++ String.ofList [Char.ofNat 0x202e] ++ "y\n")
    let .ok secPlan := config.rulePlan #["security"] #[]
      | throw <| IO.userError "the 'security' category selector was rejected"
    ensure ((secPlan.findings "A.lean" bidi).map (·.code) == #["FMT004"])
      "the security category did not select FMT004"
    ensure (match config.rulePlan #["text"] #[] with
      | .ok p => (p.findings "A.lean" bidi).isEmpty | .error _ => false)
      "a text selection reported a security finding: the categories are not disjoint"
    IO.FS.writeFile configPath "unknown = true\n"
    let rejected ← try
      discard <| FormatterConfig.load directory
      pure false
    catch _ => pure true
    ensure rejected "unknown configuration key was accepted"
  finally
    IO.FS.removeDirAll directory

private def testApplicability : IO Unit := do
  -- Admission: safe always, unsafe iff opted in, display-only never.
  ensure (Applicability.safe.admitted false && Applicability.safe.admitted true)
    "a safe fix was not admitted"
  ensure (!Applicability.unsafe.admitted false && Applicability.unsafe.admitted true)
    "unsafe admission did not track the opt-in"
  ensure (!Applicability.displayOnly.admitted false && !Applicability.displayOnly.admitted true)
    "a display-only fix was admitted"

  -- Wire round-trip and stable spellings.
  for (a, wire) in #[(Applicability.safe, "safe"), (.unsafe, "unsafe"), (.displayOnly, "display-only")] do
    ensure (a.toWire == wire) s!"applicability wire spelling changed for {wire}"
    ensure (match (Lean.fromJson? (Lean.toJson a) : Except String Applicability) with
      | .ok decoded => decoded == a | .error _ => false) s!"applicability did not round-trip: {wire}"
  ensure (match (Lean.fromJson? (.str "bogus") : Except String Applicability) with
    | .error _ => true | _ => false) "an unknown applicability wire value was accepted"

  -- Per-rule reclassification, resolved as a plan projection.
  let plan : RulePlan := { selected := #["FMT001", "FMT002"], perFileIgnores := #[], extendSafe := #["FMT001"], extendUnsafe := #["FMT002"] }
  ensure (plan.effectiveApplicability "FMT001" .unsafe == .safe) "extend-safe-fixes did not promote"
  ensure (plan.effectiveApplicability "FMT001" .safe == .safe) "promotion changed an already-safe fix"
  ensure (plan.effectiveApplicability "FMT002" .safe == .unsafe) "extend-unsafe-fixes did not demote"
  ensure (plan.effectiveApplicability "FMT999" .safe == .safe) "an unlisted rule was reclassified"
  -- Display-only is a floor no promotion can lift.
  ensure (plan.effectiveApplicability "FMT001" .displayOnly == .displayOnly)
    "extend-safe-fixes promoted a display-only fix"

  -- `RulePlan.findings` carries the effective applicability onto the reported fix.
  let demote : RulePlan := { selected := #["FMT001"], perFileIgnores := #[], extendSafe := #[], extendUnsafe := #["FMT001"] }
  let projected := demote.findings "A.lean" (runSourceRules "def x := 1  \n")
  ensure (projected.size == 1 && (projected[0]!.fix?.map (·.applicability)) == some .unsafe)
    "the findings projection did not demote FMT001's fix"

  -- Conflict provenance names both rules, not array indices.
  match preparePatch "abc" #[
      findingWithEdit { start := 0, stop := 2 } "x" .safe "RULE_A",
      findingWithEdit { start := 1, stop := 3 } "y" .safe "RULE_B"
    ] with
  | .error error =>
    let rendered := toString error
    ensure ((rendered.splitOn "RULE_A").length == 2 && (rendered.splitOn "RULE_B").length == 2)
      s!"conflict error did not name both rules: {rendered}"
  | .ok _ => throw <| IO.userError "overlapping fixes were accepted"

  -- Contradiction: a rule in both extend lists is rejected at plan construction.
  let directory ← IO.FS.createTempDir
  try
    let configPath := directory / "lean-fmt.toml"
    IO.FS.writeFile configPath "extend-safe-fixes = [\"FMT001\"]\nextend-unsafe-fixes = [\"FMT001\"]\n"
    let config ← FormatterConfig.load directory
    ensure (match config.rulePlan #[] #[] with | .error _ => true | _ => false)
      "a rule in both extend lists was accepted"
  finally
    IO.FS.removeDirAll directory

private def testCacheIdentity : IO Unit := do
  let base : CacheIdentity := {
    source := Digest.ofString "source"
    toolchain := "toolchain"
    environment := Digest.ofString "environment"
    formatter := Digest.ofString "formatter"
    configuration := Digest.ofString "configuration"
    validationLevel := .syntax
    semanticSchema := semanticResultSchema
  }
  let original := cacheIdentityDigest base
  let changes := #[
    cacheIdentityDigest { base with source := Digest.ofString "other-source" },
    cacheIdentityDigest { base with toolchain := "other-toolchain" },
    cacheIdentityDigest { base with environment := Digest.ofString "other-environment" },
    cacheIdentityDigest { base with formatter := Digest.ofString "other-formatter" },
    cacheIdentityDigest { base with configuration := Digest.ofString "other-configuration" },
    cacheIdentityDigest { base with validationLevel := .elaboration },
    cacheIdentityDigest { base with semanticSchema := "other-semantic-schema" }
  ]
  ensure (changes.all (· != original))
    "a semantic cache identity component did not invalidate the key"
  ensure (changes.toList.Pairwise (· != ·))
    "distinct cache identity components collided in the test fixture"

/- The projection of `def x := 1\n`, written out by hand so the tiling invariant is legible: every
token's span and trivia runs abut, covering `[headerStop, terminalStop)` exactly once.

    byte 0    3 4 5 6  8 9 10 11
         |def | |x| |:=| |1 |\n|
-/
private def fixtureSourceText : String := "def x := 1\n"

private def fixtureLosslessSource (mainModule := "Test") : LosslessSource := {
  schema := losslessSourceSchema
  mainModule
  normalizedBytes := fixtureSourceText.utf8ByteSize
  normalizedDigest := Digest.ofString fixtureSourceText
  headerStop := 0
  terminalStop := fixtureSourceText.utf8ByteSize
  kinds := #["Lean.Parser.Command.declaration"]
  nodes := #[{ kind := 0, parent := none, range := { start := 0, stop := 10 } }]
  tokens := #[
    { node := 0, start := 0, stop := 3, trailing := #[{ kind := .whitespace, stop := 4 }] },
    { node := 0, start := 4, stop := 5, trailing := #[{ kind := .whitespace, stop := 6 }] },
    { node := 0, start := 6, stop := 8, trailing := #[{ kind := .whitespace, stop := 9 }] },
    { node := 0, start := 9, stop := 10, trailing := #[{ kind := .whitespace, stop := 11 }] }
  ]
}

/-! ## The engine, exercised at both tiers

Every rule the product ships is `source`-tier, so `ruleRegistry` cannot reach the engine's tier
behavior at all: nothing is ever skipped, no `syntax` finding ever has to sort against a `source`
one, and `requiredTier` is `.source` for every possible selection. `RRE-FINAL`'s work order asks for
"a representative rule at each tier"; its stop rule says "do not retain fake product rules merely for
coverage". Both hold at once only if the representative rules live here and never enter
`ruleRegistry` — which is what `runRulesOf` and `requiredTierOf` take an array for.

These rules are deliberately trivial and deliberately adversarial about order: `probeSyntax` is
registered **last** and its findings land **first**, so an engine that concatenated in registry order
would fail every assertion below. -/

/-- `syntax`-tier: reports the projection's first token. Registered last, finds earliest. -/
private def probeSyntax : Rule := {
  info := {
    code := "TST900", category := "test", summary := "probe: first token"
    fixable := false, defaultEnabled := false
  }
  impl := .syntax fun facts =>
    match facts.projection.tokens[0]? with
    | none => #[]
    | some token => #[{
        code := "TST900", severity := .warning, message := "first token"
        range := { start := token.start, stop := token.stop }
      }]
}

/-- `source`-tier: reports the whole file. Shares its range with `probeTie` to pin tie-breaking. -/
private def probeSource : Rule := {
  info := {
    code := "TST901", category := "test", summary := "probe: whole file"
    fixable := false, defaultEnabled := false
  }
  impl := .source fun facts => #[{
    code := "TST901", severity := .warning, message := "whole file"
    range := { start := 0, stop := facts.bytes.size }
  }]
}

/-- `source`-tier, same range as `probeSource`, registered after it but ordering before it by code. -/
private def probeTie : Rule := {
  info := {
    code := "TST900", category := "test", summary := "probe: tie"
    fixable := false, defaultEnabled := false
  }
  impl := .source fun facts => #[{
    code := "TST900", severity := .warning, message := "tie"
    range := { start := 0, stop := facts.bytes.size }
  }]
}

private def testEngineTiers : IO Unit := do
  let normalized := fixtureSourceText
  let projection := fixtureLosslessSource
  let syntaxFacts := Facts.syntax (SyntaxFacts.of normalized projection)
  let sourceFacts := Facts.source (SourceFacts.of normalized)
  let registry := #[probeSource, probeSyntax]

  -- Mixed tiers, sorted by position and not by registry order. `probeSource` covers [0, 11) and
  -- `probeSyntax` finds the `def` token at [0, 3): same start, so the shorter range wins the tie.
  let mixed := runRulesOf registry syntaxFacts
  ensure (mixed.map (·.code) == #["TST900", "TST901"])
    "mixed-tier findings are not byte-sorted independently of registry order"
  ensure (mixed.map (fun finding => (finding.range.start, finding.range.stop)) == #[(0, 3), (0, 11)])
    "mixed-tier ranges are wrong or not sorted by stop within one start"

  -- The same registry against facts that cannot serve the `syntax` rule: it is skipped, not guessed
  -- at, not defaulted, and not an error. `requiredTierOf` is what makes the skip sound — it is what
  -- decided to obtain these facts, and it reads the same array.
  let skipped := runRulesOf registry sourceFacts
  ensure (skipped.map (·.code) == #["TST901"])
    "source facts did not skip exactly the syntax-tier rule"

  -- Ties inside one position break on the code, so registry order cannot decide output.
  let tied := runRulesOf #[probeSource, probeTie] sourceFacts
  ensure (tied.map (·.code) == #["TST900", "TST901"])
    "findings at one identical range are ordered by registry position rather than by code"
  let tiedReversed := runRulesOf #[probeTie, probeSource] sourceFacts
  ensure (tied == tiedReversed) "reordering the registry changed the output"

  -- A rule's tier is its implementation's, and `ToJson` derives `input` from it rather than reading
  -- a field. This is the drift `RuleInfo.input` allowed and `RuleImpl` makes unrepresentable.
  ensure (probeSyntax.tier == .syntax && probeSource.tier == .source) "Rule.tier is not RuleImpl.tier"
  let encoded := Lean.toJson probeSyntax
  ensure ((encoded.getObjValAs? String "input").toOption == some "syntax")
    "the rules wire shape does not derive input from the implementation"
  ensure (ruleRegistry.all (·.tier == .source))
    "a non-source rule reached ruleRegistry: `Application.renderCanonicalText` and the source-only \
     shortcut in `availableAnalysis` both need revisiting (ruff-06/RFX-SPEC owns this)"

  -- The lattice gained `semantic` above `syntax` (`ruff-05b`): richer facts serve any cheaper
  -- requirement, and the cheaper cannot serve the dearer. No shipped rule is `semantic`-tier; the
  -- formatter demands the fact through the mode (`RulePlan.demandedTier`), exercised below.
  ensure (Tier.satisfies .semantic .syntax && Tier.satisfies .semantic .source)
    "semantic facts failed to serve a cheaper requirement"
  ensure (!Tier.satisfies .syntax .semantic && !Tier.satisfies .source .semantic)
    "a cheaper tier was accepted for a semantic requirement"
  ensure (Tier.satisfies .semantic .semantic) "semantic facts did not serve a semantic requirement"
  ensure (Tier.max .syntax .semantic == .semantic && Tier.max .semantic .source == .semantic)
    "Tier.max disagrees with the source ≤ syntax ≤ semantic chain"

/-- Selection derives what a run must *obtain*, and nothing else.

The completion contract's first clause — selection "never selects worker, artifact, cache, or
scheduling strategy" — has two halves. This is the half about cost: what a selection is allowed to
make a run pay for. The other half, that selection stays out of cache identity, is
`tests/check/run.sh`'s one-entry-two-selections check, which needs a real cache and a real project.

`plan.selected` is what the fold reads, so these plans are built directly rather than through
`FormatterConfig.rulePlan`: the probe codes are not in `ruleRegistry` and `selectorsValid` would
rightly reject them. That is the seam working as intended — no fake rule is reachable from config. -/
private def testMixedSelection : IO Unit := do
  let registry := #[probeSource, probeSyntax]
  let plan (selected : Array String) : RulePlan :=
    { selected, perFileIgnores := #[], extendSafe := #[], extendUnsafe := #[] }

  ensure ((plan #[]).requiredTierOf registry == .source)
    "selecting nothing did not cost source facts"
  ensure ((plan #["TST901"]).requiredTierOf registry == .source)
    "selecting only a source rule cost more than source facts"
  ensure ((plan #["TST900"]).requiredTierOf registry == .syntax)
    "selecting a syntax rule did not require syntax facts"
  -- The point of `Tier.max`: one syntax rule in a mixed selection decides the whole batch, and its
  -- position in the array cannot matter.
  ensure ((plan #["TST900", "TST901"]).requiredTierOf registry == .syntax)
    "a mixed selection did not take the maximum of its rules' tiers"
  ensure ((plan #["TST901", "TST900"]).requiredTierOf #[probeSyntax, probeSource] == .syntax)
    "requiredTierOf depends on registry or selection order"
  -- An unselected syntax rule cannot make a run pay for facts nothing will read. This is the
  -- property that makes `--select` free: turning a rule off can never rebuild or re-elaborate.
  ensure ((plan #["TST901"]).requiredTierOf #[probeSyntax, probeSource] == .source)
    "an unselected syntax rule still cost the run its facts"
  -- And the derivation must agree with what the engine will actually run, or a batch obtains facts
  -- for rules it skips, or skips rules it obtained facts for.
  ensure ((runRulesOf registry (.source (SourceFacts.of fixtureSourceText))).map (·.code) ==
      #["TST901"])
    "requiredTierOf and runRulesOf disagree about what source facts can answer"
  ensure (ruleRegistry.all (fun rule => ({ selected := #[rule.code], perFileIgnores := #[], extendSafe := #[], extendUnsafe := #[] } : RulePlan).requiredTier == .source))
    "a shipped rule's selection costs more than source facts"

  -- Demand-gating (`ruff-05b`): the mode is the only demander of `semantic`, because no shipped rule
  -- reaches that tier. A report run (no canonical rendering) stays at its rules' tier; a
  -- canonical-rendering run (`format`/`diff`/`fix`) is lifted to `.semantic`, so the declared-spacing
  -- fact is captured then and not on the syntax-only fast path. `demandedTier` folds over the shipped
  -- registry, so this uses a shipped code rather than a probe.
  let shippedPlan : RulePlan :=
    { selected := #["FMT001"], perFileIgnores := #[], extendSafe := #[], extendUnsafe := #[] }
  ensure (shippedPlan.demandedTier false == .source)
    "a non-rendering run demanded more than its rules needed"
  ensure (shippedPlan.demandedTier true == .semantic)
    "a canonical-rendering run did not demand the semantic fact"

private def fixtureArtifact : ModuleArtifact := {
  schema := artifactSchema
  source := fixtureLosslessSource
}

/- Every rejection below is an ordinary miss, not an error: a consumer that cannot authenticate a
projection must fall back to the exact frontend rather than trust it or fail the run. -/
private def testLosslessSource : IO Unit := do
  let source := fixtureLosslessSource
  ensure source.structurallyValid "a correctly tiled projection was rejected"
  ensure (source.validFor fixtureSourceText) "the projection rejected its own source"

  -- The recorded CRLF defect: the parser normalizes before it assigns any offset, so the CRLF and
  -- LF forms of one module share a projection. Digesting raw bytes made every CRLF file a
  -- permanent silent miss.
  ensure (source.validFor "def x := 1\r\n")
    "the CRLF form of the projected module was not recognized"
  ensure (!(source.validFor "def x := 2\n")) "a different source matched the projection"
  ensure (!(source.validFor "def x := 1")) "a truncated source matched the projection"

  -- `#exit` ends the token stream before end of file. `terminalStop` is where the terminal command
  -- begins, so the tail covers `#exit` and Lean's never-parsed remainder alike; no token may claim
  -- to describe bytes the parser never read. Recording the terminal's *end* instead left `#exit`
  -- itself covered by nothing, and every file containing one failed to validate at all.
  let tailText := fixtureSourceText ++ "#exit\nnever parsed at all\n"
  let withTail : LosslessSource :=
    { source with normalizedBytes := tailText.utf8ByteSize
                  normalizedDigest := Digest.ofString tailText }
  ensure withTail.structurallyValid "a projection with an unparsed tail was rejected"
  ensure (withTail.validFor tailText) "the tail projection rejected its own source"
  ensure (withTail.terminalStop < withTail.normalizedBytes) "the tail fixture records no tail"

  let rejects (label : String) (broken : LosslessSource) : IO Unit :=
    ensure (!broken.structurallyValid) s!"{label} was accepted as a valid projection"
  rejects "a stale schema" { source with schema := "lean-fmt.lossless-source.v0" }
  rejects "a gap between tokens"
    { source with tokens := source.tokens.set! 1 { source.tokens[1]! with start := 5 } }
  rejects "overlapping tokens"
    { source with tokens := source.tokens.set! 1 { source.tokens[1]! with start := 3 } }
  rejects "a token whose span is inverted"
    { source with tokens := source.tokens.set! 0 { source.tokens[0]! with start := 3, stop := 0 } }
  let longTrailing := { source.tokens[0]! with trailing := #[{ kind := .whitespace, stop := 5 }] }
  rejects "trivia running past the next token"
    { source with tokens := source.tokens.set! 0 longTrailing }
  rejects "a token stream that stops short of the terminal"
    { source with terminalStop := source.terminalStop + 1 }
  rejects "a terminal past the end of the source"
    { source with terminalStop := source.normalizedBytes + 1 }
  rejects "a header past the terminal" { source with headerStop := source.terminalStop + 1 }
  rejects "a token owned by a nonexistent node"
    { source with tokens := source.tokens.set! 0 { source.tokens[0]! with node := 9 } }
  rejects "a node with a nonexistent kind"
    { source with nodes := source.nodes.set! 0 { source.nodes[0]! with kind := 9 } }
  rejects "a node with a nonexistent parent"
    { source with nodes := source.nodes.set! 0 { source.nodes[0]! with parent := some 9 } }
  rejects "a fabricated token position"
    { source with tokens := source.tokens.set! 0 { source.tokens[0]! with info := .synthetic } }

  let decoded : Except String LosslessSource := Lean.fromJson? (Lean.toJson source)
  match decoded with
  | .ok actual => ensure (actual == source) "lossless-source JSON round trip failed"
  | .error message => throw <| IO.userError s!"lossless-source JSON decode failed: {message}"

private def testStore : IO Unit := do
  let artifact := fixtureArtifact
  ensure (structurallyValid artifact) "valid module artifact was rejected"
  ensure (!(structurallyValid { artifact with schema := "other-schema" }))
    "schema change did not reject the artifact"
  -- A `v1` payload left in an `.olean` describes the superseded command-kind projection.
  ensure (!(structurallyValid { artifact with schema := "lean-fmt.module-artifact.v1" }))
    "a stale v1 artifact was accepted by the current reader"
  -- An artifact is now nothing but its schema and its projection, so this is the only remaining way
  -- for one to be structurally wrong. The check that used to live here bounded every finding's range
  -- by `normalizedBytes`; there are no findings to bound.
  ensure (!(structurallyValid { artifact with
      source := { artifact.source with terminalStop := artifact.source.normalizedBytes + 1 } }))
    "an artifact whose projection is itself invalid was accepted"
  ensure (!(artifact.validFor `Other fixtureSourceText)) "a wrong-module artifact was accepted"
  ensure (!(artifact.validFor `Test "other source")) "a wrong-source artifact was accepted"
  ensure (artifact.validFor `Test fixtureSourceText) "a valid artifact was rejected for its source"
  let decoded : Except String ModuleArtifact := Lean.fromJson? (Lean.toJson artifact)
  match decoded with
  | .ok actual => ensure (actual == artifact) "module-artifact JSON round trip failed"
  | .error message => throw <| IO.userError s!"module-artifact JSON decode failed: {message}"
  let directory ← IO.FS.createTempDir
  let path := directory / "nested" / "Test.json"
  try
    writeArtifactAtomic path artifact
    let hash ← Lake.computeFileHash path (text := true)
    let facet : Lake.Artifact := {
      descr := Lake.artifactWithExt hash "json"
      path
      mtime := 0
    }
    ensure ((← readFacet? facet `Test fixtureSourceText) == some artifact)
      "trusted facet artifact round trip failed"
    ensure (← readFacet? facet `Test "other source").isNone
      "source mismatch did not reject the facet artifact"
    ensure (← readFacet? facet `Other fixtureSourceText).isNone
      "module mismatch did not reject the facet artifact"
    IO.FS.writeFile path (Lean.toJson { artifact with schema := "other-schema" }).compress
    ensure (← readFacet? facet `Test fixtureSourceText).isNone
      "tampered facet artifact did not fail its content hash"
    writeArtifactAtomic path artifact
    IO.FS.writeFile (directory / "nested" / "Test.json.tmp-interrupted") "partial"
    ensure ((← readFacet? facet `Test fixtureSourceText) == some artifact)
      "an interrupted temporary write damaged the committed artifact"
    IO.FS.removeFile path
    ensure (← readFacet? facet `Test fixtureSourceText).isNone
      "missing facet artifact was not an ordinary miss"
  finally
    IO.FS.removeDirAll directory

/-- A `v4` artifact carrying the semantic fact: two notation kinds with their declared spacing. Design
B keys by `SyntaxNodeKind`, one entry per distinct kind. -/
private def fixtureSemanticArtifact : ModuleArtifact :=
  { fixtureArtifact with semantic := some { notations := #[
      { kind := "«term_+_»", atoms := #[" + "] },
      { kind := "«term-_»", atoms := #["-"] }] } }

/- The semantic fact is additive and demand-gated: the codec round-trips it, `semantic = none` (the
always-on plugin's shape) stays valid, and a `v3` payload — including one that predates the field
entirely — is an ordinary miss under the schema guard rather than a decode crash that would present
unknown declared spacing as captured-and-empty. `ruff-05b` `RSF-IMPL`. -/
private def testSemanticArtifact : IO Unit := do
  ensure (structurallyValid fixtureSemanticArtifact)
    "a v4 artifact carrying the semantic fact was rejected"
  let decoded : Except String ModuleArtifact := Lean.fromJson? (Lean.toJson fixtureSemanticArtifact)
  match decoded with
  | .ok actual => ensure (actual == fixtureSemanticArtifact) "v4 semantic artifact JSON round trip failed"
  | .error message => throw <| IO.userError s!"v4 semantic artifact decode failed: {message}"

  -- The plugin producer emits `semantic = none`; that shape is valid and round-trips too.
  ensure (fixtureArtifact.semantic.isNone) "the plugin-shaped fixture already carried a semantic fact"
  ensure (structurallyValid fixtureArtifact) "a v4 artifact with semantic = none was rejected"
  let noneDecoded : Except String ModuleArtifact := Lean.fromJson? (Lean.toJson fixtureArtifact)
  match noneDecoded with
  | .ok actual => ensure (actual == fixtureArtifact) "v4 semantic = none artifact JSON round trip failed"
  | .error message => throw <| IO.userError s!"v4 semantic = none artifact decode failed: {message}"

  -- A stale `v3` payload is a clean miss, the same discipline as the `v1` miss in `testStore`.
  ensure (!(structurallyValid { fixtureArtifact with schema := "lean-fmt.module-artifact.v3" }))
    "a stale v3 artifact was accepted by the current reader"
  -- Faithful to a payload written before the field existed: no `semantic` key at all. The optional
  -- field makes the decoder total over it (decodes to `none`), and the schema guard then misses.
  let v3payload := Lean.Json.mkObj
    [("schema", "lean-fmt.module-artifact.v3"), ("source", Lean.toJson fixtureLosslessSource)]
  match (Lean.fromJson? v3payload : Except String ModuleArtifact) with
  | .ok actual =>
    ensure (actual.semantic.isNone && !structurallyValid actual)
      "a fieldless v3 payload did not decode-then-miss cleanly"
  | .error message => throw <| IO.userError s!"the v4 decoder is not total over a fieldless v3 payload: {message}"

/-- Capture a kind's declared atoms exactly as `analyzeExact`'s `captureNotationSpacing` does:
type-guard to a descriptor, then read it through the **module-safe** compiled meta IR via `evalConst`
(never `ConstantInfo.value?`, the kernel `Expr` the module system strips). `descrAtoms` is the
production walker. `unsafe` because `evalConst` runs compiled code; wrapping the call in an `unsafe`
term keeps this test in the safe `CommandElabM` of a `run_cmd`. `ruff-05b` `RSF-IMPL`. -/
private def kindAtoms (env : Lean.Environment) (kind : Lean.Name) : Array String :=
  match env.find? kind with
  | some ci =>
    if ci.type.isConstOf ``Lean.ParserDescr || ci.type.isConstOf ``Lean.TrailingParserDescr then
      match unsafe (env.evalConst Lean.ParserDescr ({} : Lean.Options) kind) with
      | .ok descr => descrAtoms descr #[]
      | .error _ => #[]
    else #[]
  | none => #[]

/-- Every declared atom of the notations *defined in this module* (`constants.map₂` is the current
module's own decls), captured via the production `evalConst`/`descrAtoms` path. -/
private def localDeclaredAtoms (env : Lean.Environment) : Array String := Id.run do
  let mut atoms : Array String := #[]
  for (kind, _) in env.constants.map₂.toList do
    atoms := atoms ++ kindAtoms env kind
  return atoms

/- Two locally-declared notations whose `ParserDescr` the walker must read. They carry deliberately
distinctive symbols so no other decl's atoms collide: an infix with a breakable gap on both sides, and
a tight prefix — real `ParserDescr`s generated by the `notation`/`prefix` commands, the same shape
`analyzeExact` reads from the live frontend environment. -/
local notation:65 a " ⊹leanfmt⊹ " b => HAdd.hAdd a b
local prefix:100 "⊟leanfmt⊟" => Neg.neg

/- Compile-time acceptance that `evalConst ParserDescr` **is module-safe**, the property whose absence
let the `value?` capture ship empty on ~99% of the corpus (`ruff-05b` `results/03-final.md`). This
file is itself `module`-mode, so every *imported* notation's `value?` is stripped here — yet the
compiled meta IR is retained, so `evalConst` recovers the untrimmed pp-hint. Each core operator's
`value?` is asserted **absent** (the module system did strip it) while `kindAtoms` recovers its
declared spacing — `" + "`, `" * "`, `"-"` — the exact defect the reopened `RSF-IMPL` fixed. -/
open Lean Elab Command in
run_cmd do
  let env ← getEnv
  for (kind, expected) in [(`«term_+_», " + "), (`«term_*_», " * "), (`«term-_», "-")] do
    unless (env.find? kind >>= (·.value?)).isNone do
      throwError "{kind}: expected the module system to strip value?, but it is present — the \
        module-safety premise no longer holds and this test is vacuous"
    let atoms := kindAtoms env kind
    unless atoms.contains expected do
      throwError "{kind}: evalConst did not recover the imported atom {expected.quote} in module \
        mode; got {atoms} (value? is {(env.find? kind >>= (·.value?)).isSome})"

/- Compile-time acceptance of the declared-spacing walker on locally-declared notations:
`kindAtoms` (production `evalConst`/`descrAtoms`) recovers the untrimmed atoms Lean *trims away* at
parse time (`Parser/Basic.lean:1114`). The infix declares `" ⊹leanfmt⊹ "` — a breakable gap on both
sides, spaces intact — and the prefix declares `"⊟leanfmt⊟"`, tight. Recovering the *spaced* form is
the whole point: it proves capture reads the formatter's pp-hint, not the trimmed token the parser
stores. `RSF-FINAL`'s differential then confirms the atoms equal Lean's own emission. `ruff-05b`
`RSF-IMPL`. -/
open Lean Elab Command in
run_cmd do
  let atoms := localDeclaredAtoms (← getEnv)
  unless atoms.contains " ⊹leanfmt⊹ " do
    throwError "the infix's untrimmed breakable gap ' ⊹leanfmt⊹ ' was not captured; got {atoms}"
  unless atoms.contains "⊟leanfmt⊟" do
    throwError "the prefix's tight atom '⊟leanfmt⊟' was not captured; got {atoms}"
  -- The trimmed spelling must never be what we captured: that would be the parser's token, not the
  -- formatter's declared spacing, and the two are exactly what `RSF-SPEC` F1 proved differ.
  unless !atoms.contains "⊹leanfmt⊹" do
    throwError "captured the trimmed token '⊹leanfmt⊹' instead of the declared gap ' ⊹leanfmt⊹ '"

/-- Whether `s` contains `sub` as a substring (`sub` assumed non-empty). -/
private def containsSubstr (s sub : String) : Bool := (s.splitOn sub).length > 1

/- Three locally-declared **symbolic** notations for the fresh-frontend differential below: an infix
with a breakable gap on both sides, a tight infix, and a tight symbolic prefix. Symbolic (not
alphanumeric) atoms matter — `pushToken` adds a lexer-adjacency space around an *identifier-like*
atom to stop it merging with the next token, so an alphanumeric keyword's emitted spacing exceeds its
declared atom. Operators are symbolic, so for them the declared atom *is* the emitted spacing; the
differential asserts exactly that and records the bound. -/
local notation:65 a " ⊞gapfd " b => HAdd.hAdd a b
local notation:65 a "⊕tightfd" b => HAdd.hAdd a b
local prefix:100 "⊗prefd" => Neg.neg

/- **RSF-FINAL fresh-frontend differential** (`ruff-05b`). The captured declared spacing equals what
Lean's own pretty printer emits — the fact is the compiler's, not this stack's guess. For each local
notation this reads the atom `kindAtoms` recovered from its `ParserDescr` (production
`evalConst`/`descrAtoms`), then formats a node built from that notation with `PrettyPrinter.ppTerm`
and asserts the emitted text equals the operands joined by the *captured* atom (not a hardcoded
string, so the two sides are genuinely independent). The final `!=` checks make it non-vacuous: a
wrong atom would not satisfy the equality — this is the mutation guard the audit requires. Core
`+`/`*` emission is confirmed here too; the core *capture* through the on-demand `analyzeExact`
producer is `tests/semantic/run.sh`. -/
open Lean Elab Command PrettyPrinter in
run_cmd do
  let localAtoms := localDeclaredAtoms (← getEnv)
  let atomWith (marker : String) : CommandElabM String := do
    match localAtoms.filter (containsSubstr · marker) with
    | #[atom] => pure atom
    | hits => throwError "expected exactly one captured atom containing {marker}, got {hits}"
  let ppText (stx : Term) : CommandElabM String := do
    pure (← liftCoreM (ppTerm stx)).pretty
  let gap ← atomWith "⊞gapfd"
  let tight ← atomWith "⊕tightfd"
  let pre ← atomWith "⊗prefd"
  -- Infix: emitted text = lhs ++ capturedAtom ++ rhs, exactly.
  let emittedGap ← ppText (← `(1 ⊞gapfd 2))
  unless emittedGap == "1" ++ gap ++ "2" do
    throwError "gap infix: captured {gap.quote} does not predict emitted {emittedGap.quote}"
  unless emittedGap != "1" ++ " wrong " ++ "2" do
    throwError "the differential is vacuous: a wrong atom also matched the gap infix"
  let emittedTight ← ppText (← `(1 ⊕tightfd 2))
  unless emittedTight == "1" ++ tight ++ "2" do
    throwError "tight infix: captured {tight.quote} does not predict emitted {emittedTight.quote}"
  -- Prefix: emitted text = capturedAtom ++ operand, exactly.
  let emittedPre ← ppText (← `(⊗prefd 3))
  unless emittedPre == pre ++ "3" do
    throwError "symbolic prefix: captured {pre.quote} does not predict emitted {emittedPre.quote}"
  -- Core operators emit their declared spacing (their live-env capture is the shell harness's).
  unless (← ppText (← `(1 + 2 * 3))) == "1 + 2 * 3" do
    throwError "core + / * declared spacing drifted from its emission"
  unless (← ppText (← `(-1))) == "-1" do
    throwError "core prefix - declared spacing drifted from its emission"

private def sliceOf (source : String) (start stop : Nat) : String :=
  String.Pos.Raw.extract source ⟨start⟩ ⟨stop⟩

/- Check a projection against the real parser output it claims to describe.

`structurallyValid` proves the spans tile; that is cheap and content-blind. What it cannot see is
whether the recorded spans mean what they say. So this walks the projection independently, slices
the source at every recorded boundary, and reads the bytes back:

- reconstruction concatenates header, every token with its trivia, and the tail, and compares the
  result to the whole file;
- each trivia run must actually contain the form its kind names.

Contiguity makes each trivia run's start the previous stop, so the walk below is the only place that
recovers those starts — if the codec ever recorded a stop that disagreed with the bytes, this is
what would catch it. -/
private def checkProjection (source : LosslessSource) (raw : String) : IO Unit := do
  let normalized := (LosslessSource.normalize raw).1
  ensure source.structurallyValid "the compiler produced a projection that does not tile"
  ensure (source.validFor raw) "the compiler projection does not match its own source"

  let triviaHolds (kind : TriviaKind) (text : String) : Bool :=
    match kind with
    | .whitespace => text.all Char.isWhitespace
    | .lineComment => text.startsWith "--" && !(text.contains '\n')
    | .blockComment => text.startsWith "/-" && text.endsWith "-/"
  let checkTrivia (runs : Array Trivia) (start : Nat) : IO Nat := do
    let mut cursor := start
    for run in runs do
      let text := sliceOf normalized cursor run.stop
      ensure (triviaHolds run.kind text)
        s!"a trivia run classified {repr run.kind} does not contain one: {repr text}"
      cursor := run.stop
    return cursor

  let mut rebuilt := sliceOf normalized 0 source.headerStop
  let mut cursor := source.headerStop
  for token in source.tokens do
    let leadingStop ← checkTrivia token.leading cursor
    ensure (leadingStop == token.start) "leading trivia does not reach its token"
    rebuilt := rebuilt ++ sliceOf normalized cursor token.trailingStop
    cursor := token.trailingStop
    let _ ← checkTrivia token.trailing token.stop
  rebuilt := rebuilt ++ sliceOf normalized source.terminalStop source.normalizedBytes
  ensure (rebuilt == normalized) "the projection does not reconstruct its source byte-for-byte"
  -- The module linter never receives the header, so `headerStop` is the one boundary the projection
  -- asserts rather than observes. Every tracked fixture opens with `module`.
  ensure ((sliceOf normalized 0 source.headerStop).startsWith "module")
    "the recorded header is not the module header"

private unsafe def verifyPluginArtifact (moduleName : Lean.Name)
    (sourcePath : System.FilePath) : IO Unit := do
  Lean.enableInitializersExecution
  Lean.initSearchPath (← Lean.findSysroot)
  let environment ← Lean.importModules #[{ module := moduleName }] {}
    (trustLevel := 1024) (loadExts := true) (level := .exported)
  let source ← IO.FS.readFile sourcePath
  let some artifact := fromEnvironment? environment moduleName
    | throw <| IO.userError "module has no matching lean-fmt payload in its `.olean`"
  ensure (artifact.validFor moduleName source) "plugin payload does not match the source"
  ensure (artifact.schema == artifactSchema) "plugin emitted the wrong schema"
  ensure (artifact.source.kinds.contains "commandEmit_local_command")
    "plugin lost file-local command syntax"
  -- The fixture's `{ first, second }` parses two ways over one byte range. `checkProjection` is
  -- what proves only one alternative spells those bytes; this proves the case is not vacuous.
  ensure (artifact.source.kinds.contains "choice")
    "the fixture's ambiguous parse produced no choice node"
  checkProjection artifact.source source
  -- The roadmap asks for a compact representation. What grows with a file is the token and node
  -- tables, so bound their cost per element; the fixed schema strings and two digests dominate a
  -- small module and say nothing about compactness (a 34-byte module measures 29x its source and
  -- is not thereby extravagant). Derived field-name JSON measured 114 bytes per token and 54 per
  -- node on this fixture, against 28 and 13 for the array wire format.
  let encoded := (Lean.toJson artifact).compress
  let elements := artifact.source.tokens.size + artifact.source.nodes.size
  ensure (encoded.utf8ByteSize < 1024 + 40 * elements)
    s!"plugin artifact is not compact: {encoded.utf8ByteSize} bytes for {elements} elements"

private def verifyFacetArtifact (path sourcePath : System.FilePath)
    (expectedHash : Lake.Hash) : IO Unit := do
  let source ← IO.FS.readFile sourcePath
  let facet : Lake.Artifact := {
    descr := Lake.artifactWithExt expectedHash "json"
    path
    mtime := 0
  }
  let some artifact ← readFacet? facet `LocalSyntax source
    | throw <| IO.userError "facet artifact failed integrity or semantic validation"
  ensure (artifact.source.mainModule == "LocalSyntax") "facet artifact lost module identity"
  checkProjection artifact.source source

/-- The registered facet, end to end, plus the agreement the product had no test for.

`RRE-SPEC` §2 proved `check` and `format` could report different findings for one unchanged file,
because each spelled the rule configuration its own way and only one path was ever tested. The
assertion this ends on is that regression: the same file, both product paths, byte-identical
findings. It is not a tautology — the two paths reach `runRules` through different `Facts`, and the
source-only shortcut in `availableAnalysis` never touches the artifact. If a future source-tier rule
ever consults the projection, or the shortcut's `normalized` ever drifts from the artifact's, this is
what notices. -/
private def verifyOfficialFacet (root sourcePath : System.FilePath) : IO Unit := do
  let root ← IO.FS.realPath root
  let config ← FormatterConfig.load root
  let project ← Project.load root config #[sourcePath]
  let some target := project.targets[0]?
    | throw <| IO.userError "official-facet test did not select exactly one source"
  unless project.targets.size == 1 do
    throw <| IO.userError "official-facet test did not select exactly one source"
  let artifacts ← Application.officialArtifacts project.workspace #[target]
  let some (some artifact) := artifacts[0]?
    | throw <| IO.userError "registered official facet was unavailable or invalid"
  let some semantic := SemanticAnalysis.ofEnvelope? target.source { artifact? := some artifact }
    | throw <| IO.userError "registered official facet did not produce a canonical result"
  let normalized := (LosslessSource.normalize target.source).1
  ensure (semantic == SemanticAnalysis.success normalized
      (runRules (.syntax (SyntaxFacts.of normalized artifact.source))))
    "registered official facet differed from direct product semantics"
  let some artifactResult := semantic.result?
    | throw <| IO.userError "registered official facet produced no result to compare"
  ensure (artifactResult.findings == runSourceRules normalized)
    "the artifact path and the source-only shortcut disagree about one unchanged file"

/-! ## Layout

`RLC-SPEC` froze the contract these check, and its numbers came from `experiments/layout-core/`, which
shares no module with this one. Several assertions below deliberately re-assert an exact figure from
that experiment: if the product and the prototype ever disagree about margin 13, one of them is wrong
and this is where it surfaces. -/

private def hugeWidth : Nat := 1000000

/-- The flat rendering, defined independently of the renderer. `hard` is excluded by the properties
that use this. -/
private def flatText : Doc → String
  | .empty => ""
  | .text s => s
  | .line flat => flat
  | .hard => "\n"
  | .verbatim s => s
  | .cat a b => flatText a ++ flatText b
  | .nest _ d | .group d | .mark _ d => flatText d

/-- Only the literal text, with every break opportunity dropped. -/
private def textAtoms : Doc → String
  | .empty | .line _ | .hard => ""
  | .text s | .verbatim s => s
  | .cat a b => textAtoms a ++ textAtoms b
  | .nest _ d | .group d | .mark _ d => textAtoms d

private def stripLayout (s : String) : String :=
  s.foldl (fun acc c => if c == '\n' || c == ' ' then acc else acc.push c) ""

private def lineCount (s : String) : Nat := (s.splitOn "\n").length

/-- The text at a byte range. `Mark.output` and `Comment.range` are byte-indexed, like every other
offset in the projection, so a test that reads one back must slice by bytes too. -/
private def slice (s : String) (start stop : Nat) : String :=
  (Substring.Raw.mk s ⟨start⟩ ⟨stop⟩).toString

private def nextRand (seed : Nat) : Nat := (seed * 1103515245 + 12345) % 2147483648

/-- A letters-only atom: no space and no newline, so `stripLayout` cannot eat part of one. -/
private def atomFor (r : Nat) : String :=
  String.ofList (List.replicate (r % 6 + 1) (Char.ofNat (97 + r % 26)))

/-- A deterministic document generator. Seeded rather than random so a failure is reproducible from
the printed seed alone; `hard` and `verbatim` are excluded because the properties below are about the
flat/broken duality and both constructors opt out of it by definition. -/
private partial def genDoc (depth : Nat) (seed : Nat) : Doc × Nat :=
  let r := nextRand seed
  if depth == 0 then
    match r % 3 with
    | 0 => (.empty, r)
    | 1 => (.text (atomFor r), r)
    | _ => (.line (if r % 2 == 0 then " " else ""), r)
  else
    match r % 7 with
    | 0 => (.text (atomFor r), r)
    | 1 => (.line " ", r)
    | 2 => (.line "", r)
    | 3 =>
      let (a, r₁) := genDoc (depth - 1) r
      let (b, r₂) := genDoc (depth - 1) r₁
      (.cat a b, r₂)
    | 4 =>
      let (d, r₁) := genDoc (depth - 1) r
      (.nest 2 d, r₁)
    | 5 =>
      let (d, r₁) := genDoc (depth - 1) r
      (.group d, r₁)
    | _ =>
      let (d, r₁) := genDoc (depth - 1) r
      (.mark ⟨r % 100, r % 100 + 5⟩ d, r₁)

private def testDoc : IO Unit := do
  -- The case the whole model was chosen for. A `do` block is `do act1; act2` flat and drops the
  -- separator when broken. Measured in `experiments/layout-core`: Oppen *and* `Std.Format` both
  -- render `do\n  act1;\n  act2` here and strand the semicolon, because their break carries blanks
  -- only. This is the one thing `line (flat)` buys, so it is the first thing checked.
  let doBlock : Doc :=
    .text "do" ++ .nest 2 (.group (.line " " ++ .text "act1" ++ .line "; " ++ .text "act2"))
  ensure (renderText 40 doBlock == "do act1; act2") "the flat do block lost its separator"
  ensure (renderText 12 doBlock == "do\n  act1\n  act2") "the broken do block stranded its separator"

  -- A group is decided against the line, not against itself: `f(arg)` is 6 columns but the line it
  -- would produce is 14. The flip at 13/14 is the exact figure `experiments/layout-core` records.
  let tail : Doc :=
    .group (.text "f(" ++ .nest 2 (.line "" ++ .text "arg") ++ .line "" ++ .text ")") ++ .text " => tail"
  ensure (renderText 14 tail == "f(arg) => tail") "a group that fits its line was broken"
  ensure (renderText 13 tail == "f(\n  arg\n) => tail") "a group whose line overflows stayed flat"
  -- A margin is not a guarantee: `) => tail` is atomic, so no margin makes this line shorter.
  ensure (renderText 5 tail == "f(\n  arg\n) => tail") "an unbreakable atom was broken anyway"

  -- Nested groups decide independently: the outer breaks, the inner still fits.
  let nested : Doc := .group (.text "aaaa" ++ .line " " ++ .group (.text "b" ++ .line " " ++ .text "c"))
  ensure (renderText 6 nested == "aaaa\nb c") "an inner group broke because its parent did"

  -- `hard` forces every enclosing group open. This is why a line comment is safe: `--` swallows its
  -- line, so a group must never flatten one onto the same line as the code that follows it.
  ensure (renderText hugeWidth (.group (.text "a" ++ .hard ++ .text "b")) == "a\nb")
    "a group containing a hard break was flattened"
  ensure (renderText hugeWidth (.nest 2 (.group (.text "a" ++ .hard ++ .text "b"))) == "a\n  b")
    "a hard break ignored the current indentation"

  -- `verbatim` is the constructor `RLC-IMPL` added, and this is the reason: a block comment's
  -- interior is content, and `hard` would re-indent it. `Std.Format` re-indents it too.
  let block : Doc := .nest 4 (.hard ++ .verbatim "/- a\n b -/" ++ .hard ++ .text "x")
  ensure (renderText hugeWidth block == "\n    /- a\n b -/\n    x")
    "verbatim text was re-indented, rewriting its content"
  -- After a multi-line verbatim the column is its last line, not the old column plus its width.
  ensure (renderText 12 (.group (.verbatim "aa\nbbb" ++ .line " " ++ .text "cc")) == "aa\nbbb\ncc")
    "a multi-line verbatim was treated as flat"

  -- `text` claims to be one line, and the claim is checkable rather than conventional.
  ensure (Doc.wellFormed doBlock) "a well-formed document was rejected"
  ensure (!Doc.wellFormed (.text "a\nb")) "a text holding two lines was accepted"
  ensure (Doc.wellFormed (.verbatim "a\nb")) "verbatim is how a newline is stated and was rejected"

  -- Source map. Output ranges are bytes; `mark` carries no width and renders exactly as its body.
  let marked : Doc := .text "a" ++ .mark ⟨10, 20⟩ (.text "bcd") ++ .text "e"
  let (out, marks) := render hugeWidth marked
  ensure (out == "abcde") "mark changed the rendering"
  ensure (marks == #[{ source := ⟨10, 20⟩, output := ⟨1, 4⟩ }]) "the source map recorded the wrong range"
  ensure (slice out 1 4 == "bcd") "the recorded output range does not hold the marked text"

  -- Marks complete innermost-first, so the array is in completion order rather than source order.
  let (_, nestedMarks) := render hugeWidth (.mark ⟨1, 2⟩ (.text "x" ++ .mark ⟨3, 4⟩ (.text "y")))
  ensure (nestedMarks == #[{ source := ⟨3, 4⟩, output := ⟨1, 2⟩ }, { source := ⟨1, 2⟩, output := ⟨0, 2⟩ }])
    "nested marks were not recorded innermost-first"

  -- A mark spanning a break still bounds exactly what it produced.
  let (spanOut, spanMarks) := render 4 (.mark ⟨0, 9⟩ (.group (.text "aaa" ++ .line " " ++ .text "bbb")))
  ensure (spanOut == "aaa\nbbb") "a marked group did not break"
  ensure (spanMarks.size == 1 && slice spanOut spanMarks[0]!.output.start spanMarks[0]!.output.stop == spanOut)
    "a mark spanning a break lost part of its output"

  -- Properties over 400 generated documents. The seed is printed on failure, and generation is
  -- deterministic, so a counterexample is reproducible from that number alone.
  let mut seed := 20260716
  for i in [0:400] do
    let (d, next) := genDoc 5 seed
    seed := next
    let wrapped : Doc := .group d
    ensure (Doc.wellFormed wrapped) s!"generated document {i} (seed {seed}) was not well formed"
    -- At an unreachable margin every group is flat, so the renderer must agree with an
    -- independently defined flat rendering. This is what pins `line`'s flat text end to end.
    ensure (renderText hugeWidth wrapped == flatText d)
      s!"flat rendering diverged on document {i} (seed {seed})"
    -- At margin 0 every group with any width breaks, so only the literal atoms survive. Nothing may
    -- be dropped, duplicated, or reordered by breaking.
    ensure (stripLayout (renderText 0 wrapped) == textAtoms d)
      s!"breaking lost or duplicated text on document {i} (seed {seed})"
    -- Rendering is a function, not a process with state.
    ensure (renderText 20 wrapped == renderText 20 wrapped)
      s!"rendering was not deterministic on document {i} (seed {seed})"
    -- Every recorded range must address real output.
    let (text, marks) := render 20 wrapped
    for mark in marks do
      ensure (mark.output.start <= mark.output.stop && mark.output.stop <= text.utf8ByteSize)
        s!"document {i} (seed {seed}) recorded an out-of-bounds output range"
    -- Indentation is never negative and a broken line's indent is bounded by the document's nesting;
    -- a renderer that lost track of `nest` shows up as a line indented past anything it wrote.
    ensure (lineCount text <= Doc.size wrapped + 1)
      s!"document {i} (seed {seed}) produced more lines than it has nodes"

private def testComments : IO Unit := do
  -- `def x := 1  -- why\n-- next\ndef y := 2\n`
  --  0123456789...
  let text := "def x := 1  -- why\n-- next\ndef y := 2\n"
  let lineComment (stop : Nat) : Trivia := { kind := .lineComment, stop }
  let whitespace (stop : Nat) : Trivia := { kind := .whitespace, stop }
  -- `--` runs to but does not include its newline; `whitespace` takes the newline itself
  -- (`LosslessSource.scanTrivia`). That is why the split point can never land inside a line comment.
  let projection : LosslessSource := {
    schema := losslessSourceSchema
    mainModule := "Test"
    normalizedBytes := text.utf8ByteSize
    normalizedDigest := Digest.ofString text
    headerStop := 0
    terminalStop := text.utf8ByteSize
    kinds := #["Lean.Parser.Command.declaration"]
    nodes := #[{ kind := 0, parent := none, range := ⟨0, text.utf8ByteSize⟩ }]
    tokens := #[
      { node := 0, start := 0, stop := 3, trailing := #[whitespace 4] },
      { node := 0, start := 4, stop := 5, trailing := #[whitespace 6] },
      { node := 0, start := 6, stop := 8, trailing := #[whitespace 9] },
      -- `1` owns everything up to the next token: two spaces, a trailing comment, a newline, a
      -- leading comment for the next declaration, and another newline. One run, four owners.
      { node := 0, start := 9, stop := 10,
        trailing := #[whitespace 12, lineComment 18, whitespace 19, lineComment 26, whitespace 27] },
      { node := 0, start := 27, stop := 30, trailing := #[whitespace 31] },
      { node := 0, start := 31, stop := 32, trailing := #[whitespace 33] },
      { node := 0, start := 33, stop := 35, trailing := #[whitespace 36] },
      { node := 0, start := 36, stop := 37, trailing := #[whitespace 38] }
    ]
  }
  ensure projection.structurallyValid "the comment fixture is not a valid projection"
  ensure (projection.validFor text) "the comment fixture does not match its own source"

  let attachment := Comments.attach projection text
  ensure (Comments.partitions projection text) "attachment did not partition the recorded comments"
  ensure (attachment.header == ⟨0, 0⟩) "the fixture has no header and one was reported"
  ensure attachment.trailer.isEmpty "the fixture ends with no comment and a trailer was reported"

  -- `-- why` is on `1`'s line, so `1` owns it.
  ensure (attachment.tokens[3]!.trailing == #[{ kind := .lineComment, range := ⟨12, 18⟩ }])
    "the trailing comment was not owned by the token on its line"
  ensure (slice text 12 18 == "-- why") "the trailing comment range is not the comment"
  -- `-- next` is past the first newline, so it leads the *next* token rather than trailing `1`.
  ensure (attachment.tokens[3]!.leading.isEmpty) "a token claimed a comment from before its own line"
  ensure (attachment.tokens[4]!.leading == #[{ kind := .lineComment, range := ⟨19, 26⟩ }])
    "the leading comment was not handed to the following token"
  ensure (slice text 19 26 == "-- next") "the leading comment range is not the comment"
  ensure (attachment.tokens[4]!.trailing.isEmpty) "a leading comment was also counted as trailing"
  ensure (attachment.all.size == 2) "attachment invented or lost a comment"

  -- The correction to `chooseNiceTrailStop`. A block comment may contain newlines, so Lean's raw
  -- `posOf '\n'` would split *inside* this one; Lean survives that because it only moves a substring
  -- boundary, but attaching whole comments by range would drop it from both sides. Splitting at the
  -- first newline *outside* a comment keeps it whole and gives it to the token whose line it starts
  -- on. Losing it would violate the roadmap's "preserve every comment exactly once".
  let blockText := "def x := /- a\nb -/ 0\n"
  let blockProjection : LosslessSource := {
    schema := losslessSourceSchema
    mainModule := "Test"
    normalizedBytes := blockText.utf8ByteSize
    normalizedDigest := Digest.ofString blockText
    headerStop := 0
    terminalStop := blockText.utf8ByteSize
    kinds := #["Lean.Parser.Command.declaration"]
    nodes := #[{ kind := 0, parent := none, range := ⟨0, blockText.utf8ByteSize⟩ }]
    tokens := #[
      { node := 0, start := 0, stop := 3, trailing := #[whitespace 4] },
      { node := 0, start := 4, stop := 5, trailing := #[whitespace 6] },
      -- `:=` owns a space, a block comment spanning a newline, and a space.
      { node := 0, start := 6, stop := 8,
        trailing := #[whitespace 9, { kind := .blockComment, stop := 18 }, whitespace 19] },
      { node := 0, start := 19, stop := 20, trailing := #[whitespace 21] }
    ]
  }
  ensure blockProjection.structurallyValid "the block-comment fixture is not a valid projection"
  ensure (blockProjection.validFor blockText) "the block-comment fixture does not match its source"
  ensure (Comments.partitions blockProjection blockText)
    "a block comment containing a newline was lost by the split"
  let blockAttachment := Comments.attach blockProjection blockText
  ensure (blockAttachment.tokens[2]!.trailing == #[{ kind := .blockComment, range := ⟨9, 18⟩ }])
    "a multi-line block comment was not owned by the token whose line it starts on"
  ensure (slice blockText 9 18 == "/- a\nb -/") "the block comment range is not the comment"

  -- Dangling: a comment after the last token's split has no next token to lead. It is not dropped,
  -- and it is not silently handed to a token that does not own it.
  let tailText := "def x := 1\n-- dangling\n"
  let tailProjection : LosslessSource := {
    schema := losslessSourceSchema
    mainModule := "Test"
    normalizedBytes := tailText.utf8ByteSize
    normalizedDigest := Digest.ofString tailText
    headerStop := 0
    terminalStop := tailText.utf8ByteSize
    kinds := #["Lean.Parser.Command.declaration"]
    nodes := #[{ kind := 0, parent := none, range := ⟨0, tailText.utf8ByteSize⟩ }]
    tokens := #[
      { node := 0, start := 0, stop := 3, trailing := #[whitespace 4] },
      { node := 0, start := 4, stop := 5, trailing := #[whitespace 6] },
      { node := 0, start := 6, stop := 8, trailing := #[whitespace 9] },
      { node := 0, start := 9, stop := 10,
        trailing := #[whitespace 11, lineComment 22, whitespace 23] }
    ]
  }
  ensure tailProjection.structurallyValid "the dangling fixture is not a valid projection"
  ensure (tailProjection.validFor tailText) "the dangling fixture does not match its source"
  ensure (Comments.partitions tailProjection tailText) "the dangling comment was lost"
  let tailAttachment := Comments.attach tailProjection tailText
  ensure (tailAttachment.trailer == #[{ kind := .lineComment, range := ⟨11, 22⟩ }])
    "a comment past the last token was not reported as dangling"
  ensure (tailAttachment.tokens[3]!.trailing.isEmpty)
    "a comment on its own line was claimed by the previous token"

  -- A header region is reported rather than enumerated: the trivia tiling begins at `headerStop`, so
  -- comments before the first command are not in this projection at all.
  let headed := { tailProjection with headerStop := 0 }
  ensure ((Comments.attach headed tailText).header == ⟨0, 0⟩) "an empty header reported a region"

/-- Project suppression directives over findings, and recover directives from the module header.

`apply` is a pure projection over `Array Finding`; the first block checks it in isolation, with
hand-built facts, so the scope arithmetic is tested without a parser. The second block is the
regression that `RSP-IMPL` found and fixed: a directive in the module header `[0, headerStop)` — the
natural home for `ignore-file` — is invisible to `Comments.allTrivia`, so `collect` scans the header
itself. A hand-built single-command projection puts a directive above the first command and asserts it
is both parsed and, when malformed, reported rather than dropped. -/
private def testSuppression : IO Unit := do
  -- `apply` in isolation. `src` supplies real bytes for the `FMT900` removal fix's range math.
  let src := "module\n-- lean-fmt: ignore-file\ndef x := 1  \n"
  let bytes := src.toUTF8
  let mkFinding (code : String) (start stop : Nat) : Finding :=
    { code, severity := .warning, message := "x", range := ⟨start, stop⟩ }
  let f001 := mkFinding "FMT001" 42 44
  let f002 := mkFinding "FMT002" 44 44
  let mkDir (scope : DirectiveScope) (codes? : Option (Array String))
      (scopeRange : SourceRange) : Directive :=
    { scope, codes?, scopeRange, commentRange := ⟨7, 31⟩ }
  let facts (ds : Array Directive) : SuppressionFacts := { directives := ds, malformed := #[] }

  -- File-scope blanket suppresses every finding in the file.
  let blanket := Suppression.apply (facts #[mkDir .file none ⟨0, bytes.size⟩]) bytes #[f001, f002]
  ensure (blanket.kept.isEmpty && blanket.suppressed == 2 && blanket.unused.isEmpty)
    "file blanket did not suppress every finding"

  -- Code selector suppresses only the named code; the other survives.
  let named := Suppression.apply (facts #[mkDir .file (some #["FMT001"]) ⟨0, bytes.size⟩]) bytes #[f001, f002]
  ensure (named.kept.map (·.code) == #["FMT002"] && named.suppressed == 1 && named.unused.isEmpty)
    "code selector suppressed the wrong set"

  -- Suppression is a projection over codes, so the source-security codes flow through it like any
  -- other. A report-only FMT004 finding is suppressed by a directive that names it.
  let f004 := mkFinding "FMT004" 42 45
  let bidiSuppressed := Suppression.apply (facts #[mkDir .file (some #["FMT004"]) ⟨0, bytes.size⟩]) bytes #[f004]
  ensure (bidiSuppressed.kept.isEmpty && bidiSuppressed.suppressed == 1)
    "a directive naming FMT004 did not suppress the report-only security finding"

  -- A directive whose scope holds no matching finding is unused: FMT900 with a safe removal fix.
  let dead := Suppression.apply (facts #[mkDir .line (some #["FMT001"]) ⟨7, 31⟩]) bytes #[f001]
  ensure (dead.kept.size == 1 && dead.suppressed == 0) "an out-of-scope directive still suppressed"
  ensure (dead.unused.map (·.code) == #["FMT900"]) "an unused directive did not emit FMT900"
  ensure (dead.unused[0]!.fix?.map (·.applicability) == some .safe) "the FMT900 removal fix is not safe"
  -- The removal edit is a *clean line* deletion: a directive alone on its line takes the whole line
  -- and its terminating newline (`⟨7, 32⟩` over `src` — `-- …-file` is `[7, 31)`, the `\n` is `31`),
  -- and replaces with nothing. Applying it must leave `module\ndef x := 1  \n`, not a blank line.
  let removal := dead.unused[0]!.fix?.bind (·.edits[0]?)
  ensure (removal.map (·.range) == some ⟨7, 32⟩ && removal.map (·.replacement) == some "")
    "the FMT900 removal fix does not delete exactly the directive line and its newline"

  -- A list with one live and one dead code suppresses the live one and reports the dead one.
  let mixed := Suppression.apply (facts #[mkDir .file (some #["FMT001", "FMT999"]) ⟨0, bytes.size⟩]) bytes #[f001]
  ensure (mixed.suppressed == 1 && mixed.unused.map (·.code) == #["FMT900"])
    "a mixed live/dead code list did not both suppress and report"

  -- The empty EOF `FMT002` sits exactly on a file scope's upper bound and must still be caught.
  let eof := Suppression.apply (facts #[mkDir .file none ⟨0, 44⟩]) bytes #[f002]
  ensure (eof.suppressed == 1) "a file scope ending at EOF did not catch the empty FMT002"

  -- Header recovery. `headerStop` is the first command's start, so the directive on line 2 lives in
  -- `[0, headerStop)`, which `Comments.allTrivia` omits and `collect` must scan for itself.
  let mkProj (text : String) (headerStop : Nat) : LosslessSource :=
    let size := text.utf8ByteSize
    let tokenStop := headerStop + 3
    {
      schema := losslessSourceSchema
      mainModule := "Test"
      normalizedBytes := size
      normalizedDigest := Digest.ofString text
      headerStop
      terminalStop := size
      kinds := #["Lean.Parser.Command.declaration"]
      nodes := #[{ kind := 0, parent := none, range := ⟨headerStop, size⟩ }]
      tokens := #[{ node := 0, start := headerStop, stop := tokenStop, trailing := #[{ kind := .whitespace, stop := size }] }]
    }
  let headerFacts := Suppression.collect (mkProj src 32) src
  ensure (headerFacts.directives.size == 1) "collect missed a directive in the module header"
  ensure (headerFacts.directives[0]!.scope == .file) "the header directive parsed with the wrong scope"
  ensure (headerFacts.directives[0]!.scopeRange == ⟨0, src.utf8ByteSize⟩)
    "the header ignore-file scope is not the whole file"
  ensure headerFacts.malformed.isEmpty "a well-formed header directive was flagged malformed"

  -- A malformed header directive is reported (FMT901, display-only), never silently dropped.
  let badSrc := "module\n-- lean-fmt: nope\ndef x := 1\n"
  let badFacts := Suppression.collect (mkProj badSrc 25) badSrc
  ensure (badFacts.directives.isEmpty && badFacts.malformed.map (·.code) == #["FMT901"])
    "a malformed header directive was not reported as FMT901"
  ensure (badFacts.malformed[0]!.fix?.map (·.applicability) == some .displayOnly)
    "the FMT901 fix is not display-only"

/-- Attach comments over a real projection and report what happened.

The unit tests above build projections by hand, which checks the attachment algorithm against my
reading of the trivia model. This checks it against the *parser*, over whatever module the caller
projected, and it is the only path here that can catch the trivia model itself being wrong.
`tests/layout/run.sh` drives it across the repository's own modules. -/
private def attachReport (envelopePath sourcePath : String) : IO UInt32 := do
  let .ok json := Lean.Json.parse (← IO.FS.readFile envelopePath)
    | throw <| IO.userError s!"{envelopePath} is not JSON"
  let .ok (envelope : AnalysisEnvelope) := Lean.fromJson? json
    | throw <| IO.userError s!"{envelopePath} is not an analysis envelope"
  let some artifact := envelope.artifact?
    | throw <| IO.userError s!"{sourcePath} produced no artifact: {envelope.diagnostics}"
  let raw ← IO.FS.readFile sourcePath
  let normalized := (LosslessSource.normalize raw).1
  let projection := artifact.source
  ensure (projection.validFor raw) s!"{sourcePath}: the projection does not match its own source"
  -- The claim. `structurallyValid` independently guarantees the trivia runs tile
  -- `[headerStop, terminalStop)` exactly once, so agreeing with an independent walk of those runs
  -- means no comment was dropped, duplicated, or moved.
  ensure (Comments.partitions projection normalized)
    s!"{sourcePath}: attachment did not preserve every comment exactly once"
  let attachment := Comments.attach projection normalized
  let leading := attachment.tokens.foldl (fun n tc => n + tc.leading.size) 0
  let trailing := attachment.tokens.foldl (fun n tc => n + tc.trailing.size) 0
  IO.println s!"comments={attachment.all.size} leading={leading} trailing={trailing} \
dangling={attachment.trailer.size} header_bytes={attachment.header.stop} tokens={projection.tokens.size}"
  return 0

/- Does the conservative printer lose bytes on real parser output?

Every kind is still on the conservative path, so `Printer.format` is the identity on accepted source
and this checks exactly that. The property is weaker than it looks and stronger than it sounds: it does
not test any layout decision, because there are none yet — it tests that the *skeleton* is lossless.
The header split at `headerStop`, the command extents tiling `[headerStop, terminalStop)`, and the
uninterpreted tail from `terminalStop` are each a place where a byte can vanish, and each is checked
here against code nobody wrote to suit the printer.

Checked at several margins because the margin must not matter. `Doc.verbatim` is specified to emit its
bytes unchanged and, unlike `hard`, not to force its group to break; a width-sensitive result would
mean `verbatim` is re-indenting or breaking content that is not the formatter's to touch, which is the
`Std.Format` defect (`Basic.lean:269-276`) that `RLC-IMPL` added the constructor to avoid. Width 0 is
included on purpose: it is the most hostile margin there is. -/
/- The identity check is a claim about *canonical* source, not about the printer.

`checkIdentity` is true for this repository's corpus, whose modules are already written the way the
layouts write them, so any changed byte there is a defect. It is false for the frozen mathlib sample
(`experiments/run-printer-sample.sh`), which is foreign code the printer is *supposed* to reformat —
asserting identity on it reports the declaration layout doing its job as a failure, which is exactly
what the first draft of that script did. Everything else below holds either way: the projection
matching its source, and the extents tiling `[headerStop, terminalStop)` exactly once. -/
private def printerRoundtrip (envelopePath sourcePath : String) (checkIdentity : Bool) :
    IO UInt32 := do
  let .ok json := Lean.Json.parse (← IO.FS.readFile envelopePath)
    | throw <| IO.userError s!"{envelopePath} is not JSON"
  let .ok (envelope : AnalysisEnvelope) := Lean.fromJson? json
    | throw <| IO.userError s!"{envelopePath} is not an analysis envelope"
  let some artifact := envelope.artifact?
    | throw <| IO.userError s!"{sourcePath} produced no artifact: {envelope.diagnostics}"
  let raw ← IO.FS.readFile sourcePath
  let normalized := (LosslessSource.normalize raw).1
  let projection := artifact.source
  ensure (projection.validFor raw) s!"{sourcePath}: the projection does not match its own source"
  if checkIdentity then
    -- Before `RLF-REFLOW` the formatter was margin-independent, so byte-identity held at every width.
    -- Reflow makes it margin-*dependent* by design (`notes/07-reflow-policy.md`): an over-margin
    -- single-line command breaks. Two invariants replace the old one and are together stronger:
    --   * at *every* width, reflow only ever swaps a gap's spaces for a newline+indent, so the
    --     non-whitespace content is byte-identical — a direct parse-preservation proxy (no token
    --     added, dropped, or altered), checked here corpus-wide and by reparse on the fixtures;
    --   * at any width no source line exceeds, nothing can break (a flat layout is never wider than
    --     its source line), so the whole file is byte-identical — losslessness on the canonical corpus.
    let maxLine := (normalized.splitOn "\n").foldl (fun m ln => max m ln.length) 0
    let nonWs (s : String) : List Char := s.toList.filter (!·.isWhitespace)
    for width in [0, 1, 40, 80, 120, 1000] do
      let formatted ← Printer.format projection normalized width
      ensure (nonWs formatted == nonWs normalized)
        s!"{sourcePath}: reflow changed non-whitespace bytes at width {width}"
      if width ≥ maxLine then
        ensure (formatted == normalized)
          s!"{sourcePath}: format changed bytes at fitting width {width} \
({formatted.utf8ByteSize} bytes out, {normalized.utf8ByteSize} in)"
  let tree := Tree.ofSource projection
  let extents := tree.commandExtents
  -- Every command contributes exactly one extent, and the extents touch end to end across
  -- `[headerStop, terminalStop)`. The identity above would survive a *pair* of compensating errors
  -- here — a command dropped and its bytes absorbed into its neighbour's extent reproduces the source
  -- perfectly — so the tiling is checked directly rather than inferred from the bytes.
  ensure (extents.size == tree.roots.size)
    s!"{sourcePath}: {tree.roots.size} commands produced {extents.size} extents"
  let mut cursor := projection.headerStop
  for extent in extents do
    ensure (extent.start == cursor)
      s!"{sourcePath}: extent starts at {extent.start}, expected {cursor}"
    ensure (extent.stop >= extent.start) s!"{sourcePath}: extent {extent.start} runs backwards"
    cursor := extent.stop
  ensure (cursor == projection.terminalStop)
    s!"{sourcePath}: extents end at {cursor}, expected terminalStop {projection.terminalStop}"
  -- `header_canonical` is the header's answer to the question `canonical` asks of the commands: the
  -- round-trip above cannot see whether the header layout ran, because refusing it *is* the identity.
  let headerCanonical := if (← Printer.headerDoc? normalized projection.headerStop).isSome then 1
    else 0
  let (tacticBlocks, tacticOwnable, tacticOwnLine, tacticAtTwo) := tree.tacticBlocks normalized
  IO.println s!"commands={tree.roots.size} canonical={tree.canonicalCommands normalized} \
tokens={projection.tokens.size} nodes={projection.nodes.size} header_bytes={projection.headerStop} \
header_canonical={headerCanonical} members={tree.memberShells normalized} \
app_slack={tree.appSlack normalized} \
binder_slack={tree.binderSlack normalized} \
match_slack={tree.matchSlack normalized} \
tactic_blocks={tacticBlocks} tactic_ownable={tacticOwnable} \
tactic_ownable_own_line={tacticOwnLine} tactic_ownable_at_two={tacticAtTwo} \
tactic_blank_gaps={tree.tacticBlankGaps normalized} \
tail_bytes={projection.normalizedBytes - projection.terminalStop}"
  return 0

/- Print one projected module to stdout, for golden and idempotence checks.

Separate from `printer-roundtrip` because it answers a different question. That one asks whether the
skeleton loses bytes; this one shows what the formatter actually *decided*, which is the only way a
golden file can pin a canonical layout, and the only way idempotence can be checked at all — the second
format needs the first one's output as a file to re-parse. -/
private def printerFormat (envelopePath sourcePath widthText : String) : IO UInt32 := do
  let .ok json := Lean.Json.parse (← IO.FS.readFile envelopePath)
    | throw <| IO.userError s!"{envelopePath} is not JSON"
  let .ok (envelope : AnalysisEnvelope) := Lean.fromJson? json
    | throw <| IO.userError s!"{envelopePath} is not an analysis envelope"
  let some artifact := envelope.artifact?
    | throw <| IO.userError s!"{sourcePath} produced no artifact: {envelope.diagnostics}"
  let some width := widthText.toNat?
    | throw <| IO.userError s!"WIDTH must be a natural number, got {widthText}"
  let raw ← IO.FS.readFile sourcePath
  let normalized := (LosslessSource.normalize raw).1
  let projection := artifact.source
  ensure (projection.validFor raw) s!"{sourcePath}: the projection does not match its own source"
  -- The semantic fact rides along when the envelope carries it (a `captureSemantic=1` analysis); it is
  -- `none` for every fixture analyzed without it, which is exactly the conservative path those goldens
  -- pin. So this one line is what lets a notation fixture change while `wonky`/`header`/`ext` do not.
  IO.print (← Printer.format projection normalized width artifact.semantic)
  return 0

/- Re-indent the fixture's one offside block to `base` and print the whole module — the `RLF-OFFSIDE`
capability driven in isolation. The block is auto-detected (`firstIndentedBlock`: first line-starting
token indented past column 0, through the last token), re-indented (`reindentBlock`, uniform Δ shift),
and spliced back (`reindentSpanInModule`). The suite runs this at several bases and reparses each, so
parse-preservation is checked by the fresh frontend rather than argued. -/
private def printerReindent (envelopePath sourcePath baseText : String) : IO UInt32 := do
  let .ok json := Lean.Json.parse (← IO.FS.readFile envelopePath)
    | throw <| IO.userError s!"{envelopePath} is not JSON"
  let .ok (envelope : AnalysisEnvelope) := Lean.fromJson? json
    | throw <| IO.userError s!"{envelopePath} is not an analysis envelope"
  let some artifact := envelope.artifact?
    | throw <| IO.userError s!"{sourcePath} produced no artifact: {envelope.diagnostics}"
  let some base := baseText.toNat?
    | throw <| IO.userError s!"BASE must be a natural number, got {baseText}"
  let raw ← IO.FS.readFile sourcePath
  let normalized := (LosslessSource.normalize raw).1
  ensure (artifact.source.validFor raw) s!"{sourcePath}: the projection does not match its own source"
  let tree := Tree.ofSource artifact.source
  let some (lo, hi) := tree.firstIndentedBlock normalized
    | throw <| IO.userError s!"{sourcePath}: no indented offside block to re-indent"
  IO.print (tree.reindentSpanInModule normalized lo hi base)
  return 0

/- Name every command the layouts refused, one syntax kind per line.

`printer-report` counts the claims; this names the misses. It exists for the frozen mathlib sample,
where `canonical` is about half of `commands` against 95% on this repository, and the percentage alone
cannot say whether that is unread grammar or a guard misfiring. The caller tallies the lines. -/
private def printerUnclaimed (envelopePath sourcePath : String) : IO UInt32 := do
  let .ok json := Lean.Json.parse (← IO.FS.readFile envelopePath)
    | throw <| IO.userError s!"{envelopePath} is not JSON"
  let .ok (envelope : AnalysisEnvelope) := Lean.fromJson? json
    | throw <| IO.userError s!"{envelopePath} is not an analysis envelope"
  let some artifact := envelope.artifact?
    | throw <| IO.userError s!"{sourcePath} produced no artifact: {envelope.diagnostics}"
  let raw ← IO.FS.readFile sourcePath
  let normalized := (LosslessSource.normalize raw).1
  let projection := artifact.source
  ensure (projection.validFor raw) s!"{sourcePath}: the projection does not match its own source"
  let tree := Tree.ofSource projection
  for kind in tree.unclaimedKinds normalized do
    IO.println kind
  return 0

/- Name every node that carries a token, one syntax kind per line.

`printer-unclaimed` names the commands the layouts refused; this names what is inside them. It exists
for the same corpus and the same reason: `RLF-EXPRESSIONS` must pick the term kinds it can cite a
grammar for, and this repository's term mix is no more representative of Lean than its command mix
turned out to be. The caller tallies the lines. -/
private def printerNodeKinds (envelopePath sourcePath : String) : IO UInt32 := do
  let .ok json := Lean.Json.parse (← IO.FS.readFile envelopePath)
    | throw <| IO.userError s!"{envelopePath} is not JSON"
  let .ok (envelope : AnalysisEnvelope) := Lean.fromJson? json
    | throw <| IO.userError s!"{envelopePath} is not an analysis envelope"
  let some artifact := envelope.artifact?
    | throw <| IO.userError s!"{sourcePath} produced no artifact: {envelope.diagnostics}"
  let raw ← IO.FS.readFile sourcePath
  let projection := artifact.source
  ensure (projection.validFor raw) s!"{sourcePath}: the projection does not match its own source"
  let tree := Tree.ofSource projection
  for kind in tree.nodeKinds do
    IO.println kind
  return 0

/- Layout cost, on the shapes `RLC-FINAL` names.

`notes/01-layout-design.md` §4.6 records a known hole: the fit test is bounded in *columns*, not in
nodes, so a document that never spends a column could make one fit test walk arbitrarily far. These
fixtures are built to decide it rather than to pass. `tests/layout/bench.sh` reads the output and
asserts; the numbers live in `evidence/03-layout-bench.txt`.

Construction is deliberately outside every timed region, and every timed region forces its result: a
pure `let` in Lean is not evaluated where it is written, and an unforced `render` measures 166 ns for
any `n` — which is how this benchmark first lied. -/

/-- **The adversary.** `n` sibling groups that never spend a column and never offer a break, so no fit
test can ever answer early: each one walks the entire remaining tail. This is §4.6's hole made
concrete, and it is not reachable from a printer that emits a token per node — see `bench.sh`. -/
private def zeroWidthSiblings (n : Nat) : Doc := Id.run do
  let mut d := Doc.text "x"
  for _ in [0:n] do
    d := .cat (.group (.nest 1 .empty)) d
  return d

/-- **Adversarial nesting**, which is the shape the roadmap names by that phrase: `n` groups deep,
none of which spends a column. Distinct from `zeroWidthSiblings`, and the distinction is the whole
result — see `evidence/03-layout-bench.txt`. -/
private def zeroWidthNesting (n : Nat) : Doc := Id.run do
  let mut d := Doc.text "x"
  for _ in [0:n] do
    d := .group (.nest 1 d)
  return d

/-- A Lean-shaped call, `f(a0, a1, ...)`: one group, `n` arguments, every argument carrying text. This
is the shape a real printer emits, and the difference from `zeroWidthSiblings` is only that the text is
there. -/
private def callArgs (n : Nat) : Doc := Id.run do
  let mut inner := Doc.empty
  for i in [0:n] do
    let arg := Doc.text s!"a{i}"
    inner := if i == 0 then arg else .cat inner (.cat (.text ",") (.cat (.line " ") arg))
  return .group (.cat (.text "f(") (.cat (.nest 2 (.cat (.line "") inner)) (.cat (.line "") (.text ")"))))

/-- `n` nested calls, `f(f(f(...)))` — the depth axis rather than the width axis. -/
private def nestedCalls (n : Nat) : Doc := Id.run do
  let mut d := Doc.text "x"
  for _ in [0:n] do
    d := .group (.cat (.text "f(") (.cat (.nest 2 (.cat (.line "") d)) (.cat (.line "") (.text ")"))))
  return d

/-- `callArgs` with every argument marked, which is what a real printer does: one mark per token. The
cost of `mark` is the open question `RLC-IMPL` left to this prompt. -/
private def markedCallArgs (n : Nat) : Doc := Id.run do
  let mut inner := Doc.empty
  for i in [0:n] do
    let arg := Doc.mark ⟨i, i + 1⟩ (.text s!"a{i}")
    inner := if i == 0 then arg else .cat inner (.cat (.text ",") (.cat (.line " ") arg))
  return .group (.cat (.text "f(") (.cat (.nest 2 (.cat (.line "") inner)) (.cat (.line "") (.text ")"))))

private def benchOne (label : String) (n : Nat) (d : Doc) : IO Unit := do
  -- Force construction before the clock starts, so building the fixture is not in the measurement.
  if d.size == 0 then throw (IO.userError "the fixture is empty")
  let start ← IO.monoNanosNow
  let (out, marks) := render 80 d
  -- `utf8ByteSize` is O(1) and forces the render; `String.length` would walk the output and bill the
  -- walk to the renderer.
  if out.utf8ByteSize + marks.size == 999999999 then throw (IO.userError "impossible")
  let stop ← IO.monoNanosNow
  IO.println s!"{label} n={n} nodes={d.size} ms={(Float.ofNat (stop - start)) / 1000000.0} \
out_bytes={out.utf8ByteSize} marks={marks.size}"

/-- Every generated document rendered at every margin, as text.

This exists to settle equivalence claims about the renderer by diffing two builds, rather than by
arguing that a change "should not" alter output. `results/03-acceptance.md` records the one it settled. -/
private def docDump : IO UInt32 := do
  let mut seed : Nat := 20260716
  for i in [0:400] do
    let (d, s) := genDoc 4 seed
    seed := s
    for w in [0:41] do
      IO.println s!"{i} {w} {String.intercalate "⏎" ((renderText w d).splitOn "\n")}"
  return 0

/-! ## Source-security microbenchmark (`RSR-FINAL`)

The two source-security scans are linear in source size: `FMT003` is one pass over the byte array,
`FMT004` one fold over the codepoints carrying a running offset. This measures that claim the way
`docBench` measures the printer — by growth *ratio* over doubling inputs, not a wall-clock budget,
because linear and quadratic differ by the size step (here 8×) and mean the same thing on any machine.
`tests/security/bench.sh` asserts the ratios.

The measured input is scan-clean — no control or bidi byte — so the shared post-scan `qsort` over
findings (`Rules.findingOrder`), which every rule pays and is O(m log m) in the finding count m rather
than anything new to these rules, contributes nothing and the number reported is the scan cost itself.
The block carries three-byte CJK scalars so the `FMT004` fold's per-character `utf8Size` offset
arithmetic is exercised across widths, not just one-byte ASCII. A separate dense input confirms the
scans still produce findings at scale. This runs in the single test process — there is no worker, no
child, and no project setup, because a source-tier rule reads only the string it is handed. -/
private def securityCleanBlock : String :=
  -- ASCII plus four 3-byte CJK scalars, no trailing whitespace, newline-terminated so the joined
  -- input is FMT001/FMT002-clean and the timing is the scan alone.
  "def value : Nat := 42 -- 注释 中文\n"

/-- One control byte (NUL) and one bidi mark (U+202E), inside a string literal, per short block. -/
private def securityDenseBlock : String :=
  "def x := \"a" ++ String.ofList [Char.ofNat 0x00] ++ "b" ++ String.ofList [Char.ofNat 0x202e] ++
    "c\"\n"

/-- Grow `block` to at least `targetBytes` by doubling, so construction is O(size) — a linear join of
`k` copies would be O(size²) and would swamp the scan it is meant to feed. -/
private def repeatTo (block : String) (targetBytes : Nat) : String := Id.run do
  let mut s := block
  for _ in [0:64] do
    if s.utf8ByteSize ≥ targetBytes then break
    s := s ++ s
  return s

private def securityBenchOne (label : String) (input : String) : IO Unit := do
  if input.utf8ByteSize == 0 then throw (IO.userError "the bench input is empty")
  let start ← IO.monoNanosNow
  let findings := runSourceRules input
  -- Force the scan; a size comparison walks nothing but pins the array.
  if findings.size == 999999999 then throw (IO.userError "impossible")
  let stop ← IO.monoNanosNow
  IO.println s!"{label} bytes={input.utf8ByteSize} \
ms={(Float.ofNat (stop - start)) / 1000000.0} findings={findings.size}"

private def securityBench : IO UInt32 := do
  -- A ~2 MB scan-clean base, then exact doublings to 4/8/16 MB. Each doubling is built outside the
  -- timed region, so a ~2× step in ms across a 2× step in bytes is the linear claim.
  let mut input := repeatTo securityCleanBlock 2000000
  for label in ["clean-1x", "clean-2x", "clean-4x", "clean-8x"] do
    securityBenchOne label input
    input := input ++ input
  -- Findings do scale: a dense ~256 KB input reports two per block. This is deliberately not part of
  -- the linear assertion — its cost is dominated by the engine's shared O(m log m) finding-sort
  -- (`Rules.findingOrder`), which every rule pays and is not the scan. It proves only that the scans
  -- still fire at size, worker-free.
  securityBenchOne "dense" (repeatTo securityDenseBlock 256000)
  return 0

private def docBench : IO UInt32 := do
  for n in [1000, 2000, 4000, 8000] do
    benchOne "zero-width-siblings" n (zeroWidthSiblings n)
  for n in [1000, 2000, 4000, 8000] do
    benchOne "zero-width-nesting" n (zeroWidthNesting n)
  for n in [1000, 10000, 100000] do
    benchOne "call-args" n (callArgs n)
  -- Capped at 10,000: `nest` is unclamped by contract (§4.6), so depth `n` at unit 2 emits Θ(n²)
  -- *bytes* — 200 MB here, and 20 GB at n=100,000. That cost is the output, not the fit test, which is
  -- why the assertion in `bench.sh` is per output byte rather than per node.
  for n in [100, 1000, 10000] do
    benchOne "nested-calls" n (nestedCalls n)
  for n in [1000, 10000, 100000] do
    benchOne "marked-call-args" n (markedCallArgs n)
  return 0

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | ["attach-report", envelopePath, sourcePath] => attachReport envelopePath sourcePath
  | ["printer-roundtrip", envelopePath, sourcePath] =>
    printerRoundtrip envelopePath sourcePath (checkIdentity := true)
  | ["printer-report", envelopePath, sourcePath] =>
    printerRoundtrip envelopePath sourcePath (checkIdentity := false)
  | ["printer-format", envelopePath, sourcePath, width] => printerFormat envelopePath sourcePath width
  | ["printer-reindent", envelopePath, sourcePath, base] => printerReindent envelopePath sourcePath base
  | ["printer-unclaimed", envelopePath, sourcePath] => printerUnclaimed envelopePath sourcePath
  | ["printer-node-kinds", envelopePath, sourcePath] => printerNodeKinds envelopePath sourcePath
  | ["doc-bench"] => docBench
  | ["doc-dump"] => docDump
  | ["security-bench"] => securityBench
  | [] =>
    testDigests
    testRules
    testSourceSecurityRules
    testSourceSecurityProperties
    testImports
    testEngineTiers
    testMixedSelection
    testServiceProtocol
    testEdits
    testFixAllAdversarial
    testConfig
    testApplicability
    testCacheIdentity
    testLosslessSource
    testStore
    testSemanticArtifact
    testDoc
    testComments
    testSuppression
    IO.println "lean-fmt module-artifact tests passed"
    return 0
  | ["verify-plugin-artifact", moduleName, sourcePath] =>
    verifyPluginArtifact moduleName.toName sourcePath
    IO.println "lean-fmt compiler payload verified"
    return 0
  | ["verify-facet-artifact", path, sourcePath, expectedHash] =>
    let some expectedHash := Lake.Hash.ofString? expectedHash
      | do
      IO.eprintln "EXPECTED_HASH must be a Lake content hash"
      return 2
    verifyFacetArtifact path sourcePath expectedHash
    IO.println "lean-fmt compiler artifact verified"
    return 0
  | ["print-lake-hash", path] =>
    IO.println (← Lake.computeFileHash path (text := true))
    return 0
  | ["verify-official-facet", root, sourcePath] =>
    verifyOfficialFacet root sourcePath
    IO.println "lean-fmt registered compiler facet verified"
    return 0
  | _ =>
    IO.eprintln "usage: lean-fmt-tests [verify-plugin-artifact MODULE SOURCE | \
      verify-facet-artifact ARTIFACT SOURCE EXPECTED_HASH | \
      verify-official-facet ROOT SOURCE | \
      attach-report ENVELOPE SOURCE | \
      doc-bench | \
      security-bench | \
      print-lake-hash ARTIFACT]"
    return 2
