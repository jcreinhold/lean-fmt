module

public import Test.Analyze
public import Test.Fixture
public import Test.Harness
public import Test.Json
public import Test.Proc

public import LeanFmt.ArtifactModel
public import LeanFmt.Imports

import all LeanFmt.ArtifactModel
import all LeanFmt.Imports

/-!
# The admission oracle for formatter candidates

Port of `tests/fixtures/formatter/oracle.py`: an independent admission protocol for a frontend-native Lean
formatter candidate. The candidate runs twice (idempotence), every response must carry the input's
identity and a source map tiling both regions, and the before/after exact-frontend artifacts must
agree on terminal bytes, comment payloads and ownership, token spellings, and tree shape. Gates are
named so suites can assert *which* gate a bad candidate trips.

The Python oracle shelled out to `lean-fmt-tests artifact-projection` and `formatter-header`; the
port computes both in-process from the same production functions (`ModuleArtifact.materialize`,
`Imports.parseHeaderModel`).
-/

open LeanFmt LeanFmt.Internal
open LeanFmt.Test

namespace LeanFmt.Test.Oracle

/-- A named gate rejection: the gate is the contract clause, the detail what violated it. -/
public structure GateFailure where
  gate : String
  detail : String
  deriving Repr

/-- Throw a gate failure. The encoding rides on `IO.userError` so the protocol's helpers can stay
in `IO`; `run` decodes it back into a `GateFailure`. The sentinel keeps the decode unambiguous. -/
private def reject (gate detail : String) : IO α :=
  throw <| IO.userError s!"oracle-gate\x00{gate}\x00{detail}"

/-- SHA-256 of in-memory bytes, lowercase hex, via the platform tool (stdin avoids a temp file;
the oracle digests candidate output, not only files). -/
private def digestBytes (bytes : String) : IO String := do
  let result ← runProc "shasum" #["-a", "256"] (input? := some bytes)
  ensure (result.exitCode == 0) s!"shasum failed: {result.stderr}"
  match result.stdout.splitOn " " with
  | hex :: _ => return hex
  | [] => throw <| IO.userError "shasum produced no digest"

/-- Byte-range slice: the protocol's offsets are byte offsets into the normalized source. -/
private def sliceOf (source : String) (start stop : Nat) : String :=
  String.Pos.Raw.extract source ⟨start⟩ ⟨stop⟩

private def jsonString? (json : Lean.Json) (field : String) : Option String :=
  (json.getObjValAs? String field).toOption

/-- One candidate invocation: stdin is the source, the environment pins the identity the candidate
must echo, and the response must be one JSON object with a string `formatted`. -/
private def invokeCandidate (candidateCmd : Array String) (source : String)
    (setupDigest : String) (passIndex : Nat) : IO Lean.Json := do
  let some cmd := candidateCmd[0]?
    | throw <| IO.userError "oracle: empty candidate command"
  let sourceDigest ← digestBytes source
  let result ← runProc cmd (candidateCmd.toSubarray 1).toArray (input? := some source)
    (env := #[("LEAN_FMT_EXPECTED_SOURCE_DIGEST", some sourceDigest),
      ("LEAN_FMT_EXPECTED_SETUP_DIGEST", some setupDigest),
      ("LEAN_FMT_FORMAT_PASS", some (toString passIndex))])
  if result.exitCode != 0 then
    reject "candidate" result.stderr.trimAscii.toString
  let .ok response := Lean.Json.parse result.stdout
    | reject "candidate" "candidate did not emit one JSON response"
  unless (jsonString? response "formatted").isSome do
    reject "candidate" "response has no string `formatted` field"
  return response

/-- The response must name the input it claims to have formatted: source bytes, module setup, no
cancellation, no unsupported report. -/
private def validateIdentity (response : Lean.Json) (source : String) (setupDigest : String) :
    IO Unit := do
  let sourceDigest ← digestBytes source
  unless jsonString? response "sourceDigest" == some sourceDigest do
    reject "stale-artifact" "candidate identity does not match the input bytes"
  unless jsonString? response "setupDigest" == some setupDigest do
    reject "environment" "candidate identity does not match the exact module setup"
  unless jsonAt? response [.field "cancelled"] == some (Lean.toJson false) do
    reject "cancellation" "a cancelled candidate reached admission"
  let some unsupported := (jsonAt? response [.field "unsupported"]).bind (·.getArr?.toOption)
    | reject "candidate" "`unsupported` is not an array"
  if let some first := unsupported[0]? then
    reject "unsupported" first.compress

/-- One exact start/stop range, as the source map spells it. -/
private def rangePair (value : Lean.Json) (label : String) : IO (Nat × Nat) := do
  let some start := Analyze.natAt? value [.field "start"]
    | reject "source-map" s!"invalid {label}: {value.compress}"
  let some stop := Analyze.natAt? value [.field "stop"]
    | reject "source-map" s!"invalid {label}: {value.compress}"
  let keys := (Lean.Json.getObj? value).toOption.map (·.foldl (fun acc k _ => acc ++ [k]) [])
  unless keys == some ["start", "stop"] do
    reject "source-map" s!"{label} is not an exact start/stop range"
  return (start, stop)

/-- The source map must tile the complete source and output: contiguous, gapless, cursor-matched. -/
private def validateSourceMap (response : Lean.Json) (source output : String) :
    IO (Array (Nat × Nat × Nat × Nat)) := do
  let some raw := (jsonAt? response [.field "sourceMap"]).bind (·.getArr?.toOption)
    | reject "source-map" "source map is absent or empty"
  if raw.isEmpty then
    reject "source-map" "source map is absent or empty"
  let mut units := #[]
  for item in raw do
    let (ss, se) ← rangePair (← do
        let some v := jsonAt? item [.field "source"] | reject "source-map" "unit has no source"
        pure v) "unit source"
    let (os, oe) ← rangePair (← do
        let some v := jsonAt? item [.field "output"] | reject "source-map" "unit has no output"
        pure v) "unit output"
    units := units.push (ss, se, os, oe)
  let mut sourceCursor := 0
  let mut outputCursor := 0
  for (ss, se, os, oe) in units do
    unless ss == sourceCursor && os == outputCursor do
      reject "source-map" "a unit overlaps or leaves a gap"
    sourceCursor := se
    outputCursor := oe
  unless sourceCursor == source.utf8ByteSize && outputCursor == output.utf8ByteSize do
    reject "source-map" "units do not tile the complete source and output"
  return units

/-- The exact frontend's artifact for `source`, with the materialized projection attached under
`source` — what the Python oracle got by shelling out to `artifact-projection`. -/
private def analyze (root : System.FilePath) (application : String) (setup : System.FilePath)
    (work : System.FilePath) (source : String) (label : String) : IO Lean.Json := do
  let path := work / s!"contract-{label}"
  writeFile path source
  let result ← runProc application
    #["__analyze-exact", setup.toString, path.toString, label] (cwd? := some root)
  if result.exitCode != 0 then
    reject "frontend" (if result.stderr.trimAscii.isEmpty then
      s!"exact analysis exited {result.exitCode}" else result.stderr.trimAscii.toString)
  let .ok envelope := Lean.Json.parse result.stdout
    | reject "frontend" "exact analysis did not emit one JSON envelope"
  let diagnostics := (jsonAt? envelope [.field "diagnostics"]).bind (·.getArr?.toOption)
  let some artifact := jsonAt? envelope [.field "artifact"]
    | reject "frontend" "exact analysis produced no artifact"
  if artifact.isNull || (diagnostics.map (·.size)).getD 0 > 0 then
    reject "frontend" ((diagnostics.map fun ds => ", ".intercalate (ds.toList.map (·.compress))).getD "diagnostics")
  let .ok (parsed : ModuleArtifact) := Lean.fromJson? artifact
    | reject "frontend" "artifact did not decode"
  let .ok materialized := parsed.materialize source
    | reject "frontend" "artifact reconstruction failed"
  return artifact.setObjVal! "source" (Lean.toJson materialized.source)

/-- The ordered parsed import signature, computed by the real parser — what the Python oracle got
from `formatter-header`. -/
private def headerSignature (source : String) : IO Lean.Json := do
  let normalized := (LosslessSource.normalize source).1
  let some header ← Imports.parseHeaderModel normalized
    | reject "imports" "header parser refused the candidate"
  let imports := header.imports.map fun stmt => Lean.Json.mkObj [
    ("module", .str stmt.module.toString),
    ("all", stmt.importAll),
    ("meta", stmt.isMeta),
    ("public", stmt.isPublic),
    ("exported", stmt.isExported)
  ]
  return Lean.Json.mkObj [
    ("module", header.hasModule),
    ("prelude", header.hasPrelude),
    ("imports", .arr imports)
  ]

/-- The normalized tree signature: `(kind, parent)` for every node, in order. -/
private def treeSignature (source : Lean.Json) : IO (Array Lean.Json) := do
  let some kinds := (jsonAt? source [.field "kinds"]).bind (·.getArr?.toOption)
    | throw <| IO.userError "oracle: projection has no kinds table"
  let some nodes := (jsonAt? source [.field "nodes"]).bind (·.getArr?.toOption)
    | throw <| IO.userError "oracle: projection has no node table"
  let mut signature := #[]
  for node in nodes do
    let some pair := node.getArr?.toOption
    | throw <| IO.userError "oracle: projection node is not an array"
    let kindName := ((pair[0]?).bind (Analyze.natAt? · [])).bind fun index => kinds[index]?
    signature := signature.push (Lean.Json.arr #[kindName.getD Lean.Json.null, pair[1]?.getD .null])
  return signature

/-- Split the projection into token spellings, comment payloads, and ownership records, walking
the raw bytes at the recorded boundaries — the same walk `checkProjection` does, read back for
comparison rather than validation. -/
private def splitProjection (projection : Lean.Json) (raw : String) :
    IO (Array (Nat × String) × Array (Nat × String) × Array Lean.Json) := do
  let some tokens := (jsonAt? projection [.field "tokens"]).bind (·.getArr?.toOption)
    | throw <| IO.userError "oracle: projection has no token table"
  let mut spellingTokens : Array (Nat × String) := #[]
  let mut comments : Array (Nat × String) := #[]
  let mut ownership : Array Lean.Json := #[]
  let mut cursor := 0
  for tokenIdx in [:tokens.size] do
    let some fields := tokens[tokenIdx]!.getArr?.toOption | continue
    let node := (fields[0]?).bind (Analyze.natAt? · []) |>.getD 0
    let start := (fields[1]?).bind (Analyze.natAt? · []) |>.getD 0
    let stop := (fields[2]?).bind (Analyze.natAt? · []) |>.getD 0
    for sideIdx in [4, 5] do
      let some runs := (fields[sideIdx]?).bind (·.getArr?.toOption) | continue
      for runIdx in [:runs.size] do
        let some pair := runs[runIdx]!.getArr?.toOption | continue
        let kind := (pair[0]?).bind (Analyze.natAt? · []) |>.getD 0
        let stop := (pair[1]?).bind (Analyze.natAt? · []) |>.getD cursor
        let payload := sliceOf raw cursor stop
        if kind != 0 then
          comments := comments.push (kind, payload)
          ownership := ownership.push (Lean.Json.arr #[
            Lean.toJson tokenIdx, Lean.toJson sideIdx, Lean.toJson runIdx, Lean.toJson kind,
            .str payload])
        cursor := stop
      if sideIdx == 4 then
        spellingTokens := spellingTokens.push (node, sliceOf raw start stop)
        cursor := stop
  return (spellingTokens, comments, ownership)

/-- The before/after artifact agreement: terminal bytes, comment payloads and ownership, token
spellings, and the normalized tree may not change under formatting. -/
private def compareArtifacts (before after : Lean.Json) (beforeRaw afterRaw : String) : IO Unit := do
  let some beforeSource := jsonAt? before [.field "source"]
    | throw <| IO.userError "oracle: before artifact lost its projection"
  let some afterSource := jsonAt? after [.field "source"]
    | throw <| IO.userError "oracle: after artifact lost its projection"
  let beforeStop := (Analyze.natAt? beforeSource [.field "terminalStop"]).getD 0
  let afterStop := (Analyze.natAt? afterSource [.field "terminalStop"]).getD 0
  let beforeTail := sliceOf beforeRaw beforeStop beforeRaw.utf8ByteSize
  let afterTail := sliceOf afterRaw afterStop afterRaw.utf8ByteSize
  unless beforeTail == afterTail do
    reject "terminal" s!"terminal/tail bytes changed: {repr beforeTail} -> {repr afterTail}"
  let (beforeTokens, beforeComments, beforeOwners) ← splitProjection beforeSource beforeRaw
  let (afterTokens, afterComments, afterOwners) ← splitProjection afterSource afterRaw
  let docPayloads (tokens : Array (Nat × String)) (comments : Array (Nat × String)) :
      Array (Nat × String) :=
    comments ++ tokens.filterMap fun (_, token) =>
      if token.startsWith "/--" then some (3, token) else none
  unless docPayloads beforeTokens beforeComments == docPayloads afterTokens afterComments do
    reject "comments-payload" "comment kind, order, count, or payload changed"
  unless beforeOwners == afterOwners do
    reject "comments-ownership" "a comment moved between leading/trailing token owners"
  let beforeSpellings := beforeTokens.map (·.2)
  let afterSpellings := afterTokens.map (·.2)
  unless beforeSpellings == afterSpellings do
    reject "tokens" "token count, order, or spelling changed"
  let beforeTree ← treeSignature beforeSource
  let afterTree ← treeSignature afterSource
  let beforeTokenNodes := beforeTokens.map fun (node, _) => Lean.toJson node
  let afterTokenNodes := afterTokens.map fun (node, _) => Lean.toJson node
  unless beforeTree == afterTree && beforeTokenNodes == afterTokenNodes do
    reject "structure" "normalized node kind/parent/child order or token ownership changed"

/-- The admission protocol, end to end. `sourcePath` supplies the bytes (CRLF-normalized, as the
Python did) and the label the analyzer sees; `candidateCmd` is the candidate's argv. Returns the
summary JSON on admission, or the failing gate. -/
public def run (root : System.FilePath) (application : String) (setup : System.FilePath)
    (work : System.FilePath) (sourcePath : System.FilePath) (candidateCmd : Array String) :
    IO (Except GateFailure Lean.Json) := do
  try
    let original := (← IO.FS.readFile sourcePath).crlfToLf
    let setupDigest ← digestBytes (← IO.FS.readFile setup)
    let first ← invokeCandidate candidateCmd original setupDigest 1
    validateIdentity first original setupDigest
    let formatted := (jsonString? first "formatted").getD ""
    let units ← validateSourceMap first original formatted
    let second ← invokeCandidate candidateCmd formatted setupDigest 2
    validateIdentity second formatted setupDigest
    discard <| validateSourceMap second formatted ((jsonString? second "formatted").getD "")
    let label := sourcePath.fileName.getD "candidate.lean"
    let before ← analyze root application setup work original label
    let after ← analyze root application setup work formatted label
    unless (← headerSignature original) == (← headerSignature formatted) do
      reject "imports" "ordered parsed import signature changed"
    compareArtifacts before after original formatted
    unless ((jsonString? second "formatted").getD "") == formatted do
      reject "idempotence" "the second pass changed bytes"
    let mut reflowed := 0
    for (ss, se, os, oe) in units do
      if sliceOf original ss se != sliceOf formatted os oe then
        reflowed := reflowed + 1
    let some beforeSource := jsonAt? before [.field "source"] | throw <| IO.userError "oracle"
    let nodes := ((jsonAt? beforeSource [.field "nodes"]).bind (·.getArr?.toOption)).map (·.size)
      |>.getD 0
    let (projectionTokens, projectionComments, _) ← splitProjection beforeSource original
    let docCount := projectionTokens.filter (·.2.startsWith "/--") |>.size
    -- Sorted keys, compact separators: the digest input is stable across runs.
    let summary := Lean.Json.mkObj [
      ("changed", Lean.toJson (if original == formatted then 0 else 1)),
      ("comments", Lean.toJson (projectionComments.size + docCount)),
      ("nodes", Lean.toJson nodes),
      ("outputBytes", Lean.toJson formatted.utf8ByteSize),
      ("reflowedUnits", Lean.toJson reflowed),
      ("sourceBytes", Lean.toJson original.utf8ByteSize),
      ("status", Lean.Json.str "ok"),
      ("tokens", Lean.toJson projectionTokens.size),
      ("unsupported", Lean.toJson (0 : Nat))
    ]
    let stable := summary.compress ++ "\x00" ++ formatted
    let digest ← digestBytes stable
    return .ok (summary.setObjVal! "digest" digest)
  catch error =>
    match (error.toString.splitOn "\x00") with
    | ["oracle-gate", gate, detail] => return .error ⟨gate, detail⟩
    | _ => throw error

end LeanFmt.Test.Oracle
