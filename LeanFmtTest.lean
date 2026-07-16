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

private def testRules : IO Unit := do
  let source := "def x := 1  \r\n#check x\t"
  let findings := runRules source true
  ensure (findings.map (·.code) == #["FMT001", "FMT001", "FMT002"])
    "rule ordering or coverage changed"
  ensure (findings[0]!.range == { start := 10, stop := 12 })
    "CRLF trailing-whitespace range is not byte-exact"
  ensure (findings[1]!.range == { start := 22, stop := 23 })
    "EOF trailing-whitespace range is not byte-exact"
  ensure (findings[2]!.range == { start := 23, stop := 23 })
    "final-newline insertion range is not byte-exact"
  ensure ((runRules source false).map (·.code) == #["FMT002"])
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

private def fixtureArtifact (source := "def x := 1\n") : ModuleArtifact := {
  schema := artifactSchema
  source := Digest.ofString source
  sourceBytes := source.utf8ByteSize
  mainModule := "Test"
  trailingWhitespace := true
  commands := #[{
    kind := "Lean.Parser.Command.declaration"
    range? := some { start := 0, stop := 10 }
  }]
  findings := #[]
}

private def testStore : IO Unit := do
  let artifact := fixtureArtifact
  ensure (structurallyValid artifact) "valid module artifact was rejected"
  ensure (!(structurallyValid { artifact with schema := "other-schema" }))
    "schema change did not reject the artifact"
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
    ensure ((← readFacet? facet `Test "def x := 1\n") == some artifact)
      "trusted facet artifact round trip failed"
    ensure (← readFacet? facet `Test "other source").isNone
      "source mismatch did not reject the facet artifact"
    IO.FS.writeFile path (Lean.toJson { artifact with schema := "other-schema" }).compress
    ensure (← readFacet? facet `Test "def x := 1\n").isNone
      "tampered facet artifact did not fail its content hash"
    writeArtifactAtomic path artifact
    IO.FS.writeFile (directory / "nested" / "Test.json.tmp-interrupted") "partial"
    ensure ((← readFacet? facet `Test "def x := 1\n") == some artifact)
      "an interrupted temporary write damaged the committed artifact"
    IO.FS.removeFile path
    ensure (← readFacet? facet `Test "def x := 1\n").isNone
      "missing facet artifact was not an ordinary miss"
  finally
    IO.FS.removeDirAll directory

private unsafe def verifyPluginArtifact (moduleName : Lean.Name)
    (sourcePath : System.FilePath) (expectedTrailingWhitespace : Bool) : IO Unit := do
  Lean.enableInitializersExecution
  Lean.initSearchPath (← Lean.findSysroot)
  let environment ← Lean.importModules #[{ module := moduleName }] {}
    (trustLevel := 1024) (loadExts := true) (level := .exported)
  let source ← IO.FS.readFile sourcePath
  let some artifact := fromEnvironment? environment moduleName
    | throw <| IO.userError "module has no matching lean-fmt payload in its `.olean`"
  ensure (artifact.source == Digest.ofString source) "plugin payload does not match the source"
  ensure (artifact.schema == artifactSchema) "plugin emitted the wrong schema"
  ensure (artifact.mainModule == "LocalSyntax") "plugin lost module identity"
  ensure (artifact.trailingWhitespace == expectedTrailingWhitespace)
    "plugin lost traced rule configuration"
  ensure (artifact.commands.any (·.kind == "commandEmit_local_command"))
    "plugin lost file-local command syntax"
  let expectedCodes := if expectedTrailingWhitespace then #["FMT001"] else #[]
  ensure (artifact.findings.map (·.code) == expectedCodes)
    "plugin rules differ from the configured direct rule engine"
  ensure ((Lean.toJson artifact).compress.utf8ByteSize < 4096) "plugin artifact is not compact"

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
  ensure (artifact.mainModule == "LocalSyntax") "facet artifact lost module identity"
  ensure (artifact.trailingWhitespace == expectedTrailingWhitespace)
    "facet artifact lost traced rule configuration"

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
  ensure (semantic == SemanticAnalysis.success target.source
      (runRules target.source true))
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
