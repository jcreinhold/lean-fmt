# Report formats — the RRF-SPEC freeze

Owner: `ruff-15-reporting` prompt `01-schema` (claim `RRF-SPEC`).

Prerequisites re-read live for this freeze: `LeanFmt/Cli.lean`, `LeanFmt/Application.lean`,
`LeanFmt/Rules.lean`, `LeanFmt/ArtifactModel.lean`, `LeanFmt/LosslessSource.lean`, `tests/check/run.sh`,
`tests/modes/run.sh`, `tests/boundary/run.sh`. Prerequisite stacks `ruff-12-rule-lifecycle` and
`ruff-13-config-discovery` both record `first_unresolved: none`; `ruff-14-stream-range`, which froze the
position encoding this stack inherits, likewise.

Following the `*-SPEC` convention (`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC, `ruff-13` RCD-SPEC,
`ruff-14` RSF-SPEC), this prompt ships **no production Lean interface, config key, or CLI surface.** It
ships this freeze, the measured baseline, and the characterization test pinning its central
compatibility claim.

External sources are quoted, not paraphrased, and each is named at the point of use. Where a format has
no specification, this note says so rather than inventing authority for it.

---

## 1. What exists today

Measured, not assumed (`evidence/01-report-baseline.md`).

| Form | Today |
| --- | --- |
| `lean-fmt check F.lean` | one `path:START-STOP: CODE message [applicability]` line per finding, then one `mode=… files=… findings=…` summary line, exit 1 |
| `lean-fmt check F.lean --json` | the whole `RunReport` as compressed JSON on stdout, exit 1 |
| `lean-fmt check F.lean --output-format json` | `unknown option: --output-format`, exit 2 |
| `lean-fmt check F.lean --output-file X` | `unknown option: --output-file`, exit 2 |

So there are exactly **two** report renderings, `text` and `json`, selected by the boolean `--json`
(`Cli.lean:11-13` `ReportFormat`, `Cli.lean:353-356` `renderReport`). There is no output-file surface,
no line/column in any report, and no format-specific escaping anywhere.

Three facts from the baseline are load-bearing for everything below.

**1.1 — Every position in the product is a normalized-source byte offset.** `Finding.range` is a
`SourceRange` of half-open byte offsets into `raw.crlfToLf` (`ArtifactModel.lean:76-82`; the coordinate
system is a repository-wide invariant, `CLAUDE.md`). No report carries a line, a column, or a character
offset. Every format in this stack except `json` needs line/column, so **every one of them needs a
conversion that does not exist yet.** That is this stack's single largest implementation obligation and
it is named here rather than discovered mid-implementation.

**1.2 — Report paths are already root-relative.** `lean-fmt check "$PWD/tests/check/Findings.lean"`
reports `path: "tests/check/Findings.lean"`. An absolute argument comes back relativized against the
run root, so a URI-based format has a well-defined base and needs no path guessing.

**1.3 — Modes do not all carry findings.** Measured per mode on the same fixture:

| Mode | `files[].findings` | `files[].diff` | `files[].status` |
| --- | --- | --- | --- |
| `check` | populated | `null` | `findings` |
| `fix` | populated | `null` | `fixed` |
| `format --check` | populated | `null` | `clean` / `would-format` |
| `diff` | **empty** | the unified diff | `clean` / `would-format` |

`diff`'s product is a patch, not a finding set. §2.3 rejects the finding-shaped formats for it rather
than emitting an empty SARIF log that would read as "clean".

---

## 2. CLI surface

```
lean-fmt {check|format|fix} [--output-format FORMAT] [--output-file PATH] [OPTIONS] [FILE...]
lean-fmt diff             [--output-format {text|json}] [--output-file PATH] [OPTIONS] [FILE...]
```

### 2.1 `--output-format FORMAT`

`FORMAT` is one of `text`, `concise`, `json`, `github`, `sarif`, `junit`. Default `text`.

**`text` names the existing default and its bytes do not change.** This is a deliberate rejection of
ruff's naming, where the default is `full` and renders a source excerpt with a caret. lean-fmt's text
report renders no excerpt, so calling it `full` would promise a rendering this stack is not building;
and renaming the current default would break every golden test in `tests/check`, `tests/modes`,
`tests/suppression`, and `tests/syntax` for no user-visible gain. `concise` is a **new, additional**
format (§4), not a rename of the old one.

### 2.2 `--json` is retained as an exact alias

`--json` continues to mean `--output-format json` and continues to produce **byte-identical** output to
today's `--json`. It is not deprecated in this stack: it is also the flag on `rules`, `explain`,
`clean`, `compiler`, `organize`, and `config show`, none of which gain `--output-format` (they render
catalogs and status, not reports; a SARIF log of the rule catalog is meaningless). Deprecating it on
run commands alone would leave one flag meaning two different things depending on the subcommand.

Both flags together are accepted when they agree (`--json --output-format json`) and are an error when
they disagree:

```
--json and --output-format github disagree; pass only one
```

exit 2. Silently letting one win is how a CI pipeline gets the wrong format for a year.

### 2.3 Which modes accept which formats

| Mode | `text` | `concise` | `json` | `github` | `sarif` | `junit` |
| --- | --- | --- | --- | --- | --- | --- |
| `check` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `format` (writing or `--check`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `fix` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `diff` | ✓ | **rejected** | ✓ | **rejected** | **rejected** | **rejected** |

Rejection message, exit 2:

```
--output-format concise is not available for diff; diff reports a patch, not findings
```

This follows `ruff-14`'s frozen precedent — *reject a flag for a mode that cannot honor it* (`ruff-14`
`results/03-acceptance.md`, `--range` for non-honoring modes) — rather than emitting a well-formed,
empty, and misleading report. `json` stays available for `diff` because the JSON report is the whole
`RunReport` including `files[].diff`, which is exactly what a `diff` consumer wants.

### 2.4 `--output-file PATH`

Writes the rendered report to `PATH` instead of stdout. Available for every mode and every format,
including `text`.

- The **report** goes to the file. Everything that is not the report keeps its current stream:
  `--statistics` stays on stderr (`Cli.lean:358-362`), infrastructure error text stays on stderr, and
  `format`/`fix` still publish source in place.
- `diff`'s patch **is** its report, so with `--output-file` the patch goes to the file and stdout is
  empty.
- The path is pre-checked and named in its own error, per the repository's path-error rule
  (`CLAUDE.md`: "Path errors name the caller's own argument"):

  ```
  --output-file directory does not exist: build/reports/out.sarif
  ```

  exit 2, *before* analysis runs. A run that takes four minutes and then cannot write its report has
  wasted the four minutes.
- The write is **atomic**: render fully into memory, write a sibling temporary, `rename` into place.
  A consumer that polls the path never observes a truncated SARIF log, and a failed render leaves the
  previous report intact rather than a half-file. This reuses the publication discipline already frozen
  for source writes; it does **not** reuse the source publication path itself, which additionally does
  stale-source checking and validation that a report has no analogue for.
- An existing `PATH` is replaced. A `PATH` that exists and is a directory is the pre-check error above.

### 2.5 stdin/stream mode

`--output-format` is accepted for `-` targets and means the same thing, with one substitution already
frozen by `ruff-14` §5.1: **stdout carries the result and nothing else** for `format -`/`fix -`. So for
a stdin target, `concise`/`github`/`sarif`/`junit` render to **stderr** (where `ruff-14` already puts
findings) unless `--output-file` is given, in which case they render to the file and stderr stays
clean. `json` keeps `ruff-14`'s behavior — the whole answer on stdout — because that is the frozen
contract a `ruff-17-lsp` consumer will read.

---

## 3. Position encoding

### 3.1 The one conversion

Every finding-shaped format needs `(line, column)` for the start and the end of a
`SourceRange { start, stop }` of half-open **normalized-source byte offsets**.

**Lines are 1-based. Columns are 1-based and counted in Unicode code points.** This is not a new
decision; it is `ruff-14`'s frozen convention for `--range-lines`, whose `offsetOfLineColumn`
(`Cli.lean:49-73`) already walks `\n` for lines and UTF-8 lead bytes for codepoint columns. Reusing it
means the encoding a caller *sends* and the encoding a report *returns* are the same encoding. UTF-16
remains `ruff-17-lsp`'s to negotiate at its own boundary.

The conversion is the exact inverse of `offsetOfLineColumn` and RRF-IMPL must ship it as one shared
function used by all four formats. Four independent conversions is four places for the off-by-one.

### 3.2 A half-open byte range converts directly, and that is not a coincidence

Convert `start` and `stop` **each** to a `(line, column)` position by the same inverse. Then:

- `startLine`, `startColumn` := position of `start`
- `endLine`, `endColumn` := position of `stop`

Because `stop` is exclusive, its position is already "one past the last character", which is exactly
what SARIF requires of `endColumn`:

> "3.30.8 endColumn property — When a region object represents a text region specified by line/column
> properties, it MAY contain a property named endColumn whose value is an integer whose value is one
> greater than the column number of the last character in the region."
> — SARIF 2.1.0 §3.30.8

A range ending exactly at a line start therefore yields `endColumn: 1` on the following line, which the
spec confirms is how one names a region that includes the newline:

> "To specify an entire line together with its trailing newline sequence, specify the region's end
> point to be column 1 on the next line." — SARIF 2.1.0 §3.30.2, NOTE 6

And a zero-width range yields `startColumn == endColumn`, which the spec confirms is an insertion
point (§3.30.2, EXAMPLE 6). So one conversion covers ordinary findings, whole-line findings, and
zero-width insertion findings with no special cases. RRF-IMPL should pin all three in a golden test.

### 3.3 Byte offsets are NOT emitted as SARIF `byteOffset` or `charOffset`

Two independent reasons, both fatal:

1. **`charOffset` is a character offset, ours is a byte offset.** SARIF §3.30.9: "the zero-based
   *character* offset of the first character in the region". `range.start` equals a character offset
   only on pure-ASCII files. Emitting it would silently misplace every finding in a file with a single
   non-ASCII identifier — and Lean source is full of them.
2. **`byteOffset` is an offset into the *artifact*, ours is an offset into the *normalized* source.**
   A CRLF file's on-disk bytes are not the bytes our offsets index (`CLAUDE.md`: every compiler-produced
   offset indexes `raw.crlfToLf`). Beyond the encoding mismatch, SARIF forbids mixing them anyway:

   > "3.30.4 Independence of text and binary regions — The text-related and binary-related properties
   > in a region object SHALL be treated independently. That is, the value of a text-related property
   > SHALL NOT be inferred from the value of any set of binary-related properties, and vice versa."

   with an EXAMPLE showing that a region carrying both is *invalid* when they disagree.

**Frozen: SARIF `region` objects carry line/column properties only.** The normalized byte range travels
in the region's property bag, which §3.8.1 explicitly permits ("every object defined in this document
MAY contain a property named `properties` whose value is a property bag ... information about each
object that is not explicitly specified in the SARIF format"), under a name that says what it is:

```json
"properties": { "leanFmtNormalizedByteRange": { "start": 29, "stop": 49 } }
```

A consumer that wants exact bytes gets them; a conforming SARIF viewer ignores them; and nothing claims
a byte offset is a character offset.

### 3.4 `columnKind` is mandatory and we would have missed it

> "3.14.27 columnKind property — If a SARIF producer processes text artifacts and theRun.results is
> non-empty, the run object **SHALL** contain a property named columnKind whose value is a string that
> specifies the unit in which the analysis tool measures columns. ... `"unicodeCodePoints"`: Each
> Unicode code point (abstract character) is considered to occupy one column."

So `run.columnKind` is `"unicodeCodePoints"` — a **SHALL**, not a nicety, and it happens to name
`ruff-14`'s frozen convention exactly. A SARIF log from this product without `columnKind` is
non-conforming even though every validator that only checks the JSON schema would pass it. RRF-FINAL's
independent-validator gate must therefore include a conformance check, not only a schema check (§8).

---

## 4. `concise`

One line per finding, no summary line, nothing else on stdout.

```
tests/check/Findings.lean:4:1: FMT005 duplicate import of LeanFmt.Basic
```

Grammar: `PATH:LINE:COLUMN: CODE MESSAGE`, where `PATH` is the report path verbatim (root-relative,
§1.2), `LINE:COLUMN` is the **start** position only, and `MESSAGE` is the finding message with any
newline replaced by a space.

Frozen decisions:

- **No summary line.** `text` prints `mode=… files=…`; `concise` does not. The format exists to be
  piped into `grep`, `awk`, and editor error parsers, and a trailing line that does not match the
  grammar is exactly what breaks them.
- **No applicability tag.** `text` prints ` [safe]`; `concise` does not. Fix applicability is machine
  data and belongs in `json`/`sarif` (§6.4), not in a line an editor parses for a file:line:col jump.
- **No end position.** One position, because every editor error-parser convention reads one.
- **Messages are single-line by construction.** No live rule message contains a newline; the
  replacement is a defensive normalization, and RRF-IMPL pins it with a synthetic finding rather than
  assuming the invariant holds forever.
- **Infrastructure failures print** as `PATH: STATUS: DIAGNOSTIC` for file-level diagnostics and
  `lean-fmt: MESSAGE` for run-level ones, matching the two shapes the report already distinguishes
  (`FileReport.diagnostics` vs `RunReport.infrastructureFailures`).
- **`format`/`fix` statuses print** as `PATH:1:1: format FILE would be reformatted` (§7 fixes the
  `format` identity). Position `1:1` because the status is a property of the file, not of a span, and
  omitting the position would break the grammar.

---

## 5. `github`

One GitHub Actions workflow command per finding, on stdout.

```
::warning title=lean-fmt (FMT005),file=tests/check/Findings.lean,line=4,col=1,endLine=4,endColumn=21::tests/check/Findings.lean:4:1: FMT005 duplicate import of LeanFmt.Basic
```

### 5.1 Severity → command

`Severity.error` → `::error`, `.warning` → `::warning`, `.information` → `::notice`. Infrastructure
failures are always `::error`.

### 5.2 The multi-line constraint

**`col` and `endColumn` are omitted whenever `line != endLine`.** GitHub rejects the annotation
otherwise. This is not in GitHub's own documentation — the workflow-commands page documents `col` and
`endColumn` as independent optional parameters and says nothing about the interaction. It is recorded
in ruff's renderer:

```rust
// GitHub Actions workflow commands have constraints on error annotations:
// - `col` and `endColumn` cannot be set if `line` and `endLine` are different
// See: https://github.com/astral-sh/ruff/issues/22074
```
— `crates/ruff_db/src/diagnostic/render/github.rs`

Multi-line findings are common here (FMT005 spans an import line; a layout finding can span a
declaration), so this is an ordinary case, not an edge case. RRF-IMPL pins both branches.

### 5.3 Escaping

Exact, from the GitHub Actions toolkit that defines the format
(`actions/toolkit`, `packages/core/src/command.ts`):

```js
function escapeData(s)     { return s.replace(/%/g,'%25').replace(/\r/g,'%0D').replace(/\n/g,'%0A') }
function escapeProperty(s) { return s.replace(/%/g,'%25').replace(/\r/g,'%0D').replace(/\n/g,'%0A')
                                     .replace(/:/g,'%3A').replace(/,/g,'%2C') }
```

- The **message** (after `::`) uses `escapeData`.
- Every **property value** (`title`, `file`, and the numbers) uses `escapeProperty`. The extra `:` and
  `,` matter: a path containing either would otherwise terminate the property list. Paths with `:` are
  legal on macOS and Linux and this is the only thing standing between one of them and a corrupt
  annotation stream.
- `%` is replaced **first** in both. Replacing it later would double-escape the `%` introduced by the
  `\r`/`\n` replacements.

The same source shows the runner's property emitter skips falsy values (`if (val)`), so a `0` would be
dropped silently. Our lines and columns are 1-based and never `0`, so this cannot bite — recorded
because it would be invisible if it ever did.

### 5.4 The message repeats the location

The message body begins with `PATH:LINE:COLUMN: ` before the code and text, following ruff's renderer.
GitHub attaches an annotation to a file only when the workflow can resolve it; when it cannot, the
annotation still appears in the log, and without the prefix it would name no file at all.

---

## 6. `sarif`

One SARIF 2.1.0 log on stdout, pretty-printed with two-space indentation (a SARIF log is read by
humans in review often enough that compressed output is hostile, and it is written once per run so the
size does not matter).

### 6.1 Skeleton

```json
{
  "version": "2.1.0",
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
  "runs": [ { "tool": …, "invocations": [ … ], "originalUriBaseIds": …, "columnKind": "unicodeCodePoints", "results": [ … ] } ]
}
```

`version` **SHALL** be `"2.1.0"` and **SHOULD** appear first (§3.13.2); `runs` **SHALL** be present
(§3.13.4); the `$schema` URI is the one the spec itself names (§3.13.3, NOTE 2). Exactly one run.

### 6.2 `tool.driver`

```json
"driver": {
  "name": "lean-fmt",
  "informationUri": "https://github.com/jcreinhold/lean-fmt",
  "rules": [ … one reportingDescriptor per rule in the ACTIVE selection … ]
}
```

`rules` is projected from the existing `RuleInfo` catalog through `Rules.ruleInfoJson`'s source data —
**not** re-authored here. `docs/adding-a-rule.md` and `ruff-12` make one metadata source the invariant;
a second hand-written description table in the SARIF renderer is exactly the drift `ruff-12` closed.

| SARIF | `RuleInfo` |
| --- | --- |
| `id` | `code` |
| `name` | `code` (lean-fmt has no separate camel-case rule name) |
| `shortDescription.text` | `summary` |
| `fullDescription.text` | `explanation` |
| `helpUri` | the generated rule page for `code` under `docs/rules/` |
| `defaultConfiguration.level` | §6.3 |
| `properties.tags` | `[category]` |
| `properties.lifecycle` | `lifecycle` (`stable`/`preview`/`deprecated`) |
| `properties.fixable` | `fixable` |

**`rules` lists the active selection, not the whole catalog.** A descriptor for a rule that could not
have fired describes a run that did not happen.

### 6.3 Severity → `level`

`Severity.error` → `"error"`, `.warning` → `"warning"`, `.information` → `"note"`. SARIF's fourth
level `"none"` is never emitted: it means a trace notification, which no finding is.

### 6.4 `result`

```json
{
  "ruleId": "FMT005",
  "level": "warning",
  "message": { "text": "duplicate import of LeanFmt.Basic" },
  "locations": [ { "physicalLocation": {
      "artifactLocation": { "uri": "tests/check/Findings.lean", "uriBaseId": "%SRCROOT%" },
      "region": { "startLine": 4, "startColumn": 1, "endLine": 4, "endColumn": 21,
                  "properties": { "leanFmtNormalizedByteRange": { "start": 29, "stop": 49 } } } } } ],
  "properties": { "fixApplicability": "safe" }
}
```

- `uri` is the root-relative report path (§1.2), percent-encoded per RFC 3986 path-segment rules, with
  `uriBaseId: "%SRCROOT%"`. `run.originalUriBaseIds["%SRCROOT%"].uri` is the absolute `file://` URI of
  the run root, with a trailing `/`. This is the shape GitHub code scanning consumes and it keeps the
  log portable between machines.
- **Fixes ride `properties.fixApplicability`, not `result.fixes`.** SARIF has a `fixes` property
  carrying replacement text, and it is tempting. It is rejected for this stack: a SARIF `fix` names
  artifact regions in *character* offsets or line/column, our edits are normalized *byte* ranges, and
  §3.30.4 forbids the mixed region that would let us state both. Emitting fix *edits* correctly means
  converting every edit range through the same conversion and re-deriving replacement text against the
  artifact's on-disk encoding — a second write-shaped surface with its own correctness burden and no
  named consumer. `--output-format json` already carries exact edits for anyone who wants them.
  Recorded as a deliberate narrowing, not an oversight. It stands until a consumer for SARIF fixes is
  named. `ruff-18-integrations` was that stack; its 2026-07-21 narrowing to CI recipes and installation
  documentation gives it no editor or tooling deliverable that would want them, so reopening this needs
  a new stack and a real consumer.
- Suppressed findings do not appear. They are not in the canonical report (`FileReport.suppressed` is a
  count, not a list), so SARIF's `suppressions` property (§3.35) has no data to carry and stating one
  would be inventing a field the report does not have — a stop rule of this prompt. The count travels
  in `run.properties` (§6.6).

### 6.5 Infrastructure failures are notifications, not results

```json
"invocations": [ {
  "executionSuccessful": false,
  "toolExecutionNotifications": [
    { "level": "error", "message": { "text": "…" },
      "locations": [ { "physicalLocation": { "artifactLocation": { "uri": "…", "uriBaseId": "%SRCROOT%" } } } ] } ] } ]
```

This is the spec's own home for them:

> "3.20.21 toolExecutionNotifications property — ... The presence within this array of any notification
> object whose level property is `"error"` **SHALL** mean that the run failed. A SARIF consumer SHALL
> NOT assume that a failed run contains a complete set of analysis results."

That last sentence is the whole reason not to model an infrastructure failure as a `result`: a consumer
must be able to tell "the analysis found nothing" from "the analysis did not complete", and a `result`
cannot say the second. It also makes the SARIF log agree with the exit code — `executionSuccessful:
false` exactly when `reportExitCode` returns 2 (`Cli.lean:368-371`).

File-level diagnostics (`FileReport.diagnostics`, e.g. a broken or rejected file) become notifications
with a location; run-level ones (`RunReport.infrastructureFailures`) become notifications without one.

### 6.6 Counts

`run.properties` carries the summary counts the text report prints, under their existing wire names:
`findings`, `changed`, `written`, `broken`, `rejected`, `withheldUnsafe`, `suppressed`,
`withheldRedundant`. Property bags are the sanctioned place for tool-specific data (§3.8.1) and these
are the numbers a CI dashboard graphs.

---

## 7. `junit`

### 7.1 There is no JUnit specification, and the note says so

> "There is no official specification for the JUnit XML file format and various tools generate and
> support different flavors of this format. The goal of this project here is to document a common set
> of elements, attributes and conventions supported by many tools."
> — `testmoapp/junitxml`, the reference this stack targets

So the `junit` format targets **that documented common subset**, and RRF-FINAL validates
well-formedness plus a community XSD (§8), never "the JUnit spec". Claiming a conformance that does not
exist is the failure mode here.

### 7.2 Shape

One `<testsuite>` per file, one `<testcase>` per finding, `<failure>` inside a failing case.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="lean-fmt" tests="1" failures="1" errors="0">
  <testsuite name="tests/check/Findings.lean" tests="1" failures="1" errors="0">
    <testcase name="FMT005 tests/check/Findings.lean:4:1" classname="tests/check/Findings.lean">
      <failure message="duplicate import of LeanFmt.Basic" type="FMT005">tests/check/Findings.lean:4:1: FMT005 duplicate import of LeanFmt.Basic</failure>
    </testcase>
  </testsuite>
</testsuites>
```

- `classname` is the file path; `name` is `CODE PATH:LINE:COLUMN`, which is unique within a file even
  when one rule fires twice, and stable across runs so a CI history lines up.
- **A clean file emits a passing `<testcase>`** named after the file, with no child element. A
  `<testsuite>` with zero cases reads to most CI dashboards as "no tests ran", not "nothing wrong".
- **Infrastructure failures are `<error>`, findings are `<failure>`.** The distinction is the one JUnit
  consumers already draw between "the assertion failed" and "the test could not run", which is exactly
  the distinction §6.5 makes for SARIF and `reportExitCode` makes for exit codes. Run-level failures go
  in a synthetic `<testsuite name="lean-fmt">`.
- No `time` attributes. The report carries no per-file timing, and inventing `time="0"` would be a
  fabricated measurement.

### 7.3 XML escaping

Text and attribute values escape `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;` in attribute
values, and `'` → `&apos;` in attribute values. `&` **first**, for the same reason `%` goes first in
§5.3.

XML 1.0 cannot represent most C0 control characters at all — not even escaped. Any character below
U+0020 other than tab (U+0009), LF (U+000A), and CR (U+000D) is replaced by U+FFFD. This cannot arise
from a rule message today, but it can arise from a **path**, and a single stray control byte in a
filename would otherwise make the entire report unparseable. RRF-IMPL pins this with a synthetic case.

---

## 8. Schema compatibility and validation

### 8.1 The `json` compatibility contract

`--output-format json` and `--json` produce **byte-identical output to today's `--json`**, field for
field, including key order (`Lean.toJson`'s derived instance sorts keys). This stack adds no field to,
removes no field from, and reorders nothing in `RunReport` or `FileReport`.

That is a testable claim, and RRF-IMPL owns the test: a golden JSON file recorded **now**, in this
prompt, from the current binary (`evidence/01-report-baseline.md` §2), which the implementation must
still reproduce. A compatibility promise with no artifact from before the change is not a promise.

**No schema version field is added.** The report has never carried one, and adding one *is itself* a
breaking change to every consumer that compares the object. If a future stack must break the shape, the
migration is a new field with a default plus a version at that time; this stack is not that stack and
must not spend the compatibility budget it does not need.

### 8.2 Independent validation is RRF-FINAL's gate, and the tools exist

Checked available on this machine (`evidence/01-report-baseline.md` §4): `uv` 0.11.28, `jq` 1.x,
`xmllint`, `python3`. Neither `jsonschema` nor `check-jsonschema` is installed; both are reachable
through `uv run --with`, so RRF-FINAL needs no new system dependency.

| Format | Independent validator | Checks |
| --- | --- | --- |
| `json` | `jq` + the recorded golden | parses; byte-identical to the pre-change golden |
| `sarif` | `uv run --with check-jsonschema` against `sarif-schema-2.1.0.json` | schema conformance |
| `sarif` | a conformance assertion beyond the schema | `columnKind` present (§3.4), `executionSuccessful` agrees with the exit code, every `ruleId` has a descriptor |
| `junit` | `xmllint --noout`, plus `uv run --with junitparser` | well-formed; an **independent consumer** reads back every suite, case, result type, and count |
| `github` | a line-grammar parser plus round-trip unescaping | every line re-parses; unescaping `escapeProperty` recovers the exact path |
| `concise` | a line-grammar parser | every line matches `PATH:LINE:COL: CODE MSG` |

The SARIF schema check alone is **not** sufficient (§3.4): the schema does not encode the `columnKind`
**SHALL**, so a schema-valid log can still be non-conforming. This is named here so RRF-FINAL does not
mistake a green `check-jsonschema` for a conformance result.

**Amended during RRF-IMPL — the JUnit gate is a consumer, not an XSD.** The first draft named
`xmllint --schema` against "a community XSD". Measured against the most-cited one (windyroad
`JUnit.xsd`, the Apache Ant flavor), our output is rejected:

```
element testsuite: Schemas validity error : Element 'testsuite': The attribute 'time' is required but missing.
element testcase: Schemas validity error : Element 'testcase': This element is not expected. Expected is ( properties ).
```

Both complaints are Ant-flavor requirements, not common-subset ones: that XSD requires a `time`
attribute and a `<properties>` child that the `testmoapp` reference documents as optional. Since the
format has **no normative schema** (§7.1), "fails one flavor's XSD" is a flavor difference and not a
conformance failure — but calling it a pass would be worse. So the gate became what the roadmap
actually asked for, an *independent parser*: `junitparser` reads the log back and every suite, case,
result type, and aggregate count round-trips. That is a stronger check than a schema anyway, and it is
the check a user's CI actually performs. §7.2's refusal to emit a fabricated `time="0"` stands.

### 8.3 Unicode and stress

RRF-FINAL exercises, at minimum: a non-ASCII identifier (codepoint column ≠ byte column), a character
outside the BMP (codepoint column ≠ UTF-16 column — the case that would pass if we had silently chosen
UTF-16), a CRLF file (normalized offsets ≠ on-disk offsets, §3.3), a path containing `:` and `,` (§5.3),
a path containing `&` and `<` (§7.3), and a multi-line finding (§5.2). Scale uses the frozen sample or a
synthetic saved report; complete mathlib is forbidden here.

---

## 9. Failure semantics

### 9.1 Exit codes are unchanged

`reportExitCode` (`Cli.lean:368-371`) is not touched: 2 for infrastructure failure, 1 for
broken/rejected or (for a non-writer) changed, else 0. **The output format must not change the exit
code.** A CI job that swaps `--output-format sarif` in and starts passing would be the worst possible
regression this stack could ship, and RRF-FINAL pins the exit code across every format on the same
fixture.

### 9.2 Output-file failure

A failure to write the report is an **infrastructure** failure: exit 2, message on stderr naming the
path. Atomicity (§2.4) means the failure leaves either the previous file or no file, never a partial
one. The findings themselves have already been computed and are lost with the write — this is stated,
not worked around, because the alternative (fall back to stdout) would make a CI job that redirects
stdout silently produce two different artifacts depending on whether the write succeeded.

### 9.3 Broken pipe

`lean-fmt check … --output-format concise | head -1` closes stdout early. The write raises, and the
run **swallows it without a diagnostic and keeps its own exit code** — a downstream `head` is not an
error, and the standard shell idiom must not print `lean-fmt: broken pipe` into a user's terminal.

**Amended during RRF-IMPL.** The first draft said the run "exits 0". That was wrong, and the
implementation is what showed it: exiting 0 would mean `lean-fmt check … | head` reported *success* on
a run that found a violation, turning the pipe into a way to silence CI. The pipe closing says nothing
about what the analysis found. So the broken pipe suppresses the *message*, never the *verdict* —
measured: `check --output-format concise | head -1` exits 1 with the finding, and prints nothing extra.

This is a real gap, not a hypothetical: nothing in `Cli.lean` handles `EPIPE` today, so the current
behavior is whatever the Lean runtime does with the raised `IO.Error`. RRF-IMPL must establish it
deliberately, and RRF-FINAL must test it for **every** format including the two that exist today —
`text` and `json` are as pipeable as the new ones, and this is a pre-existing hole this stack is best
placed to close.

Broken pipe on `--output-file` is not the same case and is §9.2.

---

## 10. What RRF-IMPL inherits

1. The byte-offset → (line, codepoint column) conversion (§3.1) — **one** shared function, tested
   against `offsetOfLineColumn` as its inverse.
2. `ReportFormat` widened from two constructors to six, with per-mode admissibility (§2.3).
3. `--output-file` with pre-check and atomic replacement (§2.4).
4. Four pure renderers over `RunReport` — no IO, no analysis, no rule selection, no reordering. Purity
   is what makes them golden-testable and is the roadmap's completion contract.
5. SARIF rule descriptors projected from the existing catalog (§6.2), never re-authored.
6. Escaping for three different escaping regimes (§5.3, §6, §7.3), each with `%`/`&` ordered first.
7. Broken-pipe handling for all six formats (§9.3).
8. The JSON golden recorded in this prompt, still reproducing byte-for-byte (§8.1).

## 11. Open questions RRF-IMPL or RRF-FINAL must close

- **Where does the conversion live?** `Cli.lean` holds `offsetOfLineColumn` and this stack's rendering
  belongs in `Cli.lean` per `CLAUDE.md`. But the conversion needs the **source text**, which the report
  does not carry — `FileReport` has `path` and `formatted?`, not the original normalized bytes. So
  either the renderer re-reads each file (an IO dependency in a "pure renderer", and a stale-read race
  against `fix` having just rewritten it), or `FileReport` gains the line-start index it needs. The
  second is a report shape change and §8.1 forbids adding a field to the JSON. **The likely resolution
  is a private, non-serialized side table computed during execution and passed to the renderer**, but
  this has not been designed and RRF-IMPL must design it twice per the prompt's Plan step 2 before
  choosing. This is the largest unresolved item in the stack.
- **`format`/`fix` synthetic identities.** §4 and §6 use `format` as a pseudo-rule id for "would be
  reformatted". It must not collide with the `FMT###` catalog namespace or with `ruff-12`'s reserved
  and retired codes; RRF-IMPL confirms against the live registry rather than assuming.
- **`helpUri` for a rule with no generated page.** `docs/rules/` covers FMT003–FMT017; the import
  family's coverage was not re-verified here. RRF-IMPL emits `helpUri` only where the page exists.
- **Pretty-printed SARIF byte stability.** `Lean.Json`'s pretty printer is the renderer of record; if
  its output is not stable across toolchain bumps, the SARIF golden becomes a toolchain tripwire.
  RRF-IMPL should record whether it pins the rendering itself.

## 12. How §11 closed (`RRF-FINAL`)

Recorded here rather than only in `results/`, so the freeze is not left describing questions that are
answered.

- **Where the conversion lives.** Design C: `Application.execute` returns a `PositionIndex` beside the
  report, resolving exactly the offsets the finished report names. The two alternatives §11 posed were
  both rejected with reasons — re-reading races `fix` publishing in place; a `FileReport` field is the
  JSON compatibility surface. `results/02-renderers.md` records the comparison on the prompt's axes.
- **The `format` pseudo-rule id.** No collision, and now asserted rather than argued: `tests/reporting/run.sh`
  reads `lean-fmt rules --json` and checks that `format` is absent from the live registry.
- **`helpUri`.** `docs/rules/` was re-verified to hold a page for every live code, import family
  included, so the descriptor emits
  `https://github.com/jcreinhold/lean-fmt/blob/main/docs/rules/<CODE>.md` — the same host
  `informationUri` already names. The suite does not assert the string; it extracts every emitted
  `helpUri` and checks the file it names exists in this repository, so a rule page deleted or renamed
  fails the suite rather than shipping a dead link.
- **Pretty-printed SARIF byte stability is deliberately not pinned.** Byte stability is promised for
  `--output-format json` alone (§8.1), which uses `Lean.Json.compress` and is pinned to a golden by
  `tests/check/run.sh`. SARIF and JUnit promise *parse* stability, and the suite asserts them through
  independent parsers for exactly that reason. A byte golden over `Lean.Json.pretty` would encode that
  serializer's layout as a contract this stack does not make, and would fail on a toolchain bump that
  broke nothing a consumer can observe. The risk accepted, and named: a reflow that keeps the document
  valid passes silently. That is the correct outcome for a format defined by its schema.
- **URI encoding.** §6.4's RFC 3986 requirement ships as `uriPathEncode`, applied to both a result's
  `uri` and `originalUriBaseIds`' root. The character set is §3.3 `pchar` plus `/`; everything else is
  percent-encoded over UTF-8 bytes.
