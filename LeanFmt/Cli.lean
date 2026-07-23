/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.GitSelection
import all LeanFmt.LanguageServer
import all LeanFmt.Watch

open System

namespace LeanFmt.Internal.Cli

open LeanFmt.Internal LeanFmt.Internal.Application LeanFmt.Internal.Profile

/-- How a run's report is rendered (`ruff-15` RRF-IMPL, frozen in `notes/01-report-formats.md` §2).

`text` and `json` existed before this stack and their bytes are unchanged. `text` is **not** renamed
to ruff's `full`, because this report renders no source excerpt and the name would promise one. The
four added formats are projections over the finished `RunReport`: they cannot trigger analysis,
alter rule selection, or reorder results, which the roadmap requires for completion. -/
private inductive ReportFormat where
  | text
  | concise
  | json
  | github
  | sarif
  | junit
  deriving BEq

private def ReportFormat.toWire : ReportFormat → String
  | .text => "text"
  | .concise => "concise"
  | .json => "json"
  | .github => "github"
  | .sarif => "sarif"
  | .junit => "junit"

instance : ToString ReportFormat := ⟨ReportFormat.toWire⟩

private def ReportFormat.ofWire? : String → Option ReportFormat
  | "text" => some .text
  | "concise" => some .concise
  | "json" => some .json
  | "github" => some .github
  | "sarif" => some .sarif
  | "junit" => some .junit
  | _ => none

/-- Whether this format reports *findings* rather than the mode's own product.

`diff`'s product is a patch and carries no findings (`ruff-15` `evidence/01-report-baseline.md` §3),
so these four have nothing to say about it and are rejected for it, following `ruff-14`: refuse a
flag a mode cannot honor rather than emit a well-formed, empty, misleading report. -/
private def ReportFormat.findingShaped : ReportFormat → Bool
  | .concise | .github | .sarif | .junit => true
  | .text | .json => false

/-! ## stdin/stdout and range parsing (`ruff-14` RSF-IMPL)

Presentation only: this file decides what the caller typed and how to print the answer.
`Application.stream` owns identity, configuration, execution, expansion, and the splice. -/

/-- A `--range`/`--range-lines` argument, before it is resolved against the received bytes.

Line/column stays symbolic until the source is in hand: a column is a **codepoint** offset into a
line and cannot become a byte offset without the line (`notes/01-stream-range.md` §3). Byte form is
already the internal encoding and passes straight through. -/
private inductive RangeSpec where
  | bytes (start stop : Nat)
  | lineColumn (startLine startColumn stopLine stopColumn : Nat)

private def parseNat? (value : String) : Option Nat := value.toNat?

/-- `START:STOP`, half-open normalized byte offsets. -/
private def parseByteRange? (value : String) : Option RangeSpec := do
  let [start, stop] := value.splitOn ":" | none
  return .bytes (← parseNat? start) (← parseNat? stop)

/-- `LINE:COL-LINE:COL`, 1-based line and 1-based codepoint column. -/
private def parseLineRange? (value : String) : Option RangeSpec := do
  let [start, stop] := value.splitOn "-" | none
  let [startLine, startColumn] := start.splitOn ":" | none
  let [stopLine, stopColumn] := stop.splitOn ":" | none
  return .lineColumn (← parseNat? startLine) (← parseNat? startColumn)
    (← parseNat? stopLine) (← parseNat? stopColumn)

/-- Byte offset of a 1-based (line, codepoint column) position in `normalized`, clamped to the end.

Clamping rather than failing is deliberate: an editor's end-of-selection often sits one past the
last character of a line, and a formatter that rejected that would be unusable. A position past the
file end resolves to the file end, which selects the final unit. -/
private def offsetOfLineColumn (normalized : String) (line column : Nat) : Nat := Id.run do
  let bytes := normalized.toUTF8
  let mut offset := 0
  let mut currentLine := 1
  -- Walk to the start of `line`.
  while currentLine < line && offset < bytes.size do
    if bytes[offset]! == 10 then currentLine := currentLine + 1
    offset := offset + 1
  -- Then `column - 1` codepoints into it, stopping at the newline that ends the line.
  let mut remaining := column - min column 1
  while remaining > 0 && offset < bytes.size && bytes[offset]! != 10 do
    -- Advance one UTF-8 codepoint: skip the lead byte, then every continuation byte (0b10xxxxxx).
    offset := offset + 1
    while offset < bytes.size && bytes[offset]! &&& 0xC0 == 0x80 do
      offset := offset + 1
    remaining := remaining - 1
  return offset

/-- Resolve a spec against the received bytes, or say why it cannot be. -/
private def resolveRange (normalized : String) : RangeSpec → Except String SourceRange
  | .bytes start stop =>
    let size := normalized.utf8ByteSize
    if stop < start then .error s!"--range start {start} is past its stop {stop}"
    else if stop > size then
      .error s!"--range stop {stop} is past the end of the received source ({size} bytes)"
    else .ok ⟨start, stop⟩
  | .lineColumn startLine startColumn stopLine stopColumn =>
    if startLine == 0 || stopLine == 0 || startColumn == 0 || stopColumn == 0 then
      .error "--range-lines uses 1-based lines and columns"
    else
      let start := offsetOfLineColumn normalized startLine startColumn
      let stop := offsetOfLineColumn normalized stopLine stopColumn
      if stop < start then
        .error s!"--range-lines start {startLine}:{startColumn} is past its stop \
          {stopLine}:{stopColumn}"
      else .ok ⟨start, stop⟩

private structure FileCommand where
  run : RunRequest
  outputFormat : ReportFormat := .text
  /-- `--json` was typed. Kept beside `outputFormat` rather than folded into it so that
  `--json --output-format github` is rejected instead of silently letting one win
  (`notes/01-report-formats.md` §2.2). -/
  jsonFlag : Bool := false
  /-- `--output-format` was typed, and with what. Same reason. -/
  formatFlag? : Option ReportFormat := none
  /-- Write the report here instead of stdout, atomically (`notes/01-report-formats.md` §2.4). -/
  outputFile? : Option String := none
  statistics : Bool := false
  /-- The `-` target was given: read the one source from stdin and stream the answer. -/
  stdin : Bool := false
  stdinFilename? : Option String := none
  range? : Option RangeSpec := none
  /-- Which spelling the caller used, so a diagnostic names the flag they typed. -/
  rangeFlag : String := "--range"
  /-- `--watch` (`ruff-16` RWI-IMPL, `notes/01-watch-generations.md` §1). -/
  watch : Bool := false
  /-- Poll interval for `--watch`, milliseconds (§1). -/
  pollMillis : Nat := 200
  /-- Which version-control comparison selects the files, if any (§9.1). -/
  changed? : Option GitSelection.Comparison := none
  /-- Which spelling asked for it, so a diagnostic names the flag the caller typed. -/
  changedFlag : String := "--changed"

private structure RootCommand where
  root : FilePath := "."
  outputFormat : ReportFormat := .text

private structure StatusCommand where
  request : CompilerStatusRequest := {}
  outputFormat : ReportFormat := .text

private structure OrganizeCommand where
  request : OrganizeRequest := { root := ".", files := #[] }
  outputFormat : ReportFormat := .text

private def parseLspArgs (args : List String) : Except String LanguageServer.ServerOptions :=
  let rec loop (remaining : List String) (options : LanguageServer.ServerOptions) :=
    match remaining with
    | [] => .ok options
    | "--root" :: root :: rest => loop rest { options with root }
    | "--config" :: path :: rest => loop rest { options with configPath? := some path }
    | "--select" :: selector :: rest =>
      loop rest { options with select := options.select.push selector }
    | "--ignore" :: selector :: rest =>
      loop rest { options with ignore := options.ignore.push selector }
    | "--preview" :: rest => loop rest { options with preview := true }
    | "--unsafe-fixes" :: rest => loop rest { options with unsafeFixes := true }
    | "--max-memory" :: value :: rest =>
      match value.toNat? with
      | some amount => loop rest { options with maxMemoryGiB := amount }
      | none => .error "--max-memory expects a whole number of GiB"
    | "--debounce-ms" :: value :: rest =>
      match value.toNat? with
      | some amount => loop rest { options with debounceMs := amount }
      | none => .error "--debounce-ms expects a whole number of milliseconds"
    | option :: _ => .error s!"unknown lsp option: {option}"
  loop args {}

private def usage : String := "\
usage: lean-fmt {check|format|diff|fix} [OPTIONS] [FILE...]\n\
       lean-fmt {check|format|diff|fix} - --stdin-filename PATH [--range S:E]\n\
       lean-fmt lsp [--root PATH] [--config PATH] [--select SELECTOR]\n\
                    [--ignore SELECTOR] [--preview] [--unsafe-fixes]\n\
                    [--max-memory GIB] [--debounce-ms MS]\n\
       lean-fmt organize [--root PATH] [--config PATH] [--check] [--json]\n\
                         [--max-memory GIB] [FILE...]\n\
       lean-fmt rules [--json]\n\
       lean-fmt explain RULE [--json]\n\
       lean-fmt docs [--root PATH] [--check]\n\
       lean-fmt clean [--root PATH] [--json]\n\
       lean-fmt compiler {setup|status} [--root PATH] [--json]\n\
       lean-fmt config show PATH [--root PATH] [--config PATH] [--json]\n\
\n\
file options:\n\
  --root PATH          Lake project root (default: .)\n\
  --config PATH        explicit lean-fmt.toml\n\
  --select SELECTOR    set the active rules: a code/category/all (repeatable)\n\
  --extend-select SEL  add to the active rules without replacing (repeatable)\n\
  --ignore SELECTOR    deactivate a rule/category/all (repeatable)\n\
  --fixable SELECTOR   restrict which rules' fixes `fix` applies (repeatable)\n\
  --unfixable SELECTOR withhold a rule's fix from `fix` (repeatable)\n\
  --extend-fixable SEL add to the fixable set without replacing (repeatable)\n\
  --preview            unlock preview (experimental) rules\n\
  --json               deterministic JSON output (alias for --output-format json)\n\
  --output-format FMT  text|concise|json|github|sarif|junit (default: text)\n\
                       concise/github/sarif/junit are unavailable for `diff`\n\
  --output-file PATH   write the report to PATH atomically instead of stdout\n\
  --statistics         write aggregate statistics to stderr\n\
  --watch              re-run on every change until interrupted (previews only)\n\
                       json/sarif/junit require --output-file under --watch\n\
  --poll-interval MS   how often --watch looks for changes (default: 200)\n\
  --changed            select only files differing from HEAD, plus untracked\n\
  --changed-since REV  select only files this branch changed since REV\n\
  --staged             select only files staged for commit\n\
  --no-cache           neither read nor write result cache entries\n\
  --max-memory GIB     aggregate operating envelope (default: 8)\n\
  --unsafe-fixes       apply/preview unsafe fixes too (default: safe only)\n\
  --check              format: report what would change, write nothing (CI preview)\n\
\n\
stdin options (target `-`; never writes a file or a cache entry):\n\
  --stdin-filename P   required with `-`: the buffer's identity for config/module resolution\n\
  --range START:STOP   format only this half-open normalized byte range (format only)\n\
  --range-lines R      format only L:C-L:C (1-based line, 1-based codepoint column)"

/-- Reconcile the two spellings of one choice, and refuse a mode the chosen format cannot describe.

Both checks are deliberately errors rather than precedence rules. A caller who typed two different
formats does not have a preference for us to guess, and a caller who asked `diff` for SARIF wants
findings `diff` does not produce. -/
private def resolveOutputFormat (mode : RunMode) (command : FileCommand) :
    Except String FileCommand :=
  let chosen := match command.formatFlag?, command.jsonFlag with
    | some format, _ => format
    | none, true => .json
    | none, false => .text
  if command.jsonFlag && command.formatFlag?.isSome && chosen != .json then
    .error s!"--json and --output-format {chosen} disagree; pass only one"
  else if mode == .diff && chosen.findingShaped then
    .error s!"--output-format {chosen} is not available for diff; \
      diff reports a patch, not findings"
  else
    .ok { command with outputFormat := chosen }

private def parseFileArgs (mode : RunMode) (args : List String) : Except String FileCommand :=
  let rec loop (remaining : List String) (command : FileCommand) :=
    match remaining with
    | [] => resolveOutputFormat mode command
    | "--root" :: root :: rest =>
      loop rest { command with run := { command.run with root } }
    | "--json" :: rest => loop rest { command with jsonFlag := true }
    | "--output-format" :: value :: rest =>
      match ReportFormat.ofWire? value with
      | some format => loop rest { command with formatFlag? := some format }
      | none =>
        .error s!"unknown --output-format: {value} \
          (expected text, concise, json, github, sarif, or junit)"
    | "--output-file" :: path :: rest =>
      loop rest { command with outputFile? := some path }
    | "--no-cache" :: rest => loop rest { command with run := { command.run with cache := false } }
    | "--config" :: path :: rest =>
      loop rest { command with run := { command.run with configPath? := some path } }
    | "--select" :: selector :: rest =>
      loop rest { command with run := {
        command.run with select := command.run.select.push selector } }
    | "--extend-select" :: selector :: rest =>
      loop rest { command with run := {
        command.run with extendSelect := command.run.extendSelect.push selector } }
    | "--ignore" :: selector :: rest =>
      loop rest { command with run := {
        command.run with ignore := command.run.ignore.push selector } }
    | "--fixable" :: selector :: rest =>
      loop rest { command with run := {
        command.run with fixable := command.run.fixable.push selector } }
    | "--unfixable" :: selector :: rest =>
      loop rest { command with run := {
        command.run with unfixable := command.run.unfixable.push selector } }
    | "--extend-fixable" :: selector :: rest =>
      loop rest { command with run := {
        command.run with extendFixable := command.run.extendFixable.push selector } }
    | "--preview" :: rest =>
      loop rest { command with run := { command.run with preview := true } }
    | "--statistics" :: rest => loop rest { command with statistics := true }
    | "--watch" :: rest => loop rest { command with watch := true }
    | "--poll-interval" :: value :: rest =>
      match value.toNat? with
      | some amount =>
        if amount == 0 then .error "--poll-interval expects a nonzero interval in milliseconds"
        else loop rest { command with pollMillis := amount }
      | none => .error "--poll-interval expects a whole number of milliseconds"
    -- Three separate spellings rather than one `--changed [BASE]` with an optional argument. An
    -- optional-argument flag cannot be told from a file target — `check --changed main` would be
    -- ambiguous between "compare against main" and "compare the worktree, and format `main`" — and
    -- guessing there makes a caller format the wrong set without knowing
    -- (`results/02-implementation.md`, decisions changed).
    | "--changed" :: rest =>
      loop rest { command with changed? := some .worktree, changedFlag := "--changed" }
    | "--changed-since" :: revision :: rest =>
      loop rest { command with
        changed? := some (.base revision), changedFlag := "--changed-since" }
    | "--staged" :: rest =>
      loop rest { command with changed? := some .staged, changedFlag := "--staged" }
    | "--changed-since" :: [] => .error "--changed-since expects a revision"
    | "--poll-interval" :: [] =>
      .error "--poll-interval expects a whole number of milliseconds"
    | "--check" :: rest =>
      if mode == .format then
        loop rest { command with run := { command.run with formatCheck := true } }
      else
        .error "--check is valid only for format"
    | "--unsafe-fixes" :: rest =>
      loop rest { command with run := { command.run with unsafeFixes := true } }
    | "--max-memory" :: value :: rest =>
      match value.toNat? with
      | some amount =>
        loop rest { command with run := { command.run with maxMemoryGiB := amount } }
      | none => .error "--max-memory expects a whole number of GiB"
    -- `-` is a *target*, not an option, so it is matched before the `startsWith "-"` catch-all below.
    | "-" :: rest => loop rest { command with stdin := true }
    | "--stdin-filename" :: path :: rest =>
      loop rest { command with stdinFilename? := some path }
    | "--range" :: value :: rest =>
      match parseByteRange? value with
      | some spec => loop rest { command with range? := some spec, rangeFlag := "--range" }
      | none => .error s!"--range expects START:STOP byte offsets, got: {value}"
    | "--range-lines" :: value :: rest =>
      match parseLineRange? value with
      | some spec => loop rest { command with range? := some spec, rangeFlag := "--range-lines" }
      | none => .error s!"--range-lines expects LINE:COL-LINE:COL, got: {value}"
    | "--stdin-filename" :: [] => .error "--stdin-filename expects a path"
    | "--range" :: [] => .error "--range expects START:STOP byte offsets"
    | "--range-lines" :: [] => .error "--range-lines expects LINE:COL-LINE:COL"
    | option :: rest =>
      if option.startsWith "-" then .error s!"unknown option: {option}"
      else loop rest { command with run := { command.run with files := command.run.files.push option } }
  loop args { run := { mode, root := ".", files := #[] } }

/-- The stdin form's own consistency, checked once after parsing rather than at each use.

Each rejection is a frozen clause of `notes/01-stream-range.md` §2. Each is an error rather than a
fallback because the quiet alternative is worse: a `-` with no identity would format against
built-in defaults and silently disagree with the same bytes on disk, and a `--range` without `-`
would have to mean a partial in-place write, which this stack deliberately does not build.

A range is also rejected for a mode that cannot honor it. `format` is the only mode that emits a
layout, so `check`/`diff`/`fix` have nothing to narrow: `check` reports findings over the whole
buffer, and `fix` applies admitted rule fixes at original coordinates. Accepting the flag and
disregarding it would answer a narrower question than the caller asked, with no sign that it did. -/
private def validateStdin (mode : RunMode) (command : FileCommand) : Except String Unit := do
  if command.stdin then
    if command.stdinFilename?.isNone then
      .error "stdin requires --stdin-filename to establish project identity"
    else if !command.run.files.isEmpty then
      .error "- must be the only target"
    else if command.range?.isSome && !(mode == .format) then
      .error s!"{command.rangeFlag} is valid only with format, not {mode.toString}"
    else .ok ()
  else if command.stdinFilename?.isSome then
    .error "--stdin-filename is valid only with the - stdin target"
  else if command.range?.isSome then
    .error s!"{command.rangeFlag} is valid only with the - stdin target"
  else .ok ()

/-- Whether this format is a self-contained document rather than a line stream.

`json`, `sarif` and `junit` each emit **one complete document per run** — a SARIF log has a single
`runs` array and a JUnit file a single root element — so no parser accepts a stream of generations
concatenated onto stdout (`notes/01-watch-generations.md` §7). -/
private def ReportFormat.documentShaped : ReportFormat → Bool
  | .json | .sarif | .junit => true
  | .text | .concise | .github => false

/-- The watch and changed-file forms' own consistency, checked once after parsing.

Each rejection follows `ruff-14`/`ruff-15`: refuse a flag a mode cannot honor rather than emit
well-formed misleading output. -/
private def validateWatch (mode : RunMode) (command : FileCommand) : Except String Unit := do
  if command.watch then
    -- §10. A writing mode under watch publishes source, which changes the `mtime`/`byteSize` tuples
    -- the poll observes, which triggers the next generation, which publishes again. The loop
    -- sustains itself — not a race, a certainty.
    if mode == .fix then
      .error "--watch is not available for fix; watch runs previews, and a writing mode retriggers itself"
    else if command.run.writesFormat then
      .error "--watch is not available for format; pass --check to preview, \
        or a writing mode retriggers itself"
    else if command.stdin then
      .error "--watch is not available for the - stdin target; watch observes files on disk"
    -- §7. One complete document per generation, replacing the previous, needs a destination that can
    -- be replaced.
    else if command.outputFormat.documentShaped && command.outputFile?.isNone then
      .error s!"--output-format {command.outputFormat} requires --output-file with --watch; \
        a stream of {command.outputFormat} documents is not a {command.outputFormat} document"
    else .ok ()
  else if command.pollMillis != 200 then
    .error "--poll-interval is valid only with --watch"
  else .ok ()

private def validateChanged (command : FileCommand) : Except String Unit := do
  match command.changed? with
  | none => .ok ()
  | some _ =>
    if command.stdin then
      .error s!"{command.changedFlag} is not available for the - stdin target; \
        version control selects files on disk"
    else if !command.run.files.isEmpty then
      -- Naming files and asking git to name them are two answers to one question, and silently
      -- letting one win makes a caller format a set they did not intend.
      .error s!"{command.changedFlag} selects the files; do not also name them"
    else .ok ()

private def parseRootArgs (args : List String) : Except String RootCommand :=
  let rec loop (remaining : List String) (command : RootCommand) :=
    match remaining with
    | [] => .ok command
    | "--root" :: root :: rest => loop rest { command with root }
    | "--json" :: rest => loop rest { command with outputFormat := .json }
    | option :: _ => .error s!"unknown option: {option}"
  loop args {}

private def parseOutputArgs (args : List String) : Except String ReportFormat :=
  match args with
  | [] => .ok .text
  | ["--json"] => .ok .json
  | option :: _ => .error s!"unknown option: {option}"

private def parseStatusArgs (args : List String) : Except String StatusCommand :=
  let rec loop (remaining : List String) (command : StatusCommand) :=
    match remaining with
    | [] => .ok command
    | "--root" :: root :: rest =>
      loop rest { command with request := { command.request with root } }
    | "--json" :: rest => loop rest { command with outputFormat := .json }
    | "--max-memory" :: value :: rest =>
      match value.toNat? with
      | some amount =>
        loop rest { command with request := { command.request with maxMemoryGiB := amount } }
      | none => .error "--max-memory expects a whole number of GiB"
    | option :: _ => .error s!"unknown compiler status option: {option}"
  loop args {}

private def parseOrganizeArgs (args : List String) : Except String OrganizeCommand :=
  let rec loop (remaining : List String) (command : OrganizeCommand) :=
    match remaining with
    | [] => .ok command
    | "--root" :: root :: rest =>
      loop rest { command with request := { command.request with root } }
    | "--json" :: rest => loop rest { command with outputFormat := .json }
    | "--config" :: path :: rest =>
      loop rest { command with request := { command.request with configPath? := some path } }
    | "--check" :: rest =>
      loop rest { command with request := { command.request with check := true } }
    | "--max-memory" :: value :: rest =>
      match value.toNat? with
      | some amount =>
        loop rest { command with request := { command.request with maxMemoryGiB := amount } }
      | none => .error "--max-memory expects a whole number of GiB"
    | option :: rest =>
      if option.startsWith "-" then .error s!"unknown option: {option}"
      else loop rest { command with
        request := { command.request with files := command.request.files.push option } }
  loop args {}

/-! ## Report renderers (`ruff-15` RRF-IMPL)

Every renderer below is a **pure** `RunReport → String` (plus, where it needs line/column, the
`PositionIndex` execution resolved beside the report). None of them reads a file, runs analysis, or
touches rule selection, which makes them golden-testable and is what the roadmap requires for
completion. `emitReport` is the single IO boundary. -/

private def textReport (report : RunReport) : String := Id.run do
  let mut out := ""
  match report.mode with
  | "organize" =>
    for file in report.files do
      unless file.status == "clean" do out := out ++ s!"{file.path}: {file.status}\n"
      for diagnostic in file.diagnostics do out := out ++ s!"  {diagnostic}\n"
  | "format" =>
    -- `format` publishes in place by default (`ruff-11d`): a short per-file summary, never the file
    -- body. `formatted` means written; `would-format` is the `--check` preview of a file that would
    -- change. A clean file is silent. `--json` still carries the full canonical text
    -- (`file.formatted`).
    for file in report.files do
      unless file.status == "clean" do out := out ++ s!"{file.path}: {file.status}\n"
      for diagnostic in file.diagnostics do
        out := out ++ s!"  {diagnostic}\n"
  | "diff" =>
    for file in report.files do
      if let some diff := file.diff then out := out ++ diff
      for diagnostic in file.diagnostics do
        out := out ++ s!"{file.path}: {file.status}: {diagnostic}\n"
  | "fix" =>
    for file in report.files do
      unless file.status == "clean" do out := out ++ s!"{file.path}: {file.status}\n"
      for diagnostic in file.diagnostics do out := out ++ s!"  {diagnostic}\n"
      if file.withheldUnsafe > 0 then
        out := out ++
          s!"  {file.withheldUnsafe} unsafe fix(es) withheld; rerun with --unsafe-fixes to apply\n"
  | _ =>
    for file in report.files do
      for finding in file.findings do
        -- A fix's applicability is shown next to the finding so a reader knows whether `fix` would
        -- apply it by default (safe), only under `--unsafe-fixes` (unsafe), or never (display-only).
        let fixTag := match finding.fix? with
          | some fix => s!" [{fix.applicability}]"
          | none => ""
        out := out ++ s!"{file.path}:{finding.range.start}-{finding.range.stop}: \
          {finding.code} {finding.message}{fixTag}\n"
      for diagnostic in file.diagnostics do
        out := out ++ s!"{file.path}: {file.status}: {diagnostic}\n"
  return out ++ s!"mode={report.mode} files={report.files.size} findings={report.findings} \
    changed={report.changed} written={report.written} broken={report.broken} \
    rejected={report.rejected} withheld_unsafe={report.withheldUnsafe} \
    suppressed={report.suppressed} infrastructure_failures={report.infrastructureFailures.size}\n"

/-! ### Shared projections

The four finding-shaped formats disagree about syntax and agree about content. These helpers are that
content, resolved once, so a change of policy (which statuses report, how a message is flattened)
cannot reach three formats and miss the fourth. -/

/-- One line/column pair for a finding's start, or `1:1` when the index has no answer.

Only a report entry whose source the run never snapshotted reaches the fallback, and it is a
position, not a lie about one: it names the file, which is the part a reader acts on. -/
private def startPosition (positions : PositionIndex) (path : String) (finding : Finding) :
    Position :=
  (positions.position? path finding.range.start).getD ⟨1, 1⟩

private def stopPosition (positions : PositionIndex) (path : String) (finding : Finding) :
    Position :=
  (positions.position? path finding.range.stop).getD (startPosition positions path finding)

/-- Collapse a message to one line. No live rule message contains a newline; this is defensive, and
`tests/reporting` pins it with a synthetic finding rather than trusting the invariant to hold. -/
private def flattenMessage (message : String) : String :=
  (message.replace "\r\n" " ").replace "\n" " " |>.replace "\r" " "

/-- The severity a format shows for a file-level status that is not a rule finding.

`format --check` reporting "this file would be reformatted" has no `FMT###` code — there is no rule
involved — so it needs an identity of its own. `format` is deliberately outside the `FMT` namespace so
it can never collide with a live, reserved, or retired rule code (`ruff-12`). -/
private def statusRuleId : String := "format"

/-- Statuses a finding-shaped format reports as a file-level problem, with the message it prints.

A `clean` file, and a file whose only news is its findings, produce nothing here; the findings
already report it. -/
private def statusMessage? (status : String) : Option String :=
  match status with
  | "would-format" => some "file would be reformatted"
  | "would-organize" => some "imports would be reorganized"
  | "broken" => some "file could not be parsed"
  | "rejected" => some "result was rejected by validation"
  | "infrastructure-failure" => some "analysis did not complete"
  | _ => none

/-- Whether a status is an *infrastructure* problem rather than a finding.

The distinction SARIF draws between a result and a notification (§3.20.21), JUnit draws between
`<failure>` and `<error>`, and `reportExitCode` already draws between exit 1 and exit 2. One predicate
so the three cannot drift. -/
private def statusIsInfrastructure (status : String) : Bool :=
  status == "broken" || status == "rejected" || status == "infrastructure-failure"

/-! ### `concise`

`PATH:LINE:COLUMN: CODE MESSAGE`, one line per finding, and nothing else — no summary line and no
applicability tag. The format exists to be piped into `grep` and editor error-parsers, and a
trailing line that does not match the grammar breaks them (`notes/01-report-formats.md` §4). -/

private def conciseReport (positions : PositionIndex) (report : RunReport) : String := Id.run do
  let mut out := ""
  for file in report.files do
    for finding in file.findings do
      let start := startPosition positions file.path finding
      out := out ++ s!"{file.path}:{start.line}:{start.column}: {finding.code} \
        {flattenMessage finding.message}\n"
    if let some message := statusMessage? file.status then
      out := out ++ s!"{file.path}:1:1: {statusRuleId} {message}\n"
    for diagnostic in file.diagnostics do
      out := out ++ s!"{file.path}:1:1: {statusRuleId} {flattenMessage diagnostic}\n"
  for failure in report.infrastructureFailures do
    out := out ++ s!"lean-fmt: {flattenMessage failure}\n"
  return out

/-! ### `github`

GitHub Actions workflow commands. Escaping matches the runner's own (`actions/toolkit`,
`packages/core/src/command.ts`). Property values take stricter escaping than the message because an
unescaped `:` or `,` in a path would end the property list. -/

/-- `escapeData` from the toolkit: the message body. `%` first, or the `%` this introduces for
`\r`/`\n` would be double-escaped on the next pass. -/
private def githubEscapeData (value : String) : String :=
  value.replace "%" "%25" |>.replace "\r" "%0D" |>.replace "\n" "%0A"

/-- `escapeProperty` from the toolkit: `escapeData` plus `:` and `,`, which delimit the property list. -/
private def githubEscapeProperty (value : String) : String :=
  githubEscapeData value |>.replace ":" "%3A" |>.replace "," "%2C"

private def githubSeverity : Severity → String
  | .error => "error"
  | .warning => "warning"
  | .information => "notice"

/-- One workflow command.

`col`/`endColumn` are omitted whenever the span crosses lines: GitHub rejects the annotation
otherwise. GitHub does not document that constraint; ruff's renderer records it, citing
`astral-sh/ruff#22074`. Multi-line findings are ordinary here, so this is a common path. -/
private def githubCommand (severity : String) (path : String) (code : String)
    (start stop : Position) (message : String) : String :=
  let location :=
    if start.line == stop.line then
      s!",line={start.line},col={start.column},endLine={stop.line},endColumn={stop.column}"
    else
      s!",line={start.line},endLine={stop.line}"
  -- The message repeats the location because an annotation GitHub cannot attach to a file still
  -- appears in the log, and without the prefix it would name no file at all.
  s!"::{severity} title=lean-fmt ({githubEscapeProperty code}),\
    file={githubEscapeProperty path}{location}::\
    {githubEscapeData s!"{path}:{start.line}:{start.column}: {code} {message}"}"

private def githubReport (positions : PositionIndex) (report : RunReport) : String := Id.run do
  let mut out := ""
  for file in report.files do
    for finding in file.findings do
      let start := startPosition positions file.path finding
      let stop := stopPosition positions file.path finding
      out := out ++ githubCommand (githubSeverity finding.severity) file.path finding.code
        start stop (flattenMessage finding.message) ++ "\n"
    if let some message := statusMessage? file.status then
      let severity := if statusIsInfrastructure file.status then "error" else "warning"
      out := out ++ githubCommand severity file.path statusRuleId ⟨1, 1⟩ ⟨1, 1⟩ message ++ "\n"
    for diagnostic in file.diagnostics do
      out := out ++ githubCommand "error" file.path statusRuleId ⟨1, 1⟩ ⟨1, 1⟩
        (flattenMessage diagnostic) ++ "\n"
  for failure in report.infrastructureFailures do
    out := out ++ s!"::error title=lean-fmt::{githubEscapeData failure}\n"
  return out

/-! ### `sarif`

SARIF 2.1.0 (OASIS Standard). Section numbers below are that document's.

Regions carry **line/column only**. `charOffset` is a *character* offset (§3.30.9) and `byteOffset`
indexes the *artifact* (§3.30.11) while ours index the CRLF-normalized source, and §3.30.4 makes a
region whose text and binary properties disagree invalid, not merely imprecise. The exact byte range
goes in the region's property bag, which §3.8.1 allows. -/

private def sarifLevel : Severity → String
  | .error => "error"
  | .warning => "warning"
  | .information => "note"

/-- One `reportingDescriptor`, projected from the live rule catalog — never re-authored here.
`docs/adding-a-rule.md` and `ruff-12` make one metadata source the invariant, and a second
description table in this renderer is the drift they closed. -/
private def sarifRuleDescriptor (info : RuleInfo) : Lean.Json :=
  Lean.Json.mkObj <| [
    ("id", .str info.code),
    ("name", .str info.code),
    ("shortDescription", Lean.Json.mkObj [("text", .str info.summary)]),
    ("fullDescription", Lean.Json.mkObj [("text", .str info.explanation)]),
    -- The generated rule page. `ruff-15` RRF-FINAL verified that `docs/rules/` covers every live
    -- code, import family included, so this cannot link at a page that does not exist. The host is
    -- the repository's own remote, the same one `informationUri` names.
    ("helpUri", .str
      s!"https://github.com/jcreinhold/lean-fmt/blob/main/docs/rules/{info.code}.md"),
    ("properties", Lean.Json.mkObj [
      ("tags", Lean.Json.arr #[.str info.category]),
      ("lifecycle", Lean.toJson info.lifecycle),
      ("fixable", .bool info.fixable)])
  ]

/-- Percent-encode a filesystem path into the path component of a URI reference
(`notes/01-report-formats.md` §6.4).

The character set is RFC 3986 §3.3 `pchar` — unreserved, sub-delims, `:`, `@` — plus `/`, kept
because it separates the segments of this path rather than sitting inside one. Everything else
becomes `%XX` over the **UTF-8 bytes**, which is what §2.5 requires of a non-ASCII character: there
is no such thing as percent-encoding a codepoint.

The characters this handles are common ones. A space is forbidden in a URI outright; `#` would cut
the reference short at a fragment; `?` would start a query; `%` would make any following pair look
like an escape the consumer must decode. `lean-fmt` accepts whatever path the caller selects, so none
of these are hypothetical — they are ordinary macOS and Windows filenames. -/
private def uriPathEncode (path : String) : String := Id.run do
  let hexDigit (n : Nat) : Char :=
    if n < 10 then Char.ofNat ('0'.toNat + n) else Char.ofNat ('A'.toNat + (n - 10))
  let mut out := ""
  for byte in path.toUTF8 do
    let value := byte.toNat
    let c := Char.ofNat value
    if value < 0x80 && (c.isAlphanum || "-._~!$&'()*+,;=:@/".contains c) then
      out := out.push c
    else
      out := ((out.push '%').push (hexDigit (value >>> 4))).push (hexDigit (value &&& 0xF))
  return out

private def sarifRegion (start stop : Position) (range : SourceRange) : Lean.Json :=
  Lean.Json.mkObj [
    ("startLine", Lean.toJson start.line),
    ("startColumn", Lean.toJson start.column),
    ("endLine", Lean.toJson stop.line),
    ("endColumn", Lean.toJson stop.column),
    ("properties", Lean.Json.mkObj [
      ("leanFmtNormalizedByteRange", Lean.Json.mkObj [
        ("start", Lean.toJson range.start), ("stop", Lean.toJson range.stop)])])
  ]

private def sarifLocation (path : String) (region? : Option Lean.Json) : Lean.Json :=
  let physical := Lean.Json.mkObj <| [
    ("artifactLocation", Lean.Json.mkObj [
      ("uri", .str (uriPathEncode path)), ("uriBaseId", .str "%SRCROOT%")])
  ] ++ (match region? with | some region => [("region", region)] | none => [])
  Lean.Json.mkObj [("physicalLocation", physical)]

private def sarifResult (positions : PositionIndex) (path : String) (finding : Finding) :
    Lean.Json :=
  let start := startPosition positions path finding
  let stop := stopPosition positions path finding
  Lean.Json.mkObj <| [
    ("ruleId", .str finding.code),
    ("level", .str (sarifLevel finding.severity)),
    ("message", Lean.Json.mkObj [("text", .str finding.message)]),
    ("locations", Lean.Json.arr #[sarifLocation path (some (sarifRegion start stop finding.range))])
  ] ++ (match finding.fix? with
    | some fix =>
      -- Applicability, not `result.fixes`. A SARIF fix names regions in character or line/column
      -- terms while our edits are normalized byte ranges, and §3.30.4 forbids stating both.
      -- `--output-format json` carries the exact edits (`notes/01-report-formats.md` §6.4).
      [("properties", Lean.Json.mkObj [("fixApplicability", .str fix.applicability.toWire)])]
    | none => [])

/-- A notification, not a result. §3.20.21: an `error` notification "SHALL mean that the run failed",
and "A SARIF consumer SHALL NOT assume that a failed run contains a complete set of analysis results."
A `result` cannot say the analysis did not complete, which is what exit code 2 means. -/
private def sarifNotification (path? : Option String) (message : String) : Lean.Json :=
  Lean.Json.mkObj <| [
    ("level", .str "error"),
    ("message", Lean.Json.mkObj [("text", .str message)])
  ] ++ (match path? with
    | some path => [("locations", Lean.Json.arr #[sarifLocation path none])]
    | none => [])

private def sarifReport (positions : PositionIndex) (root : String) (report : RunReport) : String :=
  Id.run do
    let mut results : Array Lean.Json := #[]
    let mut notifications : Array Lean.Json := #[]
    let mut codes : Array String := #[]
    for file in report.files do
      for finding in file.findings do
        unless codes.contains finding.code do codes := codes.push finding.code
        results := results.push (sarifResult positions file.path finding)
      if let some message := statusMessage? file.status then
        if statusIsInfrastructure file.status then
          notifications := notifications.push (sarifNotification (some file.path) message)
        else
          results := results.push (Lean.Json.mkObj [
            ("ruleId", .str statusRuleId),
            ("level", .str "warning"),
            ("message", Lean.Json.mkObj [("text", .str message)]),
            ("locations", Lean.Json.arr #[sarifLocation file.path none])])
      for diagnostic in file.diagnostics do
        notifications := notifications.push (sarifNotification (some file.path) diagnostic)
    for failure in report.infrastructureFailures do
      notifications := notifications.push (sarifNotification none failure)
    -- Descriptors for the codes this run reported. A descriptor for a rule that could not have
    -- fired describes a run that did not happen.
    let descriptors := codes.filterMap fun code =>
      (ruleInfoByCode? code).map sarifRuleDescriptor
    let log := Lean.Json.mkObj [
      ("version", .str "2.1.0"),
      ("$schema", .str
        "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json"),
      ("runs", Lean.Json.arr #[Lean.Json.mkObj [
        ("tool", Lean.Json.mkObj [("driver", Lean.Json.mkObj [
          ("name", .str "lean-fmt"),
          ("informationUri", .str "https://github.com/jcreinhold/lean-fmt"),
          ("rules", Lean.Json.arr descriptors)])]),
        -- §3.14.27 makes this a SHALL whenever results are non-empty, and the JSON schema does not
        -- encode it. `unicodeCodePoints` names the encoding `ruff-14` already froze.
        ("columnKind", .str "unicodeCodePoints"),
        ("originalUriBaseIds", Lean.Json.mkObj [
          ("%SRCROOT%", Lean.Json.mkObj [("uri", .str root)])]),
        ("invocations", Lean.Json.arr #[Lean.Json.mkObj [
          ("executionSuccessful", .bool notifications.isEmpty),
          ("toolExecutionNotifications", Lean.Json.arr notifications)]]),
        ("results", Lean.Json.arr results),
        ("properties", Lean.Json.mkObj [
          ("findings", Lean.toJson report.findings),
          ("changed", Lean.toJson report.changed),
          ("written", Lean.toJson report.written),
          ("broken", Lean.toJson report.broken),
          ("rejected", Lean.toJson report.rejected),
          ("withheldUnsafe", Lean.toJson report.withheldUnsafe),
          ("suppressed", Lean.toJson report.suppressed),
          ("withheldRedundant", Lean.toJson report.withheldRedundant)])]])
    ]
    return log.pretty ++ "\n"

/-! ### `junit`

There is no official JUnit XML specification — `testmoapp/junitxml`, the reference this targets, says
so in its first paragraph. This renders the documented common subset and claims nothing more. -/

/-- XML escaping for text and attribute values. `&` first, for the same reason `%` goes first in the
GitHub escaper.

XML 1.0 cannot represent most C0 controls at all, not even escaped, so anything below U+0020 other
than tab/LF/CR becomes U+FFFD. A rule message cannot contain one today — but a **path** can, and one
stray control byte in a filename would otherwise stop a parser reading the whole report. -/
private def xmlEscape (value : String) : String :=
  let replaced := value.replace "&" "&amp;" |>.replace "<" "&lt;" |>.replace ">" "&gt;"
    |>.replace "\"" "&quot;" |>.replace "'" "&apos;"
  String.ofList <| replaced.toList.map fun c =>
    if c.val < 0x20 && c != '\t' && c != '\n' && c != '\r' then '�' else c

private structure JUnitCase where
  name : String
  message : String
  type : String
  detail : String
  /-- `<error>` rather than `<failure>`: the test could not run, as opposed to an assertion failing.
  The same distinction §6.5 draws for SARIF and `reportExitCode` draws for exit codes. -/
  isError : Bool

private def junitCaseXml (classname : String) (case : JUnitCase) : String :=
  let tag := if case.isError then "error" else "failure"
  s!"    <testcase name=\"{xmlEscape case.name}\" classname=\"{xmlEscape classname}\">\n"
    ++ s!"      <{tag} message=\"{xmlEscape case.message}\" type=\"{xmlEscape case.type}\">"
    ++ s!"{xmlEscape case.detail}</{tag}>\n"
    ++ "    </testcase>\n"

private def junitReport (positions : PositionIndex) (report : RunReport) : String := Id.run do
  let mut suites := ""
  let mut totalTests := 0
  let mut totalFailures := 0
  let mut totalErrors := 0
  for file in report.files do
    let mut cases : Array JUnitCase := #[]
    for finding in file.findings do
      let start := startPosition positions file.path finding
      let where_ := s!"{file.path}:{start.line}:{start.column}"
      cases := cases.push {
        name := s!"{finding.code} {where_}"
        message := flattenMessage finding.message
        type := finding.code
        detail := s!"{where_}: {finding.code} {flattenMessage finding.message}"
        isError := false }
    if let some message := statusMessage? file.status then
      cases := cases.push {
        name := s!"{statusRuleId} {file.path}", message, type := statusRuleId
        detail := s!"{file.path}: {message}"
        isError := statusIsInfrastructure file.status }
    for diagnostic in file.diagnostics do
      cases := cases.push {
        name := s!"{statusRuleId} {file.path}", message := flattenMessage diagnostic
        type := statusRuleId, detail := flattenMessage diagnostic, isError := true }
    let failures := cases.foldl (fun total case => if case.isError then total else total + 1) 0
    let errors := cases.size - failures
    -- A clean file emits a *passing* case, not an empty suite: a suite with zero cases reads to most
    -- CI dashboards as "no tests ran", not "nothing wrong".
    let body :=
      if cases.isEmpty then
        s!"    <testcase name=\"{xmlEscape file.path}\" classname=\"{xmlEscape file.path}\" />\n"
      else
        cases.foldl (fun acc case => acc ++ junitCaseXml file.path case) ""
    let tests := max cases.size 1
    totalTests := totalTests + tests
    totalFailures := totalFailures + failures
    totalErrors := totalErrors + errors
    suites := suites ++ s!"  <testsuite name=\"{xmlEscape file.path}\" tests=\"{tests}\" \
      failures=\"{failures}\" errors=\"{errors}\">\n{body}  </testsuite>\n"
  unless report.infrastructureFailures.isEmpty do
    let body := report.infrastructureFailures.foldl (fun acc failure =>
      acc ++ junitCaseXml "lean-fmt" {
        name := s!"{statusRuleId} lean-fmt", message := flattenMessage failure
        type := statusRuleId, detail := flattenMessage failure, isError := true }) ""
    let count := report.infrastructureFailures.size
    totalTests := totalTests + count
    totalErrors := totalErrors + count
    suites := suites ++ s!"  <testsuite name=\"lean-fmt\" tests=\"{count}\" failures=\"0\" \
      errors=\"{count}\">\n{body}  </testsuite>\n"
  return s!"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
    <testsuites name=\"lean-fmt\" tests=\"{totalTests}\" failures=\"{totalFailures}\" \
      errors=\"{totalErrors}\">\n{suites}</testsuites>\n"

/-- Render one report. Pure: the caller decides where the bytes go. -/
private def formatReport (format : ReportFormat) (positions : PositionIndex) (root : String)
    (report : RunReport) : String :=
  match format with
  | .text => textReport report
  | .concise => conciseReport positions report
  | .json => (Lean.toJson report).compress ++ "\n"
  | .github => githubReport positions report
  | .sarif => sarifReport positions root report
  | .junit => junitReport positions report

/-- Write a rendered report to `path` atomically: a sibling temporary, then `rename`.

A consumer polling the path never observes a truncated SARIF log, and a failed write leaves the
previous report intact rather than a half-file. -/
private def writeReportFile (path : String) (contents : String) : IO Unit := do
  let target := FilePath.mk path
  let temporary := FilePath.mk (path ++ ".lean-fmt-tmp")
  try
    IO.FS.writeFile temporary contents
    IO.FS.rename temporary target
  catch error =>
    if ← temporary.pathExists then IO.FS.removeFile temporary
    throw error

/-- Emit a report to stdout or to `--output-file`.

**A closed stdout is not an error.** `lean-fmt check … | head -1` is the standard idiom, and a
`lean-fmt: broken pipe` in the user's terminal — or a failed pipeline — would be the wrong answer to
it. Nothing handled `EPIPE` before this stack; that gap predates the new formats and this closes it
for all six. A failure to write an `--output-file` is a different case and stays fatal (§9.2):
otherwise it loses data silently. -/
private def emitReport (outputFile? : Option String) (contents : String) : IO Unit :=
  match outputFile? with
  | some path => writeReportFile path contents
  | none => try IO.print contents; (← IO.getStdout).flush catch _ => pure ()

private def renderReport (format : ReportFormat) (report : RunReport) : IO Unit :=
  emitReport none (formatReport format PositionIndex.empty "" report)

/-- Reject an `--output-file` this run could not write, **before** the run happens.

An analysis that then cannot write its report has wasted the whole run. The message names the
caller's own argument, as every other path-taking surface here does. -/
private def validateOutputFile (path : String) : IO (Except String Unit) := do
  let target := FilePath.mk path
  if ← target.isDir then
    return .error s!"--output-file is a directory: {path}"
  match target.parent with
  | some parent =>
    if parent.toString.isEmpty || (← parent.pathExists) then return .ok ()
    return .error s!"--output-file directory does not exist: {path}"
  | none => return .ok ()

/-- The absolute `file://` URI SARIF's `%SRCROOT%` resolves relative paths against, with the trailing
slash the base of a relative reference needs.

The same rule encodes the root as a result's path: a checkout under `~/My Projects/` is not a corner
case, and a space here would break every URI in the run rather than one. -/
private def rootUri (root : FilePath) : IO String := do
  let absolute ← try IO.FS.realPath root catch _ => pure root
  return s!"file://{uriPathEncode absolute.toString}/"

private def renderStatistics (report : RunReport) : IO Unit :=
  IO.eprintln s!"lean-fmt statistics: mode={report.mode} files={report.files.size} \
    findings={report.findings} changed={report.changed} written={report.written} \
    broken={report.broken} rejected={report.rejected} withheld_unsafe={report.withheldUnsafe} \
    suppressed={report.suppressed} infrastructure_failures={report.infrastructureFailures.size}"

/-- `writer` is whether this run publishes source (`fix`, or `format` without `--check`). A writer that
successfully published a change exits 0, like `ruff format`/`ruff check --fix`; a non-writing preview
(`check`, `diff`, `format --check`) exits 1 when anything would change (the CI code). Both exit 2 on
infrastructure failure and 1 on a broken/rejected file. -/
private def reportExitCode (writer : Bool) (report : RunReport) : UInt32 :=
  if !report.infrastructureFailures.isEmpty then 2
  else if report.broken > 0 || report.rejected > 0 then 1
  else if !writer && report.changed > 0 then 1 else 0

private def renderRules (format : ReportFormat) : IO Unit :=
  match format with
  | .json => IO.println (Lean.toJson allRulesJson).compress
  | _ =>
    for info in allRuleInfos do
      let fix := if info.fixable then "fixable" else "report-only"
      let enabled := if info.defaultEnabled then "default" else "optional"
      IO.println s!"{info.code}\t{info.category}\t{info.lifecycle.toWire}\t{fix}\t{enabled}\t{info.summary}"

/-- `explain RULE` — one rule's full description, all of it from the registry. A live rule prints
its `explainText`/`ruleInfoJson`; a retired code prints its disposition; a meta self-diagnostic
(`FMT900`/`FMT901`, which no registry holds because neither is selectable) prints its description.
All three exit 0, because `explain` is discovery. Only a token the product could never have emitted
errors (exit 2). -/
private def renderExplain (format : ReportFormat) (code : String) : IO UInt32 := do
  match ruleInfoByCode? code with
  | some info =>
    match format with
    | .json => IO.println (ruleInfoJson info (tierWireOf info.code)).compress
    | _ => IO.print (explainText info)
    return 0
  | none =>
    match reservedDisposition? code with
    | some disposition =>
      match format with
      | .json => IO.println (Lean.Json.mkObj
          [("code", .str code), ("lifecycle", .str "retired"), ("disposition", .str disposition)]).compress
      | _ => IO.println s!"{code}  [retired]\n  {disposition}"
      return 0
    | none =>
      match metaDescription? code with
      | some description =>
        match format with
        | .json => IO.println (Lean.Json.mkObj
            [("code", .str code), ("lifecycle", .str "meta"), ("description", .str description)]).compress
        | _ => IO.println s!"{code}  [meta]\n  {description}"
        return 0
      | none =>
        IO.eprintln s!"unknown rule: {code}"
        return 2

/-- `docs` — generate `docs/rules/{index,FMT###}.md` from the registry, or (`--check`) verify the
committed tree matches, which is the doc-drift / undocumented-rule invariant (`notes/01-schema.md` §9). -/
private def runDocs (root : FilePath) (check : Bool) : IO UInt32 := do
  let dir := root / "docs" / "rules"
  if check then
    let mut drift := #[]
    for (name, content) in catalogDocs do
      let path := dir / name
      let actual? ← if ← path.pathExists then some <$> IO.FS.readFile path else pure none
      unless actual? == some content do drift := drift.push name
    if drift.isEmpty then
      IO.println s!"docs up to date ({catalogDocs.size} files)"
      return 0
    IO.eprintln s!"generated docs drifted from {dir}: {String.intercalate ", " drift.toList}"
    IO.eprintln "run `lean-fmt docs` to regenerate"
    return 1
  else
    IO.FS.createDirAll dir
    for (name, content) in catalogDocs do
      IO.FS.writeFile (dir / name) content
    IO.println s!"wrote {catalogDocs.size} files to {dir}"
    return 0

private def renderClean (format : ReportFormat) (report : CleanReport) : IO Unit :=
  match format with
  | .json => IO.println (Lean.toJson report).compress
  | _ =>
    let cache := FilePath.mk report.root / ".lean-fmt-cache"
    if report.removed then IO.println s!"removed {cache}"
    else IO.println s!"cache already absent: {cache}"

private def renderCompilerSetup (format : ReportFormat) : IO Unit := do
  let report := compilerSetupReport
  match format with
  | .json => IO.println (Lean.toJson report).compress
  | _ => do
    IO.println s!"schema: {report.schema}"
    IO.println s!"package: {report.package}"
    IO.println s!"plugin target: {report.plugin}"
    IO.println s!"module facet: {report.facet}"
    IO.println s!"toolchain: {report.toolchain}"
    for step in report.guidance, index in [1:report.guidance.size + 1] do
      IO.println s!"{index}. {step}"

private def renderCompilerStatus (format : ReportFormat) (report : CompilerStatusReport) : IO Unit :=
  match format with
  | .json => IO.println (Lean.toJson report).compress
  | _ => do
    for item in report.modules do
      IO.println s!"{item.path}\t{item.module}\t{item.status}"
    IO.println s!"ready={report.ready} missing={report.missing} unbuilt={report.unbuilt}"

private def parseConfigShowArgs (args : List String) :
    Except String (FilePath × Option FilePath × String × ReportFormat) :=
  let rec loop (remaining : List String) (root : FilePath) (config? : Option FilePath)
      (target? : Option String) (format : ReportFormat) :
      Except String (FilePath × Option FilePath × String × ReportFormat) :=
    match remaining with
    | [] =>
      match target? with
      | some target => .ok (root, config?, target, format)
      | none => .error "usage: lean-fmt config show PATH [--root PATH] [--config PATH] [--json]"
    | "--json" :: rest => loop rest root config? target? .json
    | "--root" :: dir :: rest => loop rest dir config? target? format
    | "--config" :: file :: rest => loop rest root (some file) target? format
    | "--root" :: [] => .error "--root expects a path"
    | "--config" :: [] => .error "--config expects a path"
    | option :: rest =>
      if option.startsWith "-" then .error s!"unknown config option: {option}"
      else if target?.isSome then .error "config show takes exactly one path"
      else loop rest root config? (some option) format
  loop args "." none none .text

/- Text rendering is deliberately one `key = value  (origin)` line per setting with no alignment
padding: callers diff and grep this output between runs, and column padding lets an unrelated key's
length change every other line. -/
private def renderConfigShow (format : ReportFormat) (report : ConfigReport) : IO Unit :=
  match format with
  | .json => IO.println (Lean.toJson report).compress
  | _ => do
    IO.println s!"path: {report.path}"
    IO.println s!"config: {report.configFile}"
    if report.contributingFiles.isEmpty then
      IO.println "contributing files: (none)"
    else
      IO.println s!"contributing files: {String.intercalate ", " report.contributingFiles.toList}"
    if report.ignoreSources.isEmpty then
      IO.println "ignore sources: (none)"
    else
      IO.println s!"ignore sources: {String.intercalate ", " report.ignoreSources.toList}"
    IO.println s!"selected: {report.selected} ({report.gateDescription})"
    for notice in report.notices do
      IO.println s!"notice: {notice}"
    IO.println "settings:"
    for setting in report.settings do
      IO.println s!"  {setting.key} = {setting.value}  ({setting.origin})"

/-- One stream answer viewed as a one-file run report, so the four finding-shaped renderers serve the
stdin surface without a second implementation of any of them. -/
private def streamAsRunReport (mode : RunMode) (report : StreamReport) : RunReport :=
  { mode := mode.toString
    files := #[{ path := report.path, status := report.status,
                 findings := report.findings, diagnostics := report.diagnostics }]
    findings := report.findings.size
    changed := if report.changed then 1 else 0
    written := 0
    broken := if report.status == "broken" then 1 else 0
    rejected := if report.status == "rejected" then 1 else 0
    withheldUnsafe := 0, suppressed := 0, withheldRedundant := 0
    infrastructureFailures := #[] }

/-- Render one stream answer.

**stdout carries the result and nothing else** — bytes for `format`/`fix`, a unified diff for `diff`,
nothing for `check`/`format --check`. Findings and the range report go to stderr in text mode so a
pipe consumer needs no framing (`notes/01-stream-range.md` §5.1). `--json` puts the whole answer,
source map included, on stdout instead, because a machine consumer asked for structure.

The reported actual range is printed even when it is wider than the request: a caller cannot work
that widening out for itself, and hiding it would leave the "outside this range is untouched"
promise with no way to check it. -/
private def renderStream (mode : RunMode) (format : ReportFormat) (outputFile? : Option String)
    (positions : PositionIndex) (root : String) (report : StreamReport) : IO Unit := do
  match format with
  | .json => IO.println report.toJson.compress
  | .text =>
    if let some diff := report.diff then IO.print diff
    if let some output := report.output then IO.print output
    for finding in report.findings do
      IO.eprintln s!"{report.path}:{finding.range.start}-{finding.range.stop}: \
        {finding.code} {finding.message}"
    for diagnostic in report.diagnostics do
      IO.eprintln s!"{report.path}: {report.status}: {diagnostic}"
    if let some actual := report.actual? then
      IO.eprintln s!"{report.path}: formatted range {actual.start}-{actual.stop}"
  | _ =>
    -- stdout still carries the result and nothing else (`ruff-14` §5.1), so a finding-shaped report
    -- goes to stderr — beside where text mode already puts findings — unless the caller named a file
    -- for it. Putting it on stdout would corrupt the bytes a `format -` consumer is piping.
    if let some diff := report.diff then IO.print diff
    if let some output := report.output then IO.print output
    let rendered := formatReport format positions root (streamAsRunReport mode report)
    match outputFile? with
    | some path => writeReportFile path rendered
    | none => IO.eprint rendered

/-- Exit code for a stream answer.

The file-target rule (`reportExitCode`) with one substitution: a stdin mode that **emits** its result
is the writer, so `format -` and `fix -` exit 0 having streamed, as their file-target forms exit 0
having published. `check`, `diff`, and `format --check` stay previews and keep the CI code. -/
private def streamExitCode (writer : Bool) (report : StreamReport) : UInt32 :=
  if report.status == "broken" || report.status == "rejected" then 1
  else if !writer && report.changed then 1 else 0

private unsafe def runStreamCommand (mode : RunMode) (command : FileCommand)
    (filename : String) : IO UInt32 := do
  -- Read bytes and decode here rather than through `IO.FS.Stream.readToEnd`, which throws its own
  -- wording ("Tried to read from stream containing non UTF-8 data"). §6 names the message a caller
  -- sees, and the contract fixes that message, so it must not be the runtime's chance phrasing.
  let bytes ← (← IO.getStdin).readBinToEnd
  let some raw := String.fromUTF8? bytes
    | IO.eprintln "lean-fmt: stdin is not valid UTF-8"; return 2
  -- Ranges index the normalized source, the one coordinate system every offset in this product uses.
  let (normalized, _) := LosslessSource.normalize raw
  let range? ← match command.range? with
    | none => pure none
    | some spec =>
      match resolveRange normalized spec with
      | .ok range => pure (some range)
      | .error message => IO.eprintln message; return 2
  let report ← stream {
    mode
    root := command.run.root
    filename
    source := raw
    range?
    maxMemoryGiB := command.run.maxMemoryGiB
    configPath? := command.run.configPath?
    selection := {
      select := command.run.select, extendSelect := command.run.extendSelect,
      ignore := command.run.ignore, fixable := command.run.fixable,
      unfixable := command.run.unfixable, extendFixable := command.run.extendFixable,
      preview := command.run.preview }
    unsafeFixes := command.run.unsafeFixes
    formatCheck := command.run.formatCheck
  }
  -- The buffer never became a project snapshot, so the CLI that decoded it is the only holder of the
  -- bytes a line/column resolution needs.
  let positions := PositionIndex.ofSource report.path normalized report.findings
  renderStream mode command.outputFormat command.outputFile? positions
    (← rootUri command.run.root) report
  return streamExitCode (mode == .fix || command.run.writesFormat) report

/-- Run one request and emit one report. Shared by the single-shot and watch paths so that a
generation is *the same thing* a plain run is — there is no second execution or rendering path
(`notes/01-watch-generations.md` §3, §4). -/
private unsafe def runOneGeneration (command : FileCommand) : IO UInt32 := do
  let outcome ← execute command.run
  -- The one presentation phase on the profile channel. `ruff-15` measured rendering as linear in
  -- report size and *not* a scale risk, so this exists to keep the accounted fraction honest rather
  -- than because it is suspected — a phase schema that omits a step because someone expects it to be
  -- cheap cannot notice the day it stops being cheap.
  let rendered ← withPhase "render_report" <|
    pure (formatReport command.outputFormat outcome.positions (← rootUri command.run.root)
      outcome.report)
  emitReport command.outputFile? rendered
  if command.statistics then renderStatistics outcome.report
  return reportExitCode (command.run.mode == .fix || command.run.writesFormat) outcome.report

/-- Resolve a `--changed` selection into the request's file list.

Returns `none` when version control selected nothing, which is a **success that must not run**: an
empty `files` array means "the whole project" to `execute`, so passing an empty selection through
would format everything — the opposite of what the caller asked for. §9.6 requires an explicit
notice rather than a silent clean report, because "nothing changed" and "the project is clean" are
two facts a CI log must be able to tell apart. -/
private def resolveChanged (command : FileCommand) (comparison : GitSelection.Comparison) :
    IO (Except String (Option FileCommand)) := do
  match ← GitSelection.select command.run.root comparison with
  | .error message => return .error message
  | .ok selection =>
    -- Provenance goes to stderr rather than into `RunReport`. `RunReport` is `ruff-15`'s frozen JSON
    -- compatibility surface, compared byte-for-byte against `01-json-golden-check.json`; adding a
    -- field would break that contract to carry presentation (`results/02-implementation.md`).
    IO.eprintln s!"lean-fmt: changed-file selection: {selection.comparison.describe}"
    if let some resolved := selection.resolvedBase? then
      IO.eprintln s!"lean-fmt: resolved base: {resolved}"
    -- Every withheld path git named, because dropping one silently makes a partial run look
    -- complete (§9.6).
    for drop in selection.dropped do
      IO.eprintln s!"lean-fmt: not selected: {drop.describe}"
    if selection.paths.isEmpty then
      IO.eprintln s!"lean-fmt: no changed Lean sources under {command.run.root}"
      return .ok none
    IO.eprintln s!"lean-fmt: {selection.paths.size} changed path(s) selected; \
      this run covers that subset, not the whole project"
    return .ok (some { command with run := { command.run with files := selection.paths } })

/-- The child argv for one watch generation: the caller's own arguments with the watch flags removed.

Rebuilt from the raw argument list rather than re-rendered from the parsed `FileCommand`, so a child
runs *exactly* what the user asked for. Re-rendering would mean keeping a second, silently diverging
spelling of every flag, and once those diverge the watched run and the plain run analyze different
things. -/
private def generationArgs (mode : RunMode) (args : List String) : Array String := Id.run do
  let mut out : Array String := #[mode.toString]
  let mut remaining := args
  while true do
    match remaining with
    | [] => break
    | "--watch" :: rest => remaining := rest
    | "--poll-interval" :: _ :: rest => remaining := rest
    | argument :: rest => out := out.push argument; remaining := rest
  return out

private unsafe def runFileCommand (mode : RunMode) (args : List String) : IO UInt32 := do
  let command ← match parseFileArgs mode args with
    | .ok command => pure command
    | .error message => IO.eprintln message; return 2
  if let .error message := validateStdin mode command then
    IO.eprintln message
    return 2
  if let .error message := validateWatch mode command then
    IO.eprintln message
    return 2
  if let .error message := validateChanged command then
    IO.eprintln message
    return 2
  if let some path := command.outputFile? then
    if let .error message := ← validateOutputFile path then
      IO.eprintln message
      return 2
  if let some filename := command.stdinFilename? then
    try
      return ← runStreamCommand mode command filename
    catch error =>
      IO.eprintln s!"lean-fmt: {error}"
      return 2
  try
    if command.watch then
      -- Each generation is a complete `execute` over the whole project, not a changed-file subset:
      -- the fixed per-run cost (workspace load, discovery and cache epoch) does not vary with file
      -- count, so selecting a subset would save little and give up the completeness guarantee
      -- (`notes` §4, `evidence` §3). The aggregate result cache already supplies the
      -- incrementality, per file and keyed on content.
      -- **Each generation is a fresh child process**, not a second in-process `execute`.
      --
      -- The reason first written here was wrong; `ruff-16b` RCI-FINAL corrected it. It claimed a
      -- second `execute` in one process cannot reuse the result cache. `execute` opens a fresh
      -- `ResultCache` per call and retains no in-process state to go stale, and the comparison
      -- behind the claim timed two different workloads, cold-after-edit against an unchanged tree.
      -- Its slow side was the whole-project cache invalidation `ruff-16b` then removed.
      --
      -- Re-exec stays, on its own measurement rather than that one: spawning costs little beside a
      -- warm generation. The fixed cost is workspace load, discovery and epoch computation, which
      -- an in-process generation pays too, *unless* it retains the workspace across generations.
      -- Retention is the only real saving, and it is the one to refuse: deciding a generation
      -- against build state observed before the edit is the staleness class `ruff-16b` exists to
      -- remove, and it would need `open?`'s refusal to manufacture a partial epoch weakened to be
      -- worth anything.
      --
      -- Re-exec buys the parent's memory staying flat across generations, which is "no workspace
      -- retention" as `notes` §6 permitted, now measured rather than assumed. The child inherits
      -- this process's stdout and stderr, so framing (§7) is unchanged, and a generation that dies
      -- cannot take the session with it.
      let self ← IO.appPath
      Watch.run { root := command.run.root, configPath? := command.run.configPath?,
                  pollMillis := command.pollMillis } fun counter => do
        -- The banner goes to stderr so a line-oriented consumer's stdout stays uncontaminated, and a
        -- document-format consumer is reading `--output-file` anyway (§7).
        IO.eprintln s!"lean-fmt: generation {counter}"
        try
          let child ← IO.Process.spawn {
            cmd := self.toString
            args := generationArgs mode args
          }
          let code ← child.wait
          if code != 0 && code != 1 then
            IO.eprintln s!"lean-fmt: generation {counter} exited {code}"
        catch error =>
          -- One generation's failure must not end the session: the user's next edit is often the
          -- fix. Report it and keep watching (roadmap: "failure recovery").
          IO.eprintln s!"lean-fmt: generation {counter} failed: {error}"
      -- `Watch.run` does not return; a signal ends the session. Exit 0 because asking a long-running
      -- service to stop is not a failure, and because every write is atomic temp-then-rename, an
      -- abrupt exit cannot leave a torn report (§8).
      return 0
    let command ← match command.changed? with
      | none => pure command
      | some comparison =>
        match ← resolveChanged command comparison with
        | .error message => IO.eprintln s!"lean-fmt: {message}"; return 2
        | .ok none => return 0
        | .ok (some resolved) => pure resolved
    runOneGeneration command
  catch error =>
    IO.eprintln s!"lean-fmt: {error}"
    return 2

unsafe def runCli (arguments : List String) : IO UInt32 := do
  let args := match arguments with | "--" :: rest => rest | _ => arguments
  if let some result ← Application.runInternal? args then
    return result
  match args with
  | "--help" :: _ => IO.println usage; return 0
  | command :: "--help" :: _ =>
    if #["check", "format", "diff", "fix", "organize", "lsp", "rules", "explain", "docs", "clean", "compiler", "config"].contains command then
      IO.println usage
      return 0
    IO.eprintln usage
    return 2
  | "check" :: rest => runFileCommand .check rest
  | "format" :: rest => runFileCommand .format rest
  | "diff" :: rest => runFileCommand .diff rest
  | "fix" :: rest => runFileCommand .fix rest
  | "organize" :: rest =>
    let command ← match parseOrganizeArgs rest with
      | .ok command => pure command
      | .error message => IO.eprintln message; return 2
    try
      let report ← organize command.request
      renderReport command.outputFormat report
      if !report.infrastructureFailures.isEmpty then return 2
      else if report.rejected > 0 then return 1
      else if command.request.check && report.changed > 0 then return 1
      else return 0
    catch error =>
      IO.eprintln s!"lean-fmt: {error}"
      return 2
  | "lsp" :: rest =>
    let options ← match parseLspArgs rest with
      | .ok options => pure options
      | .error message => IO.eprintln message; return 2
    try
      LanguageServer.serveLanguageServer options
    catch error =>
      IO.eprintln s!"lean-fmt: {error}"
      return 2
  | "rules" :: rest =>
    let format ← match parseOutputArgs rest with
      | .ok format => pure format
      | .error message => IO.eprintln message; return 2
    renderRules format
    return 0
  | "explain" :: rest =>
    -- `explain RULE [--json]`: exactly one rule token, optional `--json`.
    match rest.filter (·.startsWith "-" |>.not), rest.contains "--json" with
    | [code], json => renderExplain (if json then .json else .text) code
    | [], _ => IO.eprintln "usage: lean-fmt explain RULE [--json]"; return 2
    | _, _ => IO.eprintln "explain takes exactly one rule code"; return 2
  | "docs" :: rest =>
    let rec loop (remaining : List String) (root : FilePath) (check : Bool) : IO UInt32 := do
      match remaining with
      | [] => runDocs root check
      | "--check" :: more => loop more root true
      | "--root" :: dir :: more => loop more dir check
      | option :: _ => IO.eprintln s!"unknown docs option: {option}"; return 2
    loop rest "." false
  | "clean" :: rest =>
    let command ← match parseRootArgs rest with
      | .ok command => pure command
      | .error message => IO.eprintln message; return 2
    try
      renderClean command.outputFormat (← clean command.root)
      return 0
    catch error =>
      IO.eprintln s!"lean-fmt: {error}"
      return 2
  | "config" :: "show" :: rest =>
    let (root, config?, target, format) ← match parseConfigShowArgs rest with
      | .ok parsed => pure parsed
      | .error message => IO.eprintln message; return 2
    try
      renderConfigShow format (← describeConfig root config? target)
      return 0
    catch error =>
      IO.eprintln s!"lean-fmt: {error}"
      return 2
  | "compiler" :: "setup" :: rest =>
    let format ← match parseOutputArgs rest with
      | .ok format => pure format
      | .error message => IO.eprintln message; return 2
    renderCompilerSetup format
    return 0
  | "compiler" :: "status" :: rest =>
    let command ← match parseStatusArgs rest with
      | .ok command => pure command
      | .error message => IO.eprintln message; return 2
    try
      renderCompilerStatus command.outputFormat (← compilerStatus command.request)
      return 0
    catch error =>
      IO.eprintln s!"lean-fmt: {error}"
      return 2
  | _ =>
    IO.eprintln usage
    return 2

end LeanFmt.Internal.Cli
