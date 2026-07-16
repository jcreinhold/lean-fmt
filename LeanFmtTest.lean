module

import all LeanFmt

open LeanFmt LeanFmt.Internal

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

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | [] =>
    testDigests
    testRules
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
  | _ =>
    IO.eprintln "usage: lean-fmt-tests [verify-plugin-artifact MODULE SOURCE EXPECTED_TRAILING | \
      verify-facet-artifact ARTIFACT SOURCE EXPECTED_TRAILING EXPECTED_HASH | \
      print-lake-hash ARTIFACT]"
    return 2
