module

import all LeanFmt.ArtifactStore
import all LeanFmt.Application
import all LeanFmt.Cache
import all LeanFmt.Config
import all LeanFmt.Edit
import all LeanFmt.Rules
import all LeanFmt.Service

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

  let findings := runRules normalized true
  ensure (findings.map (·.code) == #["FMT001", "FMT001", "FMT002"])
    "rule ordering or coverage changed"
  ensure (findings[0]!.range == { start := 10, stop := 12 })
    "trailing-whitespace range is not byte-exact in normalized coordinates"
  ensure (findings[1]!.range == { start := 21, stop := 22 })
    "EOF trailing-whitespace range is not byte-exact"
  ensure (findings[2]!.range == { start := 22, stop := 22 })
    "final-newline insertion range is not byte-exact"
  ensure ((runRules normalized false).map (·.code) == #["FMT002"])
    "traced trailing-whitespace configuration was ignored"

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

private def findingWithEdit (range : SourceRange) (replacement : String) : Finding := {
  code := "TEST"
  severity := .warning
  message := "test edit"
  range
  fix? := some { range, replacement }
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
  let patch ← requirePatch source (runRules source)
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
    let findings := runRules "def x := 1  "
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
    IO.FS.writeFile configPath "unknown = true\n"
    let rejected ← try
      discard <| FormatterConfig.load directory
      pure false
    catch _ => pure true
    ensure rejected "unknown configuration key was accepted"
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

private def fixtureArtifact : ModuleArtifact := {
  schema := artifactSchema
  trailingWhitespace := true
  source := fixtureLosslessSource
  findings := #[]
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
  let outOfRange : Finding := {
    code := "FMT001"
    severity := .warning
    message := "past the end"
    range := { start := 0, stop := artifact.source.normalizedBytes + 1 }
  }
  ensure (!(structurallyValid { artifact with findings := #[outOfRange] }))
    "a finding past the end of the projected source was accepted"
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
    (sourcePath : System.FilePath) (expectedTrailingWhitespace : Bool) : IO Unit := do
  Lean.enableInitializersExecution
  Lean.initSearchPath (← Lean.findSysroot)
  let environment ← Lean.importModules #[{ module := moduleName }] {}
    (trustLevel := 1024) (loadExts := true) (level := .exported)
  let source ← IO.FS.readFile sourcePath
  let some artifact := fromEnvironment? environment moduleName
    | throw <| IO.userError "module has no matching lean-fmt payload in its `.olean`"
  ensure (artifact.validFor moduleName source) "plugin payload does not match the source"
  ensure (artifact.schema == artifactSchema) "plugin emitted the wrong schema"
  ensure (artifact.trailingWhitespace == expectedTrailingWhitespace)
    "plugin lost traced rule configuration"
  ensure (artifact.source.kinds.contains "commandEmit_local_command")
    "plugin lost file-local command syntax"
  -- The fixture's `{ first, second }` parses two ways over one byte range. `checkProjection` is
  -- what proves only one alternative spells those bytes; this proves the case is not vacuous.
  ensure (artifact.source.kinds.contains "choice")
    "the fixture's ambiguous parse produced no choice node"
  checkProjection artifact.source source
  let expectedCodes := if expectedTrailingWhitespace then #["FMT001"] else #[]
  ensure (artifact.findings.map (·.code) == expectedCodes)
    "plugin rules differ from the configured direct rule engine"
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
    (expectedTrailingWhitespace : Bool) (expectedHash : Lake.Hash) : IO Unit := do
  let source ← IO.FS.readFile sourcePath
  let facet : Lake.Artifact := {
    descr := Lake.artifactWithExt expectedHash "json"
    path
    mtime := 0
  }
  let some artifact ← readFacet? facet `LocalSyntax source
    | throw <| IO.userError "facet artifact failed integrity or semantic validation"
  ensure (artifact.source.mainModule == "LocalSyntax") "facet artifact lost module identity"
  ensure (artifact.trailingWhitespace == expectedTrailingWhitespace)
    "facet artifact lost traced rule configuration"
  checkProjection artifact.source source

private def verifyOfficialFacet (root sourcePath : System.FilePath)
    (expectedTrailingWhitespace : Bool) : IO Unit := do
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
  ensure (artifact.trailingWhitespace == expectedTrailingWhitespace)
    "registered official facet lost traced rule configuration"
  let some semantic := SemanticAnalysis.ofEnvelope? target.source { artifact? := some artifact }
    | throw <| IO.userError "registered official facet did not produce a canonical result"
  let normalized := (LosslessSource.normalize target.source).1
  ensure (semantic == SemanticAnalysis.success normalized
      (runRules normalized expectedTrailingWhitespace))
    "registered official facet differed from direct product semantics"

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | [] =>
    testDigests
    testRules
    testServiceProtocol
    testEdits
    testConfig
    testCacheIdentity
    testLosslessSource
    testStore
    IO.println "lean-fmt module-artifact tests passed"
    return 0
  | ["verify-plugin-artifact", moduleName, sourcePath, expected] =>
    let some expected := if expected == "true" then some true else if expected == "false" then some false else none
      | do
      IO.eprintln "EXPECTED_TRAILING must be true or false"
      return 2
    verifyPluginArtifact moduleName.toName sourcePath expected
    IO.println "lean-fmt compiler payload verified"
    return 0
  | ["verify-facet-artifact", path, sourcePath, expected, expectedHash] =>
    let some expected := if expected == "true" then some true else if expected == "false" then some false else none
      | do
      IO.eprintln "EXPECTED_TRAILING must be true or false"
      return 2
    let some expectedHash := Lake.Hash.ofString? expectedHash
      | do
      IO.eprintln "EXPECTED_HASH must be a Lake content hash"
      return 2
    verifyFacetArtifact path sourcePath expected expectedHash
    IO.println "lean-fmt compiler artifact verified"
    return 0
  | ["print-lake-hash", path] =>
    IO.println (← Lake.computeFileHash path (text := true))
    return 0
  | ["verify-official-facet", root, sourcePath, expected] =>
    let some expected := if expected == "true" then some true else if expected == "false" then some false else none
      | do
      IO.eprintln "EXPECTED_TRAILING must be true or false"
      return 2
    verifyOfficialFacet root sourcePath expected
    IO.println "lean-fmt registered compiler facet verified"
    return 0
  | _ =>
    IO.eprintln "usage: lean-fmt-tests [verify-plugin-artifact MODULE SOURCE EXPECTED_TRAILING | \
      verify-facet-artifact ARTIFACT SOURCE EXPECTED_TRAILING EXPECTED_HASH | \
      verify-official-facet ROOT SOURCE EXPECTED_TRAILING | \
      print-lake-hash ARTIFACT]"
    return 2
