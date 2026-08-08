module

public import Test

/-!
# The reporting suite

The machine-readable report formats.

Every case drives the real executable, because what is under test is the bytes a CI system
receives: the grammar, the escaping, the exit code, and where the report lands. The structured
formats are checked with **independent parsers** wherever one exists — `check-jsonschema`,
`junitparser`, `xmllint`, and `urllib.parse` stay external processes, because a renderer and its
bespoke checker can agree on the same mistake, and a real consumer is the thing we actually
promise to satisfy.

Lane: workspace — several cases populate the root `.lean-fmt-cache`, which the preamble clears.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace Reporting

structure Ctx where
  root : System.FilePath
  application : String
  work : System.FilePath
  /-- Whether the startup probe could resolve and run a validator through `uv run --with`; when
  false, the checks that defer to an external validator pass vacuously and the startup notice
  says which. uv on PATH is not enough — resolution also needs network access, and a runner
  lacking either fails every dependent check with the tool's exit 255. -/
  uv : Bool
  /-- Whether xmllint is on PATH, guarding the two JUnit well-formedness checks the same way. -/
  xmllint : Bool

/-- The committed duplicate-import fixture. -/
private def findings : String :=
  "tests/fixtures/check/Findings.lean"

/-- Run the binary without asserting the exit code. -/
private def fmt (ctx : Ctx) (args : Array String) (input? : Option String := none)
    (env : Array (String × Option String) := #[]) : IO ProcResult :=
  runProc ctx.application args (input? := input?) (cwd? := some ctx.root) (env := env)

private def fmtCode (ctx : Ctx) (args : Array String) : IO UInt32 :=
  return (← fmt ctx args).exitCode

/-- The first line of stderr. -/
private def firstStderrLine (result : ProcResult) : String :=
  (((result.stderr.splitOn "\n").head?.getD "").trimAsciiEnd).toString

/-- An external validator, named in the failure so the report says which consumer broke. -/
private def expectTool (label : String) (args : Array String) (input? : Option String := none)
    (cwd? : Option System.FilePath := none) : IO String := do
  let result ← expectExit 0 label "uv" args (input? := input?) (cwd? := cwd?)
  return (result.stdout.trimAsciiEnd).toString

/-- True only when `uv run --with` can resolve and execute a package — the functional probe, not
a PATH check, because what CI runners lack is as often the network access as the binary. -/
private def probeUv : IO Bool := do
  try
    let probe ←
      runProc "uv"
          #["run", "--with", "check-jsonschema", "--quiet", "check-jsonschema", "--version"]
    return probe.exitCode == 0
  catch _ =>
    return false

/-- True when xmllint is on PATH; the same skip-not-fail rule as `probeUv`. -/
private def probeXmllint : IO Bool := do
  try
    let probe ← runProc "sh" #["-c", "command -v xmllint"]
    return probe.exitCode == 0
  catch _ =>
    return false

-- §2 — the flag surface.
private def testFlagSurface (ctx : Ctx) : IO Unit := do
  let unknown ← fmt ctx #["check", findings, "--output-format", "bogus"]
  ensureEq "an unknown --output-format is rejected"
      "unknown --output-format: bogus (expected text, concise, json, github, sarif, or junit)"
      (firstStderrLine unknown)
  ensureEq "  ... with exit 2" 2 unknown.exitCode
  -- §2.3 — a finding-shaped format for `diff`, whose product is a patch and which was *measured*
  -- to carry no findings at all. Rejected rather than rendered empty.
  for format in ["concise", "github", "sarif", "junit"]do
    let rejected ← fmt ctx #["format", "--diff", findings, "--output-format", format]
    ensureEq s!"--output-format {format} is rejected for diff"
        s!"--output-format {format} is not available for diff; diff reports a patch, not findings"
        (firstStderrLine rejected)
  ensureEq "--output-format json is still allowed for diff" 1
      (← fmtCode ctx #["format", "--diff", findings, "--output-format", "json"])
  -- §2.2 — two spellings of one choice. Agreement is fine; disagreement is an error, never a
  -- precedence rule, because a caller who typed two formats has no preference for us to guess.
  let disagree ← fmt ctx #["check", findings, "--json", "--output-format", "github"]
  ensureEq "--json with a disagreeing --output-format is rejected"
      "--json and --output-format github disagree; pass only one" (firstStderrLine disagree)
  ensureEq "--json with an agreeing --output-format is accepted" 1
      (← fmtCode ctx #["check", findings, "--json", "--output-format", "json"])

-- §8.1 — the alias is an alias, and the bytes still match the pre-change golden.
private def testJsonCompat (ctx : Ctx) : IO Unit := do
  let viaJson ← fmt ctx #["check", "--root", ".", "--no-cache", "--json", findings]
  let viaFormat ←
    fmt ctx #["check", "--root", ".", "--no-cache", "--output-format", "json", findings]
  ensureEq "--json and --output-format json produce identical bytes" viaJson.stdout viaFormat.stdout
  let golden ←
    IO.FS.readFile (ctx.root / "tests" / "fixtures" / "reporting" / "golden" / "json-check.json")
  ensureEq "--output-format json still reproduces the pre-change golden" golden viaJson.stdout

-- §9.1 — the worst regression here is a CI job that starts passing because it swapped a format
-- in. Every format must agree with `text` on the verdict.
private def testExitCodes (ctx : Ctx) : IO Unit := do
  let baseline ← fmtCode ctx #["check", findings]
  ensureEq "the baseline is the CI failure code" 1 baseline
  for format in ["concise", "json", "github", "sarif", "junit"]do
    ensureEq s!"{format} agrees with text on the exit code" baseline
        (← fmtCode ctx #["check", findings, "--output-format", format])

-- §4 — concise.
private def testConcise (ctx : Ctx) : IO Unit := do
  let concise ← fmt ctx #["check", findings, "--output-format", "concise"]
  let lines := concise.stdout.splitOn "\n" |>.filter (!·.isEmpty)
  ensureEq "one line per finding, no summary line" 1 lines.length
  ensureEq "the grammar is PATH:LINE:COL: CODE MESSAGE"
      "tests/fixtures/check/Findings.lean:4:1: FMT003 duplicate import of LeanFmt.Basic"
      (concise.stdout.trimAsciiEnd).toString
  -- `text` prints ` [safe]`; `concise` must not — an applicability tag is machine data and breaks
  -- an editor error-parser reading the line for a file:line:col jump.
  ensure (!(concise.stdout.contains "[safe]")) "concise leaked the applicability tag"

-- §3.1 — columns count code points, not bytes. Line 8 of the fixture is
-- `def ünïcödéValue : Nat := ((1))`: a byte column would report 31 and a codepoint column 27.
private def testCodepointColumns (ctx : Ctx) : IO Unit := do
  let result ←
    fmt ctx
        #["check", "tests/fixtures/reporting/Unicode.lean", "--select", "all", "--preview",
          "--output-format", "concise"]
  ensureContains result.stdout "tests/fixtures/reporting/Unicode.lean:8:27: FMT011"
      "a codepoint column is reported, not a byte column"

-- §5 — github workflow commands, escaping, and the multi-line restriction.
private def testGithub (ctx : Ctx) : IO Unit := do
  let github ← fmt ctx #["check", findings, "--output-format", "github"]
  ensureEq "one workflow command per finding"
      "::warning title=lean-fmt (FMT003),file=tests/fixtures/check/Findings.lean,line=4,col=1,endLine=4,\
     endColumn=21::tests/fixtures/check/Findings.lean:4:1: FMT003 duplicate import of LeanFmt.Basic"
      (github.stdout.trimAsciiEnd).toString
  -- §5.3 — property values escape `:` and `,` beyond what the message escapes, because either
  -- would otherwise terminate the property list.
  let hostile := "dir,with:punct/Buffer.lean"
  let dup := "module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n"
  let hostileOut ←
    fmt ctx #["check", "-", "--stdin-filename", hostile, "--output-format", "github"] (input? :=
        some dup)
  ensureContains hostileOut.stderr "file=dir%2Cwith%3Apunct/Buffer.lean"
      "a path's ':' and ',' are escaped in the property list"
  -- The message half uses the laxer `escapeData`, which leaves `:` and `,` alone.
  ensureContains hostileOut.stderr "::dir,with:punct/Buffer.lean:4:1: FMT003"
      "the message half is not property-escaped"
  -- §5.2 — GitHub rejects an annotation carrying col/endColumn when line != endLine. A multi-line
  -- finding must therefore drop them.
  let multiline := "module\n\nimport LeanFmt.Basic\n\ndef spanning : Nat := ((\n  1\n  ))\n"
  let multi ←
    fmt ctx
        #["check", "-", "--stdin-filename", "tests/fixtures/reporting/Multiline.lean", "--select",
          "FMT011", "--preview", "--output-format", "github"]
        (input? := some multiline)
  ensure (!(multi.stderr.contains "col="))
      s!"a multi-line annotation kept col=, which GitHub rejects: {multi.stderr}"
  ensureContains multi.stderr "line=5,endLine=7" "  ... but still carries line and endLine"

/-- The SARIF assertions beyond the schema (§3.4): `columnKind`, the property-bag byte range,
described ruleIds, and the invocation record. -/
private def sarifConform (log : Lean.Json) (label : String) : IO Unit := do
  ensureJsonAt log [.field "version"] (Lean.toJson "2.1.0") label
  let some runs :=
    (jsonAt? log [.field "runs"]).bind
      (·.getArr?.toOption) | throw <| IO.userError s!"{label}: no runs"
  ensureEq s!"{label}: one run" 1 runs.size
  let run := runs[0]!
  let some results :=
    (jsonAt? run [.field "results"]).bind
      (·.getArr?.toOption) | throw <| IO.userError s!"{label}: no results"
  ensure (!results.isEmpty) s!"{label}: the fixture produced no results; assertions are vacuous"
  ensureJsonAt run [.field "columnKind"] (Lean.toJson "unicodeCodePoints") label
  -- §3.30.4: a text region must not carry binary properties. Ours are normalized-source byte
  -- offsets, which are neither charOffset nor byteOffset, so they belong in the property bag.
  let some region :=
    jsonAt? results[0]!
      [.field "locations", .index 0, .field "physicalLocation",
        .field "region"] | throw <| IO.userError s!"{label}: no region"
  ensure ((jsonAt? region [.field "charOffset"]).isNone) s!"{label}: region carries charOffset"
  ensure ((jsonAt? region [.field "byteOffset"]).isNone) s!"{label}: region carries byteOffset"
  ensureJsonAt region [.field "properties", .field "leanFmtNormalizedByteRange"]
      (Lean.Json.mkObj [("start", Lean.toJson (29 : Nat)), ("stop", Lean.toJson (49 : Nat))]) label
  ensureJsonAt region [.field "startLine"] (Lean.toJson (4 : Nat)) label
  ensureJsonAt region [.field "startColumn"] (Lean.toJson (1 : Nat)) label
  ensureJsonAt region [.field "endLine"] (Lean.toJson (4 : Nat)) label
  ensureJsonAt region [.field "endColumn"] (Lean.toJson (21 : Nat)) label
  -- Every reported ruleId has a descriptor: a result naming a rule the tool did not describe is
  -- a log a viewer cannot explain.
  let described :=
    (((jsonAt? run [.field "tool", .field "driver", .field "rules"]).bind (·.getArr?.toOption)).getD
          #[]).filterMap
      fun rule => (rule.getObjValAs? String "id").toOption
  for result in results do
    let ruleId := (result.getObjValAs? String "ruleId").toOption.getD ""
    ensure (described.contains ruleId) s!"{label}: {ruleId} has no descriptor"
  -- §3.20.21 — the invocation, not a result, is what says whether the run completed.
  let some invocations :=
    (jsonAt? run [.field "invocations"]).bind
      (·.getArr?.toOption) | throw <| IO.userError s!"{label}: no invocations"
  ensureEq s!"{label}: one invocation" 1 invocations.size
  ensureJsonAt invocations[0]! [.field "executionSuccessful"] (Lean.toJson true) label
  ensureJsonAt invocations[0]! [.field "toolExecutionNotifications"] (.arr #[]) label
  let some srcroot :=
    (jsonAt? run [.field "originalUriBaseIds", .field "%SRCROOT%", .field "uri"]).bind
      (·.getStr?.toOption) | throw <| IO.userError s!"{label}: no %SRCROOT%"
  ensure (srcroot.startsWith "file:///") s!"{label}: %SRCROOT% is {srcroot}"

-- §6 — sarif: schema validation by an independent validator, conformance beyond the schema, the
-- catalog-projected descriptor, and the aborted-run log.
private def testSarif (ctx : Ctx) : IO Unit := do
  let report ← fmt ctx #["check", findings, "--output-format", "sarif"]
  let reportPath := ctx.work / "report.sarif"
  writeFile reportPath report.stdout
  if ctx.uv then
    discard <|
        expectExit 0 "the SARIF log validates against the 2.1.0 JSON schema" "uv"
          #["run", "--with", "check-jsonschema", "--quiet", "check-jsonschema", "--schemafile",
            "tests/fixtures/reporting/sarif-schema-2.1.0.json", reportPath.toString]
          (cwd? := some ctx.root)
  sarifConform (← parseJson report.stdout "sarif") "sarif"
  -- The descriptor text is projected from the live rule catalog, never re-authored in the
  -- renderer.
  let explained ←
    expectExit 0 "explain FMT003" ctx.application #["explain", "FMT003", "--json"] (cwd? :=
        some ctx.root)
  let summary := ((← parseJson explained.stdout "explain").getObjValAs? String "summary").toOption
  let described :=
    (((jsonAt? (← parseJson report.stdout "sarif")
          [.field "runs", .index 0, .field "tool", .field "driver", .field "rules", .index 0,
            .field "shortDescription", .field "text"])).bind
      (·.getStr?.toOption))
  ensureEq "a rule descriptor matches the catalog's own summary" summary described
  -- §6.5 — an infrastructure failure is a notification and flips executionSuccessful, so the log
  -- agrees with exit code 2 instead of looking like a clean run that found nothing.
  let sabotaged :=
    #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"), ("LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE", some "1"),
      ("LEAN_FMT_TEST_ANALYZER", some "/usr/bin/false")]
  let failed ←
    fmt ctx
        #["check", "--root", ".", "--no-cache", "--output-format", "sarif",
          "tests/fixtures/check/Clean.lean"]
        (env := sabotaged)
  let failedLog ← parseJson failed.stdout "failed sarif"
  let some invocation :=
    jsonAt? failedLog
      [.field "runs", .index 0, .field "invocations",
        .index 0] | throw <| IO.userError "failed sarif: no invocation"
  ensureJsonAt invocation [.field "executionSuccessful"] (Lean.toJson false) "failed sarif"
  let notifications :=
    ((jsonAt? invocation [.field "toolExecutionNotifications"]).bind (·.getArr?.toOption)).getD #[]
  ensure (!notifications.isEmpty) "failed sarif: no toolExecutionNotifications"
  for notification in notifications do
    ensureJsonAt notification [.field "level"] (Lean.toJson "error") "failed sarif"
  -- The log and the exit code must say the same thing.
  ensureEq "  ... and the same run exits 2" 2 failed.exitCode

-- §7 — junit: well-formed, read back by an independent consumer, passing case for a clean file,
-- and XML escaping.
private def testJunit (ctx : Ctx) : IO Unit := do
  let report ← fmt ctx #["check", findings, "--output-format", "junit"]
  let reportPath := ctx.work / "report.xml"
  writeFile reportPath report.stdout
  if ctx.xmllint then
    discard <|
        expectExit 0 "the JUnit report is well-formed XML" "xmllint"
          #["--noout", reportPath.toString]
  -- An independent JUnit *consumer*, which is what a CI system actually runs. §8.2 records why
  -- this replaced an XSD check: the format has no normative schema, and the most-cited XSD is one
  -- flavor that requires a `time` this report has no measurement for.
  let parsed ←
    if ctx.uv then
      expectTool "an independent JUnit parser reads it back"
          #["run", "--with", "junitparser", "--quiet", "python3", "-c",
            "import sys\nfrom junitparser import JUnitXml\n\
       xml = JUnitXml.fromfile(sys.argv[1])\n\
       cases = [(suite.name, case.name, [r.type for r in case.result]) \
       for suite in xml for case in suite]\n\
       assert cases == [(\"tests/fixtures/check/Findings.lean\", \
       \"FMT003 tests/fixtures/check/Findings.lean:4:1\", [\"FMT003\"])], cases\n\
       assert (xml.tests, xml.failures, xml.errors) == (1, 1, 0)\n\
       print(\"ok\")",
            reportPath.toString]
    else
      pure "ok"
  ensureEq "an independent JUnit parser reads it back" "ok" parsed
  -- A clean file emits a *passing* case, not an empty suite: a suite with zero cases reads to
  -- most CI dashboards as "no tests ran" rather than "nothing wrong".
  let clean ← fmt ctx #["check", "tests/fixtures/check/Clean.lean", "--output-format", "junit"]
  let cleanPath := ctx.work / "clean.xml"
  writeFile cleanPath clean.stdout
  let cleanParsed ←
    if ctx.uv then
      expectTool "a clean file emits a passing case"
          #["run", "--with", "junitparser", "--quiet", "python3", "-c",
            "import sys\nfrom junitparser import JUnitXml\n\
       xml = JUnitXml.fromfile(sys.argv[1])\n\
       cases = [(case.name, list(case.result)) for suite in xml for case in suite]\n\
       assert len(cases) == 1 and cases[0][1] == [], cases\n\
       assert (xml.tests, xml.failures, xml.errors) == (1, 0, 0)\n\
       print(\"ok\")",
            cleanPath.toString]
    else
      pure "ok"
  ensureEq "a clean file emits a passing case, not an empty suite" "ok" cleanParsed
  -- §7.3 — XML escaping. `--stdin-filename` supplies a path no filesystem has to accept.
  let dup := "module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n"
  let xmlHostile ←
    fmt ctx #["check", "-", "--stdin-filename", "a&b<c>d.lean", "--output-format", "junit"]
        (input? := some dup)
  ensureContains xmlHostile.stderr "a&amp;b&lt;c&gt;d.lean"
      "XML metacharacters in a path are escaped"
  if ctx.xmllint then
    discard <|
        expectExit 0 "  ... and the result is still well-formed" "xmllint" #["--noout", "-"]
          (input? := some xmlHostile.stderr)

-- §2.4, §9.2 — output files.
private def testOutputFiles (ctx : Ctx) : IO Unit := do
  let absent := ctx.work / "absent" / "report.json"
  let missing ← fmt ctx #["check", findings, "--output-file", absent.toString, "--json"]
  ensureEq "a missing --output-file directory is rejected before the run"
      s!"--output-file directory does not exist: {absent}" (firstStderrLine missing)
  ensureEq "  ... with exit 2" 2 missing.exitCode
  let directory ← fmt ctx #["check", findings, "--output-file", ctx.work.toString, "--json"]
  ensureEq "a directory --output-file is rejected" s!"--output-file is a directory: {ctx.work}"
      (firstStderrLine directory)
  let outSarif := ctx.work / "out.sarif"
  let written ←
    fmt ctx #["check", findings, "--output-file", outSarif.toString, "--output-format", "sarif"]
  ensureEq "--output-file leaves stdout empty" "" written.stdout
  if ctx.uv then
    discard <|
        expectExit 0 "  ... and the file holds the complete report" "uv"
          #["run", "--with", "check-jsonschema", "--quiet", "check-jsonschema", "--schemafile",
            "tests/fixtures/reporting/sarif-schema-2.1.0.json", outSarif.toString]
          (cwd? := some ctx.root)
  ensureEq "  ... and the exit code is unchanged" 1
      (←
        fmtCode ctx
            #["check", findings, "--output-file", (ctx.work / "out2.sarif").toString,
              "--output-format", "sarif"])
  -- Atomic replacement: the temporary must not survive, and a previous report must not be
  -- truncated in place. Both are what a CI job polling the path depends on.
  ensure (!(← (ctx.work / "out.sarif.lean-fmt-tmp").pathExists))
      "the atomic write left its temporary behind"

-- §9.3 — `… | head -1` is the standard idiom. It must not print a diagnostic — and must NOT be
-- turned into a success, which would make the pipe a way to silence CI. The pipeline needs
-- PIPESTATUS, so it runs under bash.
private def testBrokenPipe (ctx : Ctx) : IO Unit := do
  for format in ["text", "concise", "json", "github", "sarif", "junit"]do
    let script :=
      "err=$(\"$APP\" check \"$FINDINGS\" --output-format \"$FMT\" 2>&1 >/dev/null \
        | head -1)\n\
        code=$({ \"$APP\" check \"$FINDINGS\" --output-format \"$FMT\" 2>/dev/null \
        | head -1 >/dev/null; }; echo \"${PIPESTATUS[0]}\")\n\
        printf '%s\\n%s' \"$err\" \"$code\""
    let result ←
      expectExit 0 s!"broken pipe {format}" "bash" #["-c", script] (cwd? := some ctx.root) (env :=
          #[("APP", some ctx.application), ("FINDINGS", some findings), ("FMT", some format)])
    let lines := result.stdout.splitOn "\n"
    ensureEq s!"{format} survives a closed pipe with its own exit code" "1"
        ((lines[1]?.getD "").trimAsciiEnd).toString
    ensure (((lines[0]?.getD "").trimAsciiEnd).toString.isEmpty)
        s!"{format} printed a diagnostic on a closed pipe: {lines[0]?.getD ""}"

-- §2.5 — stdin: stdout still carries the result and nothing else, so a
-- finding-shaped report goes to stderr — putting it on stdout would corrupt the bytes a
-- `format -` consumer is piping.
private def testStdin (ctx : Ctx) : IO String := do
  let dup := "module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n"
  let result ←
    fmt ctx
        #["check", "-", "--stdin-filename", "tests/fixtures/reporting/Buffer.lean",
          "--output-format", "concise"]
        (input? := some dup)
  ensureEq "a stdin report does not reach stdout" "" result.stdout
  ensureEq "a stdin report reaches stderr with resolved positions"
      "tests/fixtures/reporting/Buffer.lean:4:1: FMT003 duplicate import of LeanFmt.Basic"
      (result.stderr.trimAsciiEnd).toString
  -- CRLF: every offset indexes the CRLF-normalized source, so a line/column resolved from it must
  -- match the LF twin exactly. Delivered through stdin because git would not keep a CRLF fixture.
  let crlf ←
    fmt ctx
        #["check", "-", "--stdin-filename", "tests/fixtures/reporting/Buffer.lean",
          "--output-format", "concise"]
        (input? := some "module\r\n\r\nimport LeanFmt.Basic\r\nimport LeanFmt.Basic\r\n")
  ensureEq "a CRLF buffer resolves to the same line and column as its LF twin"
      (result.stderr.trimAsciiEnd).toString (crlf.stderr.trimAsciiEnd).toString
  return (result.stderr.trimAsciiEnd).toString

-- §6.2, §6.4 — URI encoding, help links, and the pseudo-rule id.
private def testUris (ctx : Ctx) : IO Unit := do
  let dup := "module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n"
  -- §6.4 — a SARIF `uri` is a URI reference, not a filesystem path. The four characters below are
  -- the ones that actually break: a space is forbidden outright, `#` starts a fragment, `%` makes
  -- whatever follows look like an escape, and a non-ASCII character has no representation except
  -- its UTF-8 bytes.
  let uriOut ←
    fmt ctx #["check", "-", "--stdin-filename", "src/my dir/Ä#b%c.lean", "--output-format", "sarif"]
        (input? := some dup)
  ensureContains uriOut.stderr "\"uri\": \"src/my%20dir/%C3%84%23b%25c.lean\""
      "a SARIF uri percent-encodes space, '#', '%', and UTF-8 bytes"
  -- And the result is a *parseable* URI reference, checked by a parser that is not ours.
  let decoded ←
    if ctx.uv then
      expectTool "  ... and an independent URI parser decodes it back to the path"
          #["run", "--quiet", "python3", "-c",
            "import json, sys, urllib.parse\n\
       log = json.loads(sys.stdin.read())\n\
       uri = log[\"runs\"][0][\"results\"][0][\"locations\"][0][\"physicalLocation\"]\
       [\"artifactLocation\"][\"uri\"]\n\
       parts = urllib.parse.urlsplit(uri)\n\
       assert parts.fragment == \"\" and parts.query == \"\", f\"leaked delimiter in {uri}\"\n\
       print(urllib.parse.unquote(parts.path))"]
          (input? := some uriOut.stderr)
    else
      -- The vacuous value is the assertion's expectation: a skipped decode is recorded by the
      -- startup notice, not by a failure the tool's absence would fabricate.
      pure "src/my dir/Ä#b%c.lean"
  ensureEq "  ... and an independent URI parser decodes it back to the path" "src/my dir/Ä#b%c.lean"
      decoded
  -- §6.2 — `helpUri`. The assertion is not that the string is present but that the file it names
  -- is in this repository — a link checked by construction.
  let sarif ← fmt ctx #["check", findings, "--output-format", "sarif"]
  let log ← parseJson sarif.stdout "helpUri sarif"
  let rules :=
    ((jsonAt? log [.field "runs", .index 0, .field "tool", .field "driver", .field "rules"]).bind
          (·.getArr?.toOption)).getD
      #[]
  ensure (!rules.isEmpty) "no rule descriptor carried a helpUri"
  for rule in rules do
    let some uri :=
      (rule.getObjValAs? String
          "helpUri").toOption | throw <| IO.userError "a rule descriptor carried no helpUri"
    let uriPrefix := "https://github.com/jcreinhold/lean-fmt/blob/main/docs/rules/"
    ensure (uri.startsWith uriPrefix) s!"helpUri outside the docs tree: {uri}"
    let page := (uri.drop uriPrefix.length).toString
    ensure (← (ctx.root / "docs" / "rules" / page).pathExists)
        s!"helpUri names a rule page that does not exist: {page}"
  -- The `format` pseudo-rule id (§6.3, §7.2) stands in for a per-file status that no rule
  -- produced. It must not collide with anything the registry can emit.
  let rulesJson ←
    expectExit 0 "rules --json" ctx.application #["rules", "--json"] (cwd? := some ctx.root)
  let codes :=
    (((← parseJson rulesJson.stdout "rules").getArr?.toOption).getD #[]).filterMap fun rule =>
      (rule.getObjValAs? String "code").toOption
  ensure (!(codes.contains "format")) "the 'format' pseudo-rule id collides with a registered rule"

-- §3.1 — codepoint columns are neither bytes nor UTF-16. An astral-plane character is 4 bytes
-- and 2 UTF-16 code units, so it separates all three encodings at once: the reported column is
-- 34, where a byte column would be 37 and a UTF-16 column 35.
private def testAstral (ctx : Ctx) : IO Unit := do
  let astral ←
    fmt ctx
        #["check", "-", "--stdin-filename", "tests/fixtures/reporting/Astral.lean", "--select",
          "FMT011", "--preview", "--output-format", "concise"]
        (input? :=
        some "module\n\nimport LeanFmt.Basic\n\n/- 𝔘 -/ def astralValue : Nat := ((1))\n")
  ensureEq "an astral-plane character advances the column by one, not two or four"
      "tests/fixtures/reporting/Astral.lean:5:34: FMT011 redundant nested parentheses"
      (astral.stderr.trimAsciiEnd).toString

-- §5.2 — the other half of the escaping contract: a consumer applying the documented inverse
-- recovers the path exactly. An escaper that is merely self-consistent passes the byte-level
-- assertion and fails this.
private def testGithubRoundTrip (ctx : Ctx) : IO Unit := do
  let dup := "module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n"
  let result ←
    fmt ctx
        #["check", "-", "--stdin-filename", "weird,path:with%signs/A.lean", "--output-format",
          "github"]
        (input? := some dup)
  let line := (result.stderr.splitOn "\n").head?.getD ""
  let fileValue :=
    match (line.splitOn "file=").tail? with
    | some (after :: _) => (after.splitOn ",").head?.getD ""
    | _ => ""
  let unescaped :=
    fileValue.replace "%3A" ":" |>.replace "%2C" "," |>.replace "%0D" "\r" |>.replace "%0A"
        "\n" |>.replace
      "%25" "%"
  ensureEq "a GitHub property survives the documented unescaping" "weird,path:with%signs/A.lean"
      unescaped

end Reporting

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  removeDirAll? (root / ".lean-fmt-cache")
  let uv ← Reporting.probeUv
  let xmllint ← Reporting.probeXmllint
  unless uv && xmllint do
    IO.println
        s!"reporting: external validators unavailable (uv: {uv}, xmllint: {xmllint}); the SARIF \
        schema validations, the JUnit parser read-backs, the URI decode, and the XML \
        well-formedness checks pass vacuously — every in-repo check still runs"
  withScratchDir "reporting" fun work => do
      let ctx : Reporting.Ctx :=
        { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, work, uv,
          xmllint }
      let cases : Array Case :=
        #[{ name := "flag-surface", run := Reporting.testFlagSurface ctx },
          { name := "json-compat", run := Reporting.testJsonCompat ctx },
          { name := "exit-codes", run := Reporting.testExitCodes ctx },
          { name := "concise", run := Reporting.testConcise ctx },
          { name := "codepoint-columns", run := Reporting.testCodepointColumns ctx },
          { name := "github", run := Reporting.testGithub ctx },
          { name := "sarif", run := Reporting.testSarif ctx },
          { name := "junit", run := Reporting.testJunit ctx },
          { name := "output-files", run := Reporting.testOutputFiles ctx },
          { name := "broken-pipe", run := Reporting.testBrokenPipe ctx },
          { name := "stdin", run := discard <| Reporting.testStdin ctx },
          { name := "uris", run := Reporting.testUris ctx },
          { name := "astral-columns", run := Reporting.testAstral ctx },
          { name := "github-property-roundtrip", run := Reporting.testGithubRoundTrip ctx }]
      runCases "reporting" cases args
