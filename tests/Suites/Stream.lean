module

public import Test

/-!
# The stream suite

Port of `tests/stream/run.sh`: the stdin/stdout and range
surface. Every case drives the real executable through a pipe, because the thing under test *is*
the pipe behavior: what reaches stdout, what reaches stderr, what the exit code is, and what is
NOT written. The frozen contract is the range-formatting section of `LeanFmt/Application.lean`;
section numbers below refer to it.

Lane: workspace+slow — the suite removes the root `.lean-fmt-cache`, and the broken-pipe case
elaborates a 6,000-definition buffer.
-/

open LeanFmt.Test

namespace Stream

structure Ctx where
  root : System.FilePath
  app : String
  work : System.FilePath
  identity : String := "tests/stream/Unsaved.lean"

private def fmt (ctx : Ctx) (args : Array String) (input : System.FilePath) : IO ProcResult := do
  runProc ctx.app args (cwd? := some ctx.root)
    (input? := some (← IO.FS.readFile input)) (timeoutMs := some 600000)

/-- First stderr line — the old script's `2>&1 >/dev/null | head -1`. -/
private def firstErr (result : ProcResult) : String :=
  ((result.stderr.splitOn "\n").filter (· != "")).head?.getD ""

private def lastErr (result : ProcResult) : String :=
  ((result.stderr.splitOn "\n").filter (· != "")).reverse.head?.getD ""

/-- §2 usage rejections: every malformed combination names what the caller typed. -/
private def testUsageRejections (ctx : Ctx) (dirty : System.FilePath) : IO Unit := do
  let check (label : String) (args : List String) (expected : String) (code : UInt32 := 2) : IO Unit := do
    let result ← fmt ctx args.toArray dirty
    ensureEq label expected (firstErr result)
    ensureEq s!"{label}: exit" code result.exitCode
  check "- without --stdin-filename is rejected" ["format", "-"]
    "stdin requires --stdin-filename to establish project identity"
  check "--stdin-filename without - is rejected" ["format", "--stdin-filename", ctx.identity]
    "--stdin-filename is valid only with the - stdin target"
  check "--range without - is rejected" ["format", "--range", "0:10"]
    "--range is valid only with the - stdin target"
  check "--range-lines names the flag the caller typed" ["format", "--range-lines", "1:1-2:1"]
    "--range-lines is valid only with the - stdin target"
  check "- alongside another target is rejected"
    ["format", "-", "--stdin-filename", ctx.identity, "other.lean"] "- must be the only target"
  check "a malformed --range is rejected"
    ["format", "-", "--stdin-filename", ctx.identity, "--range", "bogus"]
    "--range expects START:STOP byte offsets, got: bogus"
  check "a reversed --range is rejected"
    ["format", "-", "--stdin-filename", ctx.identity, "--range", "40:10"]
    "--range start 40 is past its stop 10"
  check "a --range past the end is rejected"
    ["format", "-", "--stdin-filename", ctx.identity, "--range", "0:99999"]
    "--range stop 99999 is past the end of the received source (78 bytes)"

/-- §2 identity gates, naming the caller's own argument. Gate 1 (`.lake`) is not liftable by the
stdin form any more than by a file argument. -/
private def testIdentityGates (ctx : Ctx) (dirty : System.FilePath) : IO Unit := do
  let check (label identity expected : String) : IO Unit := do
    let result ← fmt ctx #["format", "-", "--stdin-filename", identity] dirty
    ensureEq label expected (firstErr result)
  check "a path outside the root is rejected" "../evil.lean"
    "lean-fmt: selected file is outside the project root: ../evil.lean"
  check "a path inside .lake is rejected" ".lake/build/x.lean"
    "lean-fmt: selected file is inside the Lake build directory: .lake/build/x.lean"
  check "a non-Lean path is rejected" "notes.txt"
    "lean-fmt: selected file is not a Lean source: notes.txt"

/-- §7 format streams, and writes nothing — including no persistent cache entry. -/
private def testFormatStreams (ctx : Ctx) (dirty : System.FilePath) : IO Unit := do
  let formatted ← expectExit 0 "format -" ctx.app
    #["format", "-", "--stdin-filename", ctx.identity]
    (input? := some (← IO.FS.readFile dirty)) (cwd? := some ctx.root)
  ensure (formatted.stdout.contains "namespace Alpha") "format did not canonicalize the buffer"
  -- Naming a real file must not write it, and no run may leave a cache entry behind.
  let witness := ctx.root / "tests" / "fixtures" / "check" / "Layout.lean"
  removeDirAll? (ctx.root / ".lean-fmt-cache")
  let before ← sha256 witness
  discard <| expectExit 0 "format - naming a real file" ctx.app
    #["format", "-", "--stdin-filename", "tests/fixtures/check/Layout.lean"]
    (input? := some (← IO.FS.readFile dirty)) (cwd? := some ctx.root)
  ensureEq "naming an existing file wrote it" before (← sha256 witness)
  ensure (!(← (ctx.root / ".lean-fmt-cache").pathExists))
    "a stdin run created a persistent cache directory"

/-- §6 the other modes. -/
private def testOtherModes (ctx : Ctx) (dirty : System.FilePath) : IO Unit := do
  let source ← IO.FS.readFile dirty
  let check ← expectExit 0 "check -" ctx.app #["check", "-", "--stdin-filename", ctx.identity]
    (input? := some source) (cwd? := some ctx.root)
  ensureEq "check - is not silent on stdout" 0 check.stdout.length
  let diff ← expectExit 1 "diff -" ctx.app #["diff", "-", "--stdin-filename", ctx.identity]
    (input? := some source) (cwd? := some ctx.root)
  ensureEq "diff - emits a unified diff" s!"--- a/{ctx.identity}"
    ((diff.stdout.splitOn "\n").head?.getD "")
  let formatCheck ← expectExit 1 "format --check -" ctx.app
    #["format", "--check", "-", "--stdin-filename", ctx.identity, "--check"]
    (input? := some source) (cwd? := some ctx.root)
  ensureEq "format --check - is not silent on stdout" 0 formatCheck.stdout.length

/-- A buffer that does not elaborate streams NOTHING — not partial bytes, not the input echoed
back. Echoing would let a shell redirect write a broken buffer over a good file. -/
private def testBrokenBuffer (ctx : Ctx) : IO Unit := do
  let broken := ctx.work / "broken.lean"
  writeFile broken "module\n\ndef x : Nat := \"not a nat\"\n"
  let result ← fmt ctx #["format", "-", "--stdin-filename", ctx.identity] broken
  ensureEq "a broken buffer streams bytes" 0 result.stdout.length
  ensureEq "a broken buffer's exit" 1 result.exitCode
  ensure (result.stderr.contains "broken") "a broken buffer does not say why on stderr"

/-- §4 range expansion: the reported actual range is the unit, not the request; whole-file and
full-range are the same bytes; idempotence holds in output coordinates, which is the only place
it can. -/
private def testRangeExpansion (ctx : Ctx) (dirty : System.FilePath) : IO Unit := do
  let source ← IO.FS.readFile dirty
  let stream (args : Array String) (input : String := source) : IO ProcResult :=
    runProc ctx.app (#["format", "-", "--stdin-filename", ctx.identity] ++ args)
      (input? := some input) (cwd? := some ctx.root)
  let ranged ← expectExit 0 "range" (ctx.app)
    (#["format", "-", "--stdin-filename", ctx.identity, "--range", "30:49"])
    (input? := some source) (cwd? := some ctx.root)
  ensureEq "a range formats its own unit" "namespace Alpha"
    ((ranged.stdout.splitOn "\n")[4]?.getD "<missing>")
  ensure (ranged.stdout.contains "def  x   :=   1")
    "a range rewrote the other command's bytes"
  ensureEq "the reported actual range is the unit, not the request"
    s!"{ctx.identity}: formatted range 30-51" (lastErr ranged)
  let formatted ← expectExit 0 "whole" ctx.app
    #["format", "-", "--stdin-filename", ctx.identity] (input? := some source)
    (cwd? := some ctx.root)
  let full ← expectExit 0 "full range" ctx.app
    #["format", "-", "--stdin-filename", ctx.identity, "--range", "0:78"]
    (input? := some source) (cwd? := some ctx.root)
  ensureEq "full range == whole file" formatted.stdout full.stdout
  -- Idempotence, stated in the only coordinates where it can be true: re-running the *requested*
  -- range over the output is NOT a fixed point (the unit's length changed, so 30:49 names a
  -- different region now); re-running the range the unit *now* occupies — what the source map's
  -- `output` reports — is.
  let map ← parseJson (← stream #["--range", "30:49", "--json"]).stdout "map"
  let start := ((jsonAt? map [.field "sourceMap", .index 0, .field "output", .field "start"])
    |>.bind (·.getNum?.toOption)).getD 0 |>.mantissa.toNat
  let stop := ((jsonAt? map [.field "sourceMap", .index 0, .field "output", .field "stop"])
    |>.bind (·.getNum?.toOption)).getD 0 |>.mantissa.toNat
  let again ← expectExit 0 "again" ctx.app
    #["format", "-", "--stdin-filename", ctx.identity, "--range", s!"{start}:{stop}"]
    (input? := some ranged.stdout) (cwd? := some ctx.root)
  ensureEq "range formatting is idempotent in output coordinates" ranged.stdout again.stdout

/-- §3, §5 encodings: positions are codepoints, not bytes; a CRLF buffer streams back CRLF. -/
private def testEncodings (ctx : Ctx) : IO Unit := do
  let utf8 := ctx.work / "utf8.lean"
  writeFile utf8 "module\n\nnamespace     αβγ\n\nend αβγ\n"
  let json ← parseJson (← fmt ctx
    #["format", "-", "--stdin-filename", ctx.identity, "--range-lines", "3:1-3:18", "--json"]
    utf8).stdout "utf8"
  -- Line 3 is `namespace     αβγ`, 17 codepoints over 20 bytes.
  ensureJsonAt json [.field "requestedRange", .field "stop"] (Lean.toJson (28 : Nat))
    "a codepoint column does not resolve past multibyte text"
  let rendered ← expectExit 0 "utf8 stream" ctx.app
    #["format", "-", "--stdin-filename", ctx.identity, "--range-lines", "3:1-3:18"]
    (input? := some (← IO.FS.readFile utf8)) (cwd? := some ctx.root)
  ensureEq "the multibyte buffer still formats" "namespace αβγ"
    ((rendered.stdout.splitOn "\n")[2]?.getD "<missing>")
  let crlf := ctx.work / "crlf.lean"
  writeFile crlf "module\r\n\r\nnamespace     Alpha\r\n\r\nend Alpha\r\n"
  let roundTrip ← expectExit 0 "crlf stream" ctx.app
    #["format", "-", "--stdin-filename", ctx.identity]
    (input? := some (← IO.FS.readFile crlf)) (cwd? := some ctx.root)
  ensure (roundTrip.stdout.contains "\r") "a CRLF buffer lost its line endings"

/-- §5.1 the json envelope: schema, bytes, source map, and a pinned structural digest. -/
private def testJsonSurface (ctx : Ctx) (dirty : System.FilePath) : IO Unit := do
  let json ← parseJson (← fmt ctx
    #["format", "-", "--stdin-filename", ctx.identity, "--range", "30:49", "--json"]
    dirty).stdout "json"
  ensureJsonAt json [.field "schema"] (Lean.toJson "lean-fmt.stream.v1") "json schema"
  let formatted := (json.getObjValAs? String "formatted").toOption.getD ""
  ensure ((formatted.splitOn "\n").contains "namespace Alpha")
    "json does not carry the bytes"
  let sourceMap := (json.getObjVal? "sourceMap").toOption.getD .null
  ensureEq "json carries the source map" 1
    (sourceMap.getArr?.toOption.getD #[]).size
  -- The source map indexes the streamed text.
  let start := ((jsonAt? json [.field "sourceMap", .index 0, .field "output", .field "start"])
    |>.bind (·.getNum?.toOption)).getD 0 |>.mantissa.toNat
  let stop := ((jsonAt? json [.field "sourceMap", .index 0, .field "output", .field "stop"])
    |>.bind (·.getNum?.toOption)).getD 0 |>.mantissa.toNat
  let slice := String.Pos.Raw.extract formatted ⟨start⟩ ⟨stop⟩
  ensureEq "the source map does not index the streamed text" "namespace Alpha"
    (slice.trimAscii.toString)
  -- The structural digest is deterministic across the port: Lean's compress sorts object keys,
  -- which is exactly the old heredoc's `sort_keys=True`.
  let digest ← runProc "shasum" #["-a", "256"] (input? := some sourceMap.compress)
  ensureEq "the structural source-map digest changed"
    "6d65a19283a1094a684dc55c07c30f958c8024e39f807cb49dee3c4c52aa3303"
    ((digest.stdout.splitOn " ").head?.getD "")

/-- The unit lattice of a buffer, as "start-stop start-stop ..." over the *source*. -/
private def units (ctx : Ctx) (buffer : System.FilePath) : IO String := do
  let json ← parseJson (← fmt ctx
    #["format", "-", "--stdin-filename", ctx.identity, "--json"] buffer).stdout "units"
  let entries := ((json.getObjVal? "sourceMap").toOption.getD (.arr #[])).getArr?.toOption.getD #[]
  let spans := entries.toList.map fun entry =>
    let spanAt (key : String) : Nat := ((jsonAt? entry [.field "source", .field key])
      |>.bind (·.getNum?.toOption)).getD 0 |>.mantissa.toNat
    s!"{spanAt "start"}-{spanAt "stop"}"
  return " ".intercalate spans

/-- The actual-range line, on stderr. -/
private def actual (ctx : Ctx) (args : Array String) (buffer : System.FilePath) : IO String := do
  return lastErr (← fmt ctx (#["format", "-", "--stdin-filename", ctx.identity] ++ args) buffer)

/-- §4 the forward extension on real source, and final-newline preservation at the tail. -/
private def testForwardExtension (ctx : Ctx) : IO Unit := do
  let pair := ctx.work / "pair.lean"
  writeFile pair "module\n\ndef a := 1 def b := 2\n"
  ensureEq "two commands on one line are two units" "0-8 8-19 19-30" (← units ctx pair)
  ensureEq "a range over the first stops at its native command boundary"
    s!"{ctx.identity}: formatted range 8-19" (← actual ctx #["--range", "8:18"] pair)
  -- The registered command formatter supplies a hard boundary, so no forward extension fires.
  let json ← parseJson (← fmt ctx
    #["format", "-", "--stdin-filename", ctx.identity, "--json"] pair).stdout "pair json"
  let formatted := (json.getObjValAs? String "formatted").toOption.getD ""
  let stop := ((jsonAt? json [.field "sourceMap", .index 1, .field "output", .field "stop"])
    |>.bind (·.getNum?.toOption)).getD 0 |>.mantissa.toNat
  ensureEq "the first unit does not end at a line boundary" "\n"
    (String.Pos.Raw.extract formatted ⟨stop - 1⟩ ⟨stop⟩)
  -- A buffer with no final newline, ranged over its last unit: the range preserves the
  -- convention, as whole-file formatting does.
  let nonl := ctx.work / "nonl.lean"
  writeFile nonl "module\n\ndef  x   :=   1"
  let ranged ← expectExit 0 "nonl range" ctx.app
    #["format", "-", "--stdin-filename", ctx.identity, "--range", "8:23"]
    (input? := some (← IO.FS.readFile nonl)) (cwd? := some ctx.root)
  ensureEq "a range over the last unit preserves a missing final newline"
    "module\n\ndef x :=\n  1" ranged.stdout

/-- §4 custom syntax and the `#exit` tail: the whole buffer is analyzed and only the slice is
emitted, and the tail is one verbatim unit. -/
private def testCustomSyntaxAndTail (ctx : Ctx) : IO Unit := do
  let syn := ctx.work / "syn.lean"
  writeFile syn
    "module\n\nnotation:65 lhs:65 \" ⊕ \" rhs:66 => Nat.add lhs rhs\n\ndef  total   :=   1 ⊕ 2\n\ndef  other   :=   3\n"
  let ranged ← expectExit 0 "syn range" ctx.app
    #["format", "-", "--stdin-filename", ctx.identity, "--range-lines", "5:1-5:20"]
    (input? := some (← IO.FS.readFile syn)) (cwd? := some ctx.root)
  ensure (ranged.stdout.contains "1 ⊕ 2") "a range over a notation's user lost the notation"
  ensure (ranged.stdout.contains "def  other   :=   3")
    "  ... and did not leave the command after it alone"
  let terminal := ctx.work / "exit.lean"
  writeFile terminal "module\n\ndef  x   :=   1\n\n#exit\n\nthis is not lean at all\n"
  ensureEq "the tail unit begins at #exit" "0-8 8-25 25-56" (← units ctx terminal)
  let whole ← expectExit 0 "exit stream" ctx.app
    #["format", "-", "--stdin-filename", ctx.identity]
    (input? := some (← IO.FS.readFile terminal)) (cwd? := some ctx.root)
  ensureEq "the tail streams back verbatim" "this is not lean at all"
    (((whole.stdout.splitOn "\n").reverse.filter (· != "")).head?.getD "")

/-- §4 header-only, empty, and nested ranges. -/
private def testHeaderEmptyNested (ctx : Ctx) (dirty : System.FilePath) : IO Unit := do
  let hdr := ctx.work / "hdr.lean"
  writeFile hdr "module\n\nimport   LeanFmt.Basic\nimport LeanFmt.Doc\n\ndef  x   :=   1\n"
  ensureEq "a range inside the header selects the whole header"
    s!"{ctx.identity}: formatted range 0-51" (← actual ctx #["--range", "0:20"] hdr)
  let headerRanged ← expectExit 0 "header range" ctx.app
    #["format", "-", "--stdin-filename", ctx.identity, "--range", "0:20"]
    (input? := some (← IO.FS.readFile hdr)) (cwd? := some ctx.root)
  ensure (headerRanged.stdout.contains "import LeanFmt.Basic")
    "  ... did not format the complete header/import region"
  ensure (headerRanged.stdout.contains "def  x   :=   1") "  ... and touched the body"
  -- An empty range is a cursor: it selects the one unit that contains the position.
  ensureEq "an empty range selects the unit containing it"
    s!"{ctx.identity}: formatted range 30-51" (← actual ctx #["--range", "30:30"] dirty)
  -- The lattice is command-granular: six bytes deep inside a structure instance widen to the
  -- enclosing command.
  let nest := ctx.work / "nest.lean"
  writeFile nest
    "module\n\nstructure Point where\n  x : Nat\n  y : Nat\n\ndef  origin   : Point   :=   { x := 0, y := 0 }\n"
  ensureEq "a range inside a nested node widens to its command"
    s!"{ctx.identity}: formatted range 51-99" (← actual ctx #["--range", "82:88"] nest)

/-- §4 formatter suppression is a structural unit, and §4.3 comment ownership at an extent
boundary is trailing-greedy. -/
private def testSuppressionAndOwnership (ctx : Ctx) : IO Unit := do
  let suppressed := ctx.work / "suppressed.lean"
  writeFile suppressed
    "module\n\n-- lean-fmt: format-ignore-next\ndef preserved(alpha:Nat):Nat:=alpha+1\n\ndef  resumed(beta:Nat):Nat:=beta+1\n"
  let suppressedRange ← expectExit 0 "suppressed range" ctx.app
    #["format", "-", "--stdin-filename", ctx.identity, "--range-lines", "3:1-4:38"]
    (input? := some (← IO.FS.readFile suppressed)) (cwd? := some ctx.root)
  let lines := suppressedRange.stdout.splitOn "\n"
  ensureEq "a selected suppressed unit moved" "def preserved(alpha:Nat):Nat:=alpha+1"
    (lines[3]?.getD "<missing>")
  ensureEq "a suppressed range touched the following dirty unit"
    "def  resumed(beta:Nat):Nat:=beta+1" (lines[5]?.getD "<missing>")
  let resumedRange ← expectExit 0 "resumed range" ctx.app
    #["format", "-", "--stdin-filename", ctx.identity, "--range-lines", "6:1-6:39"]
    (input? := some (← IO.FS.readFile suppressed)) (cwd? := some ctx.root)
  ensure (resumedRange.stdout.contains "def resumed (beta : Nat) : Nat :=")
    "formatting did not resume in the next selected unit"
  -- The body is asserted too: the header alone would no longer prove the unit reflowed.
  let resumedLines := resumedRange.stdout.splitOn "\n"
  let some headerIndex := resumedLines.findIdx? (·.contains "def resumed")
    | throw <| IO.userError "the resumed header is missing"
  ensureEq "the resumed unit's body reflows onto its own line" "  beta + 1"
    (resumedLines[headerIndex + 1]?.getD "<missing>")
  ensureEq "formatting the next unit disturbed suppressed bytes"
    "def preserved(alpha:Nat):Nat:=alpha+1" (resumedLines[3]?.getD "<missing>")
  -- A comment written *above* a declaration is in the *earlier* command's extent — a frozen
  -- verdict, surprising enough to assert.
  let cmt := ctx.work / "cmt.lean"
  writeFile cmt "module\n\ndef  a   :=   1\n\n-- a comment written above b\ndef  b   :=   2\n"
  ensureEq "the comment above b belongs to a's unit" "0-8 8-54 54-70" (← units ctx cmt)

/-- §6 pipes: chaining through itself is a fixed point; a stdout that goes away is an
infrastructure failure, not a crash; invalid UTF-8 gets the frozen decode. -/
private def testPipes (ctx : Ctx) : IO Unit := do
  let nest := ctx.work / "nest.lean"
  writeFile nest
    "module\n\nstructure Point where\n  x : Nat\n  y : Nat\n\ndef  origin   : Point   :=   { x := 0, y := 0 }\n"
  let once ← expectExit 0 "once" ctx.app #["format", "-", "--stdin-filename", ctx.identity]
    (input? := some (← IO.FS.readFile nest)) (cwd? := some ctx.root)
  let twice ← expectExit 0 "twice" ctx.app #["format", "-", "--stdin-filename", ctx.identity]
    (input? := some once.stdout) (cwd? := some ctx.root)
  ensureEq "format - piped into itself is not a fixed point" once.stdout twice.stdout
  -- A reader that exits before the writer finishes. 6,000 definitions because the size is part
  -- of the contract and no more: the output must exceed the 64 KiB pipe buffer.
  let big := ctx.work / "big.lean"
  IO.FS.withFile big .write fun handle => do
    handle.putStr "module\n\n"
    for i in [0:6001] do
      handle.putStr s!"def  x{i}   :=   {i}\n\n"
  let errPath := ctx.work / "pipe.err"
  let pipeScript := ctx.work / "pipe.sh"
  writeFile pipeScript
    "\"$1\" format - --stdin-filename \"$2\" < \"$3\" 2> \"$4\" | { read -r _i; exit 0; }\n\
     printf '%s' \"${PIPESTATUS[0]}\"\n"
  let pipe ← runProc "bash"
    #[pipeScript.toString, ctx.app, ctx.identity, big.toString, errPath.toString]
    (cwd? := some ctx.root) (timeoutMs := some 600000)
  ensureEq "a stdout that goes away is not exit 2" "2" (pipe.stdout.trimAscii.toString)
  ensure ((← IO.FS.readFile errPath).contains "broken pipe")
    "  ... and does not say so on stderr"
  -- §6 fixes this wording; without an explicit decode it would be the runtime's phrasing.
  let binary := ctx.work / "binary.lean"
  IO.FS.writeBinFile binary
    (("module\n\ndef x := ".toUTF8 ++ ByteArray.mk #[0xff, 0xfe]) ++ "\n".toUTF8)
  let decodeScript := ctx.work / "decode.sh"
  writeFile decodeScript
    "\"$1\" format - --stdin-filename \"$2\" < \"$3\" 2>&1 >/dev/null\n\
     printf 'EXIT:%s' \"$?\"\n"
  let decoded ← runProc "sh" #[decodeScript.toString, ctx.app, ctx.identity, binary.toString]
    (cwd? := some ctx.root)
  let errLines := (decoded.stdout.splitOn "\n").filter (· != "")
  ensureEq "invalid UTF-8 on stdin is rejected with the frozen message"
    "lean-fmt: stdin is not valid UTF-8" (errLines.head?.getD "")
  ensure (decoded.stdout.endsWith "EXIT:2") "  ... and its exit is not 2"

/-- §2 a range names the only mode that can honor it, and §6 `fix -` streams the buffer at
original coordinates. -/
private def testRangeModesAndFix (ctx : Ctx) (dirty : System.FilePath) : IO Unit := do
  for mode in ["check", "diff", "fix"] do
    let result ← fmt ctx
      #[mode, "-", "--stdin-filename", ctx.identity, "--range", "30:49"] dirty
    ensureEq s!"--range is not rejected for {mode} -" s!"--range is valid only with format, not {mode}"
      (firstErr result)
  let source ← IO.FS.readFile dirty
  let fixed ← expectExit 0 "fix -" ctx.app #["fix", "-", "--stdin-filename", ctx.identity]
    (input? := some source) (cwd? := some ctx.root)
  -- `fix` publishes admitted rule fixes at *original* coordinates; a buffer with no admitted fix
  -- streams back unchanged.
  ensureEq "fix - streams the buffer at original coordinates" "namespace     Alpha"
    ((fixed.stdout.splitOn "\n")[4]?.getD "<missing>")

end Stream

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  withTempDir fun work => do
    let ctx : Stream.Ctx := {
      root
      app := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
      work
    }
    -- A buffer with one layout defect in its own command and a second command after it — the
    -- minimum that can show a range leaving the other one alone.
    let dirty := work / "dirty.lean"
    writeFile dirty
      "module\n\nimport LeanFmt.Basic\n\nnamespace     Alpha\n\ndef  x   :=   1\n\nend Alpha\n"
    let code ← (try
        runCases "stream" #[
          { name := "usage-rejections", run := Stream.testUsageRejections ctx dirty },
          { name := "identity-gates", run := Stream.testIdentityGates ctx dirty },
          { name := "format-streams", run := Stream.testFormatStreams ctx dirty },
          { name := "other-modes", run := Stream.testOtherModes ctx dirty },
          { name := "broken-buffer", run := Stream.testBrokenBuffer ctx },
          { name := "range-expansion", run := Stream.testRangeExpansion ctx dirty },
          { name := "encodings", run := Stream.testEncodings ctx },
          { name := "json-surface", run := Stream.testJsonSurface ctx dirty },
          { name := "forward-extension", run := Stream.testForwardExtension ctx },
          { name := "custom-syntax-and-tail", run := Stream.testCustomSyntaxAndTail ctx },
          { name := "header-empty-nested", run := Stream.testHeaderEmptyNested ctx dirty },
          { name := "suppression-and-ownership", run := Stream.testSuppressionAndOwnership ctx },
          { name := "pipes", run := Stream.testPipes ctx },
          { name := "range-modes-and-fix", run := Stream.testRangeModesAndFix ctx dirty }
        ] args
      catch error => do
        IO.eprintln (toString error)
        pure 1)
    removeDirAll? (root / ".lean-fmt-cache")
    return code
