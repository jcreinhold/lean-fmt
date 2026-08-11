module

public import Test
public import Test.Projection

/-!
# The lossless suite

Round-trip and differential corpus for the lossless projection.

The corpus is this repository's own Lean modules. They are real, non-trivial, always present, and
they change as the project changes, which a frozen fixture cannot. Production `LeanFmt/*` modules
cannot carry the plugin without depending on themselves, so the exact frontend is the only path
for them; the check suite is what proves the two producers agree.

Every claim is re-derived by `Test.Projection`, which shares no code with the product and can
therefore contradict it. The mutation case is what makes that
non-vacuous.

Lane: parallel — generated fixtures live in the scratch dir; `lake setup-file` is Lake-cached.

Byte-exotic fixtures are generated rather than committed: git normalizes line endings, so a CRLF
fixture cannot survive as a file.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace Lossless

structure Ctx where
  root : System.FilePath
  application : String
  work : System.FilePath
  borrowedSetup : System.FilePath

/-- `__analyze-exact SETUP SOURCE DISPLAY` — no mode argument: the lossless claim is about the
projection, not any formatter draft. -/
private def project (ctx : Ctx) (setup source display : String) (label : String) : IO Lean.Json :=
  do
  let result ←
    expectExit 0 label ctx.application #["__analyze-exact", setup, source, display] (cwd? :=
        some ctx.root)
  parseJson result.stdout label

/-- One corpus module: analyzes clean, carries an artifact, and the independent oracle verifies
the projection against the file on disk. -/
private def testModule (ctx : Ctx) (moduleName : String) : IO Unit := do
  let setup ← setupFile ctx.root ctx.work moduleName
  let envelope ← project ctx setup.toString moduleName moduleName s!"lossless:{moduleName}"
  ensure (((jsonAt? envelope [.field "diagnostics"]).bind (·.getArr?.toOption)).getD #[]).isEmpty
      s!"{moduleName} did not analyze"
  ensure ((jsonAt? envelope [.field "artifact"]).isSome) s!"{moduleName} produced no artifact"
  discard <| LeanFmt.Test.Projection.checkEnvelope envelope (ctx.root / moduleName)

/-- One byte-exotic fixture, analyzed with the borrowed setup and oracle-checked. -/
private def exotic (ctx : Ctx) (name content : String) : IO Lean.Json := do
  let source := ctx.work / s!"{name}.lean"
  writeFile source content
  let envelope ←
    project ctx ctx.borrowedSetup.toString source.toString s!"{name}.lean" s!"exotic:{name}"
  discard <| LeanFmt.Test.Projection.checkEnvelope envelope source
  return envelope

/-- The exotic corpus: each is a case the projection's coordinate system or boundaries must
survive, and each was a real defect at some point. -/
private def testExotic (ctx : Ctx) : IO Unit := do
  -- CRLF: every compiler offset indexes `raw.crlfToLf`, so the oracle's digest of the *normalized*
  -- bytes must match while `raw_bytes` exceeds `normalized_bytes`.
  discard <| exotic ctx "crlf" "module\r\n\r\ndef crlfValue : Nat := 1\r\n-- a comment\r\n"
  -- `#exit` leaves a tail Lean never parses. `terminalStop` is where the token stream ends, so the
  -- tail must reconstruct verbatim rather than being claimed by a token that does not cover it.
  discard <|
      exotic ctx "exit" "module\n\ndef exitValue : Nat := 1\n#exit\nthis tail is never parsed {{{\n"
  -- The same, in CRLF, so the tail crosses the normalization boundary too.
  discard <|
      exotic ctx "exitcrlf"
        "module\r\n\r\ndef bothValue : Nat := 1\r\n#exit\r\nunparsed CRLF tail\r\n"
  -- No final newline: the last token's trailing trivia ends exactly at end of file.
  discard <| exotic ctx "nonewline" "module\n\ndef noFinalNewline : Nat := 1"
  -- Nothing but a header: the whole file is header, and the token stream is empty.
  discard <| exotic ctx "headeronly" "module\n"
  -- Trailing trivia is greedy up to the next token's text, so comments after the last command are
  -- absorbed by its trailing rather than stranded before `eoi`.
  discard <|
      exotic ctx "eofcomments"
        "module\n\ndef beforeComments : Nat := 1\n\n-- after the last command\n/- and a block -/\n"
  -- Multi-byte UTF-8 must be counted in bytes, not codepoints, everywhere.
  discard <| exotic ctx "unicode" "module\n\ndef «π ≤ τ» : String := \"λ → ∀ 🎉\"\n-- ∀ε>0 ∃δ>0\n"
  -- A `choice` node holds several parses of one byte range; only one may spell those bytes.
  let choiceEnvelope ←
    exotic ctx "choice"
        "module\n\nstructure P where\n  a : Nat\n  b : Nat\n\ndef mk (a b : Nat) : P := { a, b }\n"
  let some kinds :=
    ((((jsonAt? choiceEnvelope [.field "artifact", .field "syntaxData", .field "kinds"]).bind
              (·.getArr?.toOption)).getD
          #[]).mapM
      (·.getStr?.toOption))
    | throw <| IO.userError "choice: kinds are not strings"
  ensure (kinds.contains "choice") "the ambiguous parse produced no choice node; case is vacuous"

/-! ## Mutation machinery

The oracle must be able to fail. Each mutation is a lie a corrupt or buggy producer could tell,
and a validator that accepts any of them proves nothing about the ones it accepted above. The
tiling mutations are the load-bearing ones: `ModuleSyntax.structurallyValid` accepts every one of
them -- it checks that roots are contiguous in the entry array and that command ranges lie in the
file, and never that one leaf's `trailingStop` is the next leaf's `leadingStart`. -/

private def fail {α} (message : String) : IO α :=
  throw <| IO.userError message

private def syntaxOf (artifact : Lean.Json) : Lean.Json :=
  (artifact.getObjVal? "syntaxData").toOption.getD .null

private def mapSyntax (artifact : Lean.Json) (edit : Lean.Json → Lean.Json) : Lean.Json :=
  artifact.setObjVal! "syntaxData" (edit (syntaxOf artifact))

private def entriesOf (projection : Lean.Json) : Array Lean.Json :=
  (projection.getObjVal? "entries").toOption |>.bind (·.getArr?.toOption) |>.getD #[]

private def setEntries (projection : Lean.Json) (entries : Array Lean.Json) : Lean.Json :=
  projection.setObjVal! "entries" (.arr entries)

private def kindsOf (projection : Lean.Json) : Array String :=
  (((projection.getObjVal? "kinds").toOption |>.bind (·.getArr?.toOption)).getD #[]).filterMap
    (·.getStr?.toOption)

private def mapCommands (projection : Lean.Json) (edit : Array Lean.Json → Array Lean.Json) :
    Lean.Json :=
  let commands :=
    (projection.getObjVal? "commands").toOption |>.bind (·.getArr?.toOption) |>.getD #[]
  projection.setObjVal! "commands" (.arr (edit commands))

private def jsonNat (json : Lean.Json) (label : String) : IO Nat :=
  match json with
  | .num n => return n.mantissa.toNat
  | _ => fail s!"{label}: not a natural number"

/-- `entry[1][field] += delta` — shift one original-info field of one leaf entry. -/
private def shiftInfoField (entry : Lean.Json) (field : Nat) (delta : Int) : Lean.Json :=
  match entry with
  | .arr items =>
    match items[1]? with
    | some rawInfo =>
      match rawInfo with
      | .arr info =>
        let shifted :=
          info.modify field fun value =>
            match value with
            | .num n => .num { mantissa := n.mantissa + delta, exponent := n.exponent }
            | other => other
        .arr (items.set! 1 (.arr shifted))
      | _ => entry
    | _ => entry
  | other => other

/-- Array positions of the original-info leaves, in pre-order (which is array order). -/
private def leafPositions (entries : Array Lean.Json) : IO (Array Nat) := do
  let mut found := #[]
  for index in [0:entries.size] do
    match entries[index]! with
    | .arr items =>
      let tag :=
        items[0]? |>.bind fun value =>
          match value with
          | .num n => some n.mantissa
          | _ => none
      if tag == some 2 || tag == some 3 then
        if
            items[1]?.map
                (fun info =>
                  match info with
                  | .arr _ => true
                  | _ => false) |>.getD
              false then
          found := found.push index
    | _ =>
      pure ()
  if found.size < 4 then
    fail s!"the mutation base has only {found.size} leaves"
  return found

/-- The first leaf that owns trailing trivia. Shrinking one of those opens a hole; shrinking a
leaf with none would instead invert `endPosition <= trailingStop` and be caught as bad order,
which is a different claim than the one this mutation means to test. -/
private def trailingLeaf (entries : Array Lean.Json) : IO Nat := do
  for index in ← leafPositions entries do
    match entries[index]! with
    | .arr items =>
      match items[1]? with
      | some rawInfo =>
        match rawInfo with
        | .arr info =>
          let stop :=
            info[4]? |>.bind fun value =>
              match value with
              | .num n => some n.mantissa
              | _ => none
          let endPos :=
            info[3]? |>.bind fun value =>
              match value with
              | .num n => some n.mantissa
              | _ => none
          match stop, endPos with
          | some trailingStop, some endPosition =>
            if trailingStop > endPosition then
              return index
          | _, _ =>
            pure ()
        | _ =>
          pure ()
      | none =>
        pure ()
    | _ =>
      pure ()
  fail "no leaf in the mutation base owns trailing trivia"

/-- Return `(nextIndex, leaf entry positions)` for the subtree rooted at `index`. -/
private partial def subtreeLeaves (entries : Array Lean.Json) (index : Nat) :
    IO (Nat × Array Nat) := do
  let some entry := entries[index]? | fail s!"subtree index {index} of {entries.size}"
  match entry with
  | .arr items =>
    let tag :=
      items[0]? |>.bind fun value =>
        match value with
        | .num n => some n.mantissa.toNat
        | _ => none
    match tag with
    | some 0 =>
      return (index + 1, #[])
    | some 1 =>
      let some childCount :=
        items[3]? |>.bind fun value =>
          match value with
          | .num n => some n.mantissa.toNat
          | _ => none
        | fail "node without child count"
      let mut cursor := index + 1
      let mut found := #[]
      for _ in [0:childCount] do
        let (next, child) ← subtreeLeaves entries cursor
        cursor := next
        found := found ++ child
      return (cursor, found)
    | some _ =>
      return (index + 1, #[index])
    | none =>
      fail s!"entry {index} has no tag"
  | _ =>
    fail s!"entry {index} is malformed"

/-- Entry positions of the leaves under the second alternative of the first choice node. -/
private partial def choiceAlternative (entries : Array Lean.Json) (kinds : Array String) :
    IO (Array Nat) := do
  for index in [0:entries.size] do
    match entries[index]! with
    | .arr items =>
      let tag :=
        items[0]? |>.bind fun value =>
          match value with
          | .num n => some n.mantissa
          | _ => none
      if tag == some 1 then
        let kindIndex :=
          items[2]? |>.bind fun value =>
            match value with
            | .num n => some n.mantissa.toNat
            | _ => none
        if kindIndex.bind (kinds[·]?) == some "choice" then
          let some childCount :=
            items[3]? |>.bind fun value =>
              match value with
              | .num n => some n.mantissa.toNat
              | _ => none
            | fail "choice node without child count"
          let mut cursor := index + 1
          let mut alternatives := #[]
          for _ in [0:childCount] do
            let (next, child) ← subtreeLeaves entries cursor
            cursor := next
            alternatives := alternatives.push child
          if alternatives.size < 2 then
            fail "the choice node has one alternative; case is vacuous"
          if alternatives[1]!.isEmpty then
            fail "the choice node's second alternative holds no leaf"
          return alternatives[1]!
    | _ =>
      pure ()
  fail "no choice node in the choice fixture"

/-- Run the oracle expecting rejection; return the rejection for the report. An accepted mutation
is the failure. -/
private def expectRejection (name : String) (check : IO LeanFmt.Test.Projection.Measurements) :
    IO String := do
  let outcome ←
    try
      discard check
      pure (none : Option String)
    catch error =>
      pure (some (toString error))
  match outcome with
  | none =>
    fail s!"the oracle accepted a {name} mutation; it has no teeth"
  | some message =>
    return s!"{name}: {message}"

/-- The mutation battery over the unicode base and the choice fixture. -/
private def testMutations (ctx : Ctx) : IO Unit := do
  let unicodeSource := ctx.work / "unicode.lean"
  let baseEnvelope ←
    project ctx ctx.borrowedSetup.toString unicodeSource.toString "unicode.lean" "mutate-base"
  let some base := jsonAt? baseEnvelope [.field "artifact"]
    | fail "mutation base has no artifact"
  let choiceSource := ctx.work / "choice.lean"
  let choiceEnvelope ←
    project ctx ctx.borrowedSetup.toString choiceSource.toString "choice.lean" "mutate-choice"
  let some choiceBase := jsonAt? choiceEnvelope [.field "artifact"]
    | fail "choice mutation base has no artifact"
  -- `s` is the artifact; `x` its projection. Identity lives on the artifact, structure on the
  -- projection, and the tiling claims live on individual leaves.
  let checks : Array (String × (Lean.Json → IO Lean.Json)) :=
    #[
      -- Identity: the artifact must be about the file the consumer holds, not another one.
      ("wrong digest", fun artifact =>
        pure <|
          artifact.setObjVal! "normalizedDigest"
            (Lean.toJson (String.ofList (List.replicate 64 '0')))),
      ("wrong length", fun artifact => do
        let bytes ←
          jsonNat ((artifact.getObjVal? "normalizedBytes").toOption.getD .null) "normalizedBytes"
        pure <| artifact.setObjVal! "normalizedBytes" (Lean.toJson (bytes + 1))),
      ("stale schema", fun artifact =>
        pure <| artifact.setObjVal! "schema" (Lean.toJson "lean-fmt.module-artifact.v0")),
      ("carries findings", fun artifact => pure <| artifact.setObjVal! "findings" (.arr #[])),
      -- Roots: the command array must be a concatenation of whole trees with nothing between them.
      ("non-contiguous root", fun artifact =>
        pure <|
          mapSyntax artifact fun projection =>
            mapCommands projection (·.modify 0 (·.setObjVal! "entry" (Lean.toJson (1 : Nat))))),
      ("command range past end", fun artifact =>
        pure <|
          mapSyntax artifact fun projection =>
            mapCommands projection
              (·.modify 0 fun command =>
                match (command.getObjVal? "range").toOption with
                | some range =>
                  let stop :=
                    ((range.getObjVal? "stop").toOption |>.bind fun value =>
                          match value with
                          | .num n => some n.mantissa.toNat
                          | _ => none).getD
                      0
                  command.setObjVal! "range"
                    (range.setObjVal! "stop" (Lean.toJson (stop + 1000000000)))
                | none => command)),
      ("terminal misplaced", fun artifact =>
        let projection := syntaxOf artifact
        let terminal :=
          ((projection.getObjVal? "terminal").toOption |>.bind fun value =>
                match value with
                | .num n => some n.mantissa.toNat
                | _ => none).getD
            0
        pure <| mapSyntax artifact (·.setObjVal! "terminal" (Lean.toJson (terminal + 1)))),
      ("truncated entries", fun artifact =>
        pure <|
          mapSyntax artifact fun projection => setEntries projection (entriesOf projection).pop),
      ("trailing entry", fun artifact =>
        pure <|
          mapSyntax artifact fun projection =>
            setEntries projection ((entriesOf projection).push (.arr #[Lean.toJson (0 : Nat)]))),
      -- Tiling: a hole, an overlap, and a dropped leaf are all silent losses of source, and all
      -- three are invisible to `structurallyValid`.
      ("dropped leaf", fun artifact => do
        let entries := entriesOf (syntaxOf artifact)
        let position := (← leafPositions entries)[2]!
        pure <|
            mapSyntax artifact fun projection =>
              setEntries projection (entries.set! position (.arr #[Lean.toJson (0 : Nat)]))),
      ("hole after leaf", fun artifact => do
        let entries := entriesOf (syntaxOf artifact)
        let position ← trailingLeaf entries
        pure <|
            mapSyntax artifact fun projection =>
              setEntries projection (entries.modify position (shiftInfoField · 4 (-1)))),
      ("overlapping leaf", fun artifact => do
        let entries := entriesOf (syntaxOf artifact)
        let position ← trailingLeaf entries
        pure <|
            mapSyntax artifact fun projection =>
              setEntries projection (entries.modify position (shiftInfoField · 4 1))),
      ("leaf past end", fun artifact => do
        let entries := entriesOf (syntaxOf artifact)
        let positions ← leafPositions entries
        let position := positions.back!
        pure <|
            mapSyntax artifact fun projection =>
              setEntries projection (entries.modify position (shiftInfoField · 4 1000000))),
      ("inverted leaf", fun artifact => do
        let entries := entriesOf (syntaxOf artifact)
        let position := (← leafPositions entries)[2]!
        pure <|
            mapSyntax artifact fun projection =>
              setEntries projection (entries.modify position (shiftInfoField · 2 1000000000))),
      -- Provenance: a fabricated position is not a projection of anything.
      ("synthetic leaf", fun artifact => do
        let entries := entriesOf (syntaxOf artifact)
        let position := (← leafPositions entries)[2]!
        match entries[position]! with
        | .arr items =>
          match items[1]? with
          | some rawInfo =>
            match rawInfo with
            | .arr info =>
              let positionField := info[2]?.getD .null
              let endField := info[3]?.getD .null
              let synthetic : Lean.Json :=
                .arr #[Lean.toJson (2 : Nat), positionField, endField, Lean.toJson true]
              pure <|
                  mapSyntax artifact fun projection =>
                    setEntries projection (entries.set! position (.arr (items.set! 1 synthetic)))
            | _ =>
              fail "synthetic leaf: no info"
          | none =>
            fail "synthetic leaf: no info"
        | _ =>
          fail "synthetic leaf: malformed entry"),
      -- Dangling references.
      ("bad kind ref", fun artifact =>
        let projection := syntaxOf artifact
        let entries := entriesOf projection
        pure <|
          mapSyntax artifact fun x =>
            setEntries x
              (entries.modify 0 fun entry =>
                match entry with
                | .arr items => .arr (items.set! 2 (Lean.toJson (kindsOf x).size))
                | other => other))]
  let mut rejected := 0
  for (name, edit) in checks do
    let mutated ← edit base
    let message ←
      expectRejection name <| LeanFmt.Test.Projection.checkArtifact mutated unicodeSource
    IO.println s!"   rejected {message}"
    rejected := rejected + 1
  -- `choice` alternatives all spell one byte range. Four walks in `NativeLayout.lean` take
  -- `children[0]`; `NativeLayout.command` gates them by comparing every alternative's terminal
  -- sequence, and this oracle checks the same property independently of that gate -- so it must
  -- be able to see them disagree.
  let choiceEntries := entriesOf (syntaxOf choiceBase)
  let alternative ← choiceAlternative choiceEntries (kindsOf (syntaxOf choiceBase))
  let some firstLeaf := alternative[0]? | fail "choice alternative holds no leaf"
  -- `trailingStop`, so the span the oracle compares differs while the info stays well ordered and
  -- the failure is attributable to disagreement rather than to a malformed leaf.
  let disagreement :=
    mapSyntax choiceBase fun projection =>
      setEntries projection (choiceEntries.modify firstLeaf (shiftInfoField · 4 1))
  let message ←
    expectRejection "choice disagreement" <|
        LeanFmt.Test.Projection.checkArtifact disagreement choiceSource
  IO.println s!"   rejected {message}"
  rejected := rejected + 1
  IO.println s!"the oracle rejected all {rejected} mutations"

end Lossless

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  withScratchDir "lossless" fun work => do
      -- `__analyze-exact SETUP SOURCE DISPLAY` takes the source path separately from the setup, so a
      -- generated file can borrow a declared module's setup.
      let borrowedSetup ← setupFile root work "tests/fixtures/check/Clean.lean"
      let ctx : Lossless.Ctx :=
        { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, work
          borrowedSetup }
      -- The repository's own modules, sorted (byte order, like `LC_ALL=C sort`) so a regression
      -- surfaces on the small ones first.
      let mut modules := #[]
      for entry in ← (root / "LeanFmt").walkDir do
        if entry.extension == some "lean" then
          -- Repo-relative: `lake setup-file` wants the relative path, and the corpus case name
          -- is the same string.
          let absolute := entry.toString
          modules :=
            modules.push
              (String.Pos.Raw.extract absolute ⟨root.toString.utf8ByteSize + 1⟩
                ⟨absolute.utf8ByteSize⟩)
      modules := modules.qsort (· < ·)
      -- `Main.lean` is the only module outside `LeanFmt/` left to project.
      let extras := #["Main.lean"]
      let corpus :=
        (modules ++ extras).map fun moduleName =>
          let caseName := "corpus:" ++ moduleName
          ({ name := caseName, run := Lossless.testModule ctx moduleName } : Case)
      let cases :=
        corpus ++
          #[{ name := "exotic", run := Lossless.testExotic ctx },
            { name := "mutations", run := Lossless.testMutations ctx }]
      runCases "lossless" cases args
