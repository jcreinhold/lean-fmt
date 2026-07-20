#!/usr/bin/env bash
set -euo pipefail

# `ruff-15` RRF-IMPL — the machine-readable report formats.
#
# Every case drives the real executable, because what is under test is the bytes a CI system receives:
# the grammar, the escaping, the exit code, and where the report lands. The frozen contract is
# `docs/projects/ruff-15-reporting/notes/01-report-formats.md`; section numbers below refer to it.
#
# The three structured formats are checked with **independent parsers** rather than with our own
# string matching wherever one exists — a renderer and its bespoke checker can agree on the same
# mistake, and a real consumer is the thing we actually promise to satisfy.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
work=$(mktemp -d)
cleanup() { rm -rf "$work" "$repo_root/.lean-fmt-cache"; }
trap cleanup EXIT

failures=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else fail "$1: [$2] does not contain [$3]"; fi
}

LEAN_NUM_THREADS=1 lake build lean-fmt >/dev/null
application=$(lake -q query lean-fmt --text)
fmt() { "$application" "$@"; }
code() { set +e; fmt "$@" >/dev/null 2>&1; printf '%s' "$?"; set -e; }

findings=tests/check/Findings.lean
unicode=tests/reporting/Unicode.lean

printf -- '--- flag surface (§2) ---\n'

check "an unknown --output-format is rejected" \
  "$(fmt check "$findings" --output-format bogus 2>&1 >/dev/null | head -1)" \
  "unknown --output-format: bogus (expected text, concise, json, github, sarif, or junit)"
check "  ... with exit 2" "$(code check "$findings" --output-format bogus)" "2"

# §2.3 — a finding-shaped format for `diff`, whose product is a patch and which was *measured* to
# carry no findings at all. Rejected rather than rendered empty, following `ruff-14`'s precedent.
for format in concise github sarif junit; do
  check "--output-format $format is rejected for diff" \
    "$(fmt diff "$findings" --output-format "$format" 2>&1 >/dev/null | head -1)" \
    "--output-format $format is not available for diff; diff reports a patch, not findings"
done
check "--output-format json is still allowed for diff" \
  "$(code diff "$findings" --output-format json)" "0"

# §2.2 — two spellings of one choice. Agreement is fine; disagreement is an error, never a precedence
# rule, because a caller who typed two formats has no preference for us to guess.
check "--json with a disagreeing --output-format is rejected" \
  "$(fmt check "$findings" --json --output-format github 2>&1 >/dev/null | head -1)" \
  "--json and --output-format github disagree; pass only one"
check "--json with an agreeing --output-format is accepted" \
  "$(code check "$findings" --json --output-format json)" "1"

printf -- '--- json compatibility (§8.1) ---\n'

# The pre-change golden lives in evidence/ and `tests/check/run.sh` pins `--json` against it. Here we
# pin the *other* spelling: the two must be the same bytes, or the alias is not an alias.
fmt check --root . --no-cache --json "$findings" >"$work/via-json.json" 2>/dev/null || true
fmt check --root . --no-cache --output-format json "$findings" >"$work/via-format.json" 2>/dev/null || true
if cmp -s "$work/via-json.json" "$work/via-format.json"; then
  ok "--json and --output-format json produce identical bytes"
else
  fail "--json and --output-format json diverged"
fi
if cmp -s "$work/via-json.json" docs/projects/ruff-15-reporting/evidence/01-json-golden-check.json; then
  ok "--output-format json still reproduces the pre-change golden"
else
  fail "the JSON report changed shape"
fi

printf -- '--- exit codes are format-independent (§9.1) ---\n'

# The worst regression this stack could ship is a CI job that starts passing because it swapped a
# format in. Every format must agree with `text` on the verdict.
baseline=$(code check "$findings")
check "the baseline is the CI failure code" "$baseline" "1"
for format in concise json github sarif junit; do
  check "$format agrees with text on the exit code" "$(code check "$findings" --output-format "$format")" "$baseline"
done

printf -- '--- concise (§4) ---\n'

concise=$(fmt check "$findings" --output-format concise 2>/dev/null || true)
check "one line per finding, no summary line" "$(printf '%s\n' "$concise" | wc -l | tr -d ' ')" "1"
check "the grammar is PATH:LINE:COL: CODE MESSAGE" "$concise" \
  "tests/check/Findings.lean:4:1: FMT005 duplicate import of LeanFmt.Basic"
# `text` prints ` [safe]`; `concise` must not — an applicability tag is machine data and breaks an
# editor error-parser reading the line for a file:line:col jump.
if [[ "$concise" == *"[safe]"* ]]; then
  fail "concise leaked the applicability tag"
else
  ok "concise omits the applicability tag"
fi

printf -- '--- columns count code points, not bytes (§3.1) ---\n'

# Line 8 of the fixture is `def ünïcödéValue : Nat := ((1))`. Four of the characters before the
# redundant parenthesis are two bytes wide, so a byte column would report 31 and a codepoint column
# reports 27. This is the case that would silently pass if the conversion counted bytes.
unicode_concise=$(fmt check "$unicode" --select all --preview --output-format concise 2>/dev/null || true)
contains "a codepoint column is reported, not a byte column" "$unicode_concise" \
  "tests/reporting/Unicode.lean:8:27: FMT013"

printf -- '--- github (§5) ---\n'

github=$(fmt check "$findings" --output-format github 2>/dev/null || true)
check "one workflow command per finding" "$github" \
  "::warning title=lean-fmt (FMT005),file=tests/check/Findings.lean,line=4,col=1,endLine=4,endColumn=21::tests/check/Findings.lean:4:1: FMT005 duplicate import of LeanFmt.Basic"

# §5.3 — property values escape `:` and `,` beyond what the message escapes, because either would
# otherwise terminate the property list. `--stdin-filename` is an identity that need not exist
# (`ruff-14` §2), which is what lets a path this hostile be tested at all.
hostile='dir,with:punct/Buffer.lean'
printf 'module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n' >"$work/dup.lean"
hostile_out=$(fmt check - --stdin-filename "$hostile" --output-format github <"$work/dup.lean" 2>&1 >/dev/null || true)
contains "a path's ':' and ',' are escaped in the property list" "$hostile_out" \
  "file=dir%2Cwith%3Apunct/Buffer.lean"
# The message half uses the laxer `escapeData`, which leaves `:` and `,` alone. Both halves of the
# same line, escaped by different rules, is the behavior the runner actually specifies.
contains "the message half is not property-escaped" "$hostile_out" \
  "::dir,with:punct/Buffer.lean:4:1: FMT005"

# §5.2 — GitHub rejects an annotation carrying col/endColumn when line != endLine. A multi-line
# finding must therefore drop them. FMT013's range spans the parenthesized expression.
printf 'module\n\nimport LeanFmt.Basic\n\ndef spanning : Nat := ((\n  1\n  ))\n' >"$work/multiline.lean"
multi=$(fmt check - --stdin-filename "tests/reporting/Multiline.lean" --select FMT013 --preview \
  --output-format github <"$work/multiline.lean" 2>&1 >/dev/null || true)
if [[ "$multi" == *"col="* ]]; then
  fail "a multi-line annotation kept col=, which GitHub rejects: $multi"
else
  ok "a multi-line annotation omits col/endColumn"
fi
contains "  ... but still carries line and endLine" "$multi" "line=5,endLine=7"

printf -- '--- sarif (§6) ---\n'

fmt check "$findings" --output-format sarif >"$work/report.sarif" 2>/dev/null || true

# An independent validator, not our own string matching.
if uv run --with check-jsonschema --quiet check-jsonschema \
    --schemafile tests/reporting/sarif-schema-2.1.0.json "$work/report.sarif" >"$work/sarif.log" 2>&1; then
  ok "the SARIF log validates against the 2.1.0 JSON schema"
else
  fail "SARIF schema validation failed: $(tail -3 "$work/sarif.log")"
fi

# §3.4 — the schema does NOT encode the `columnKind` SHALL, so a green schema check is not a
# conformance result. These assertions are the difference.
sarif_assert() {
  uv run --quiet python3 - "$work/report.sarif" <<'PY'
import json, sys
log = json.load(open(sys.argv[1]))
run, = log["runs"]
assert log["version"] == "2.1.0", log["version"]
# §3.14.27: SHALL be present when results are non-empty, and it must name the encoding we actually use.
assert run["results"], "the fixture produced no results, so the assertions are vacuous"
assert run["columnKind"] == "unicodeCodePoints", run.get("columnKind")
# §3.30.4: a text region must not carry binary properties. Ours are normalized-source byte offsets,
# which are neither charOffset nor byteOffset, so they belong in the property bag and nowhere else.
region, = [loc["physicalLocation"]["region"] for loc in run["results"][0]["locations"]]
assert "charOffset" not in region and "byteOffset" not in region, region
assert region["properties"]["leanFmtNormalizedByteRange"] == {"start": 29, "stop": 49}, region
assert (region["startLine"], region["startColumn"]) == (4, 1), region
assert (region["endLine"], region["endColumn"]) == (4, 21), region
# Every reported ruleId has a descriptor: a result naming a rule the tool did not describe is a log a
# viewer cannot explain.
described = {r["id"] for r in run["tool"]["driver"]["rules"]}
for result in run["results"]:
    assert result["ruleId"] in described, (result["ruleId"], described)
# §3.20.21 — the invocation, not a result, is what says whether the run completed.
invocation, = run["invocations"]
assert invocation["executionSuccessful"] is True, invocation
assert invocation["toolExecutionNotifications"] == [], invocation
assert run["originalUriBaseIds"]["%SRCROOT%"]["uri"].startswith("file:///"), run["originalUriBaseIds"]
print("ok")
PY
}
check "the SARIF log conforms beyond the schema" "$(sarif_assert)" "ok"

# The descriptor text is projected from the live rule catalog, never re-authored in the renderer.
summary=$(fmt explain FMT005 --json 2>/dev/null | uv run --quiet python3 -c \
  'import json,sys; print(json.load(sys.stdin)["summary"])' || true)
described=$(uv run --quiet python3 -c \
  'import json,sys; log=json.load(open(sys.argv[1])); r,=log["runs"]; print(r["tool"]["driver"]["rules"][0]["shortDescription"]["text"])' \
  "$work/report.sarif")
check "a rule descriptor matches the catalog's own summary" "$described" "$summary"

# §6.5 — an infrastructure failure is a notification and flips executionSuccessful, so the log agrees
# with exit code 2 instead of looking like a clean run that found nothing.
LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false fmt check --root . --no-cache \
  --output-format sarif tests/check/Clean.lean >"$work/failed.sarif" 2>/dev/null || true
failed_assert=$(uv run --quiet python3 - "$work/failed.sarif" <<'PY'
import json, sys
run, = json.load(open(sys.argv[1]))["runs"]
invocation, = run["invocations"]
assert invocation["executionSuccessful"] is False, invocation
assert invocation["toolExecutionNotifications"], invocation
assert all(n["level"] == "error" for n in invocation["toolExecutionNotifications"])
print("ok")
PY
)
check "an aborted run reports executionSuccessful=false" "$failed_assert" "ok"
# The log and the exit code must say the same thing: §6.5 exists so a consumer cannot read "no
# results" as "clean" on a run that never completed.
set +e
LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false fmt check --root . --no-cache \
  --output-format sarif tests/check/Clean.lean >/dev/null 2>&1
aborted_code=$?
set -e
check "  ... and the same run exits 2" "$aborted_code" "2"

printf -- '--- junit (§7) ---\n'

fmt check "$findings" --output-format junit >"$work/report.xml" 2>/dev/null || true
if xmllint --noout "$work/report.xml" 2>"$work/xml.log"; then
  ok "the JUnit report is well-formed XML"
else
  fail "JUnit XML is malformed: $(cat "$work/xml.log")"
fi

# An independent JUnit *consumer*, which is what a CI system actually runs. §8.2 records why this
# replaced an XSD check: the format has no normative schema, and the most-cited XSD is one flavor
# that requires a `time` this report has no measurement for.
junit_assert=$(uv run --with junitparser --quiet python3 - "$work/report.xml" <<'PY'
import sys
from junitparser import JUnitXml
xml = JUnitXml.fromfile(sys.argv[1])
cases = [(suite.name, case.name, [r.type for r in case.result]) for suite in xml for case in suite]
assert cases == [("tests/check/Findings.lean",
                  "FMT005 tests/check/Findings.lean:4:1", ["FMT005"])], cases
assert (xml.tests, xml.failures, xml.errors) == (1, 1, 0), (xml.tests, xml.failures, xml.errors)
print("ok")
PY
)
check "an independent JUnit parser reads it back" "$junit_assert" "ok"

# A clean file emits a *passing* case, not an empty suite: a suite with zero cases reads to most CI
# dashboards as "no tests ran" rather than "nothing wrong".
fmt check tests/check/Clean.lean --output-format junit >"$work/clean.xml" 2>/dev/null || true
clean_assert=$(uv run --with junitparser --quiet python3 - "$work/clean.xml" <<'PY'
import sys
from junitparser import JUnitXml
xml = JUnitXml.fromfile(sys.argv[1])
cases = [(case.name, list(case.result)) for suite in xml for case in suite]
assert len(cases) == 1 and cases[0][1] == [], cases
assert (xml.tests, xml.failures, xml.errors) == (1, 0, 0), (xml.tests, xml.failures, xml.errors)
print("ok")
PY
)
check "a clean file emits a passing case, not an empty suite" "$clean_assert" "ok"

# §7.3 — XML escaping. `--stdin-filename` again supplies a path no filesystem has to accept.
xml_hostile=$(fmt check - --stdin-filename 'a&b<c>d.lean' --output-format junit <"$work/dup.lean" 2>&1 >/dev/null || true)
contains "XML metacharacters in a path are escaped" "$xml_hostile" "a&amp;b&lt;c&gt;d.lean"
if printf '%s' "$xml_hostile" | xmllint --noout - 2>/dev/null; then
  ok "  ... and the result is still well-formed"
else
  fail "a hostile path produced malformed XML"
fi

printf -- '--- output files (§2.4, §9.2) ---\n'

check "a missing --output-file directory is rejected before the run" \
  "$(fmt check "$findings" --output-file "$work/absent/report.json" --json 2>&1 >/dev/null | head -1)" \
  "--output-file directory does not exist: $work/absent/report.json"
check "  ... with exit 2" "$(code check "$findings" --output-file "$work/absent/report.json" --json)" "2"
check "a directory --output-file is rejected" \
  "$(fmt check "$findings" --output-file "$work" --json 2>&1 >/dev/null | head -1)" \
  "--output-file is a directory: $work"

stdout_bytes=$(fmt check "$findings" --output-file "$work/out.sarif" --output-format sarif 2>/dev/null | wc -c | tr -d ' ' || true)
check "--output-file leaves stdout empty" "$stdout_bytes" "0"
if uv run --with check-jsonschema --quiet check-jsonschema \
    --schemafile tests/reporting/sarif-schema-2.1.0.json "$work/out.sarif" >/dev/null 2>&1; then
  ok "  ... and the file holds the complete report"
else
  fail "--output-file wrote an invalid report"
fi
check "  ... and the exit code is unchanged" \
  "$(code check "$findings" --output-file "$work/out2.sarif" --output-format sarif)" "1"

# Atomic replacement: the temporary must not survive, and a previous report must not be truncated in
# place. Both are what a CI job polling the path depends on.
if [[ -e "$work/out.sarif.lean-fmt-tmp" ]]; then
  fail "the atomic write left its temporary behind"
else
  ok "the atomic write leaves no temporary"
fi

printf -- '--- broken pipe (§9.3) ---\n'

# `… | head -1` is the standard idiom. It must not print a diagnostic — and must NOT be turned into a
# success, which would make the pipe a way to silence CI.
for format in text concise json github sarif junit; do
  set +e
  pipe_err=$(fmt check "$findings" --output-format "$format" 2>&1 >/dev/null | head -1)
  producer=$( { fmt check "$findings" --output-format "$format" 2>/dev/null | head -1 >/dev/null; } ; echo "${PIPESTATUS[0]}")
  set -e
  check "$format survives a closed pipe with its own exit code" "$producer" "1"
  if [[ -n "$pipe_err" ]]; then
    fail "$format printed a diagnostic on a closed pipe: $pipe_err"
  else
    ok "  ... and prints no diagnostic"
  fi
done

printf -- '--- stdin (§2.5) ---\n'

# stdout still carries the result and nothing else (`ruff-14` §5.1), so a finding-shaped report goes
# to stderr — putting it on stdout would corrupt the bytes a `format -` consumer is piping.
stream_stdout=$(fmt check - --stdin-filename tests/reporting/Buffer.lean --output-format concise <"$work/dup.lean" 2>/dev/null || true)
check "a stdin report does not reach stdout" "$stream_stdout" ""
stream_stderr=$(fmt check - --stdin-filename tests/reporting/Buffer.lean --output-format concise <"$work/dup.lean" 2>&1 >/dev/null || true)
check "a stdin report reaches stderr with resolved positions" "$stream_stderr" \
  "tests/reporting/Buffer.lean:4:1: FMT005 duplicate import of LeanFmt.Basic"

# CRLF: every offset indexes the CRLF-normalized source, so a line/column resolved from it must match
# the LF twin exactly. Delivered through stdin because git would not keep a CRLF fixture on disk.
printf 'module\r\n\r\nimport LeanFmt.Basic\r\nimport LeanFmt.Basic\r\n' >"$work/crlf.lean"
crlf=$(fmt check - --stdin-filename tests/reporting/Buffer.lean --output-format concise <"$work/crlf.lean" 2>&1 >/dev/null || true)
check "a CRLF buffer resolves to the same line and column as its LF twin" "$crlf" "$stream_stderr"

if [[ $failures -ne 0 ]]; then
  printf 'lean-fmt reporting tests failed (%s)\n' "$failures" >&2
  exit 1
fi
printf 'lean-fmt reporting format tests passed\n'
