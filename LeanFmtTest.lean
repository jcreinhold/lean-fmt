module

import all LeanFmt.ArtifactStore
import all LeanFmt.Application
import all LeanFmt.Cache
import all LeanFmt.Comments
import all LeanFmt.Config
import all LeanFmt.Doc
import all LeanFmt.Edit
import all LeanFmt.Printer
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
    for width in [0, 1, 40, 80, 120, 1000] do
      let formatted ← Printer.format projection normalized width
      ensure (formatted == normalized)
        s!"{sourcePath}: format changed bytes at width {width} \
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
  let (tacticBlocks, tacticOwnable) := tree.tacticBlocks normalized
  IO.println s!"commands={tree.roots.size} canonical={tree.canonicalCommands normalized} \
tokens={projection.tokens.size} nodes={projection.nodes.size} header_bytes={projection.headerStop} \
header_canonical={headerCanonical} members={tree.memberShells normalized} \
app_slack={tree.appSlack normalized} \
binder_slack={tree.binderSlack normalized} \
match_slack={tree.matchSlack normalized} \
tactic_blocks={tacticBlocks} tactic_ownable={tacticOwnable} \
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
  IO.print (← Printer.format projection normalized width)
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
  | ["printer-unclaimed", envelopePath, sourcePath] => printerUnclaimed envelopePath sourcePath
  | ["printer-node-kinds", envelopePath, sourcePath] => printerNodeKinds envelopePath sourcePath
  | ["doc-bench"] => docBench
  | ["doc-dump"] => docDump
  | [] =>
    testDigests
    testRules
    testServiceProtocol
    testEdits
    testConfig
    testCacheIdentity
    testLosslessSource
    testStore
    testDoc
    testComments
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
      attach-report ENVELOPE SOURCE | \
      doc-bench | \
      print-lake-hash ARTIFACT]"
    return 2
