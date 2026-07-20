module

import all LeanFmt.Service

open System

namespace LeanFmt.Internal.Cli

open LeanFmt.Internal LeanFmt.Internal.Application LeanFmt.Internal.Service

private inductive ReportFormat where
  | text
  | json

/-! ## stdin/stdout and range parsing (`ruff-14` RSF-IMPL)

Presentation only: this file decides what the caller typed and how to print the answer.
`Application.stream` owns identity, configuration, execution, expansion, and the splice. -/

/-- A `--range`/`--range-lines` argument, before it is resolved against the received bytes.

Line/column is kept symbolic until the source is in hand because a column is a **codepoint** offset
into a line and cannot become a byte offset without the line (`notes/01-stream-range.md` §3). Byte
form is already the internal encoding and passes straight through. -/
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

Clamping rather than failing is deliberate: an editor's end-of-selection routinely sits one past the
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
  statistics : Bool := false
  /-- The `-` target was given: read the one source from stdin and stream the answer. -/
  stdin : Bool := false
  stdinFilename? : Option String := none
  range? : Option RangeSpec := none
  /-- Which spelling the caller used, so a diagnostic names the flag they typed. -/
  rangeFlag : String := "--range"

private structure RootCommand where
  root : FilePath := "."
  outputFormat : ReportFormat := .text

private structure StatusCommand where
  request : CompilerStatusRequest := {}
  outputFormat : ReportFormat := .text

private structure OrganizeCommand where
  request : OrganizeRequest := { root := ".", files := #[] }
  outputFormat : ReportFormat := .text

private def parseServeArgs (args : List String) : Except String ServeOptions :=
  let rec loop (remaining : List String) (options : ServeOptions) :=
    match remaining with
    | [] => .ok options
    | "--root" :: root :: rest => loop rest { options with root }
    | "--config" :: path :: rest => loop rest { options with configPath? := some path }
    | "--select" :: selector :: rest =>
      loop rest { options with select := options.select.push selector }
    | "--ignore" :: selector :: rest =>
      loop rest { options with ignore := options.ignore.push selector }
    | "--preview" :: rest => loop rest { options with preview := true }
    | "--max-memory" :: value :: rest =>
      match value.toNat? with
      | some amount => loop rest { options with maxMemoryGiB := amount }
      | none => .error "--max-memory expects a whole number of GiB"
    | option :: _ => .error s!"unknown serve option: {option}"
  loop args {}

private def usage : String := "\
usage: lean-fmt {check|format|diff|fix} [OPTIONS] [FILE...]\n\
       lean-fmt {check|format|diff|fix} - --stdin-filename PATH [--range S:E]\n\
       lean-fmt serve [--root PATH] [--config PATH] [--select SELECTOR]\n\
                      [--ignore SELECTOR] [--max-memory GIB]\n\
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
  --json               deterministic JSON output\n\
  --statistics         write aggregate statistics to stderr\n\
  --no-cache           neither read nor write result cache entries\n\
  --max-memory GIB     aggregate operating envelope (default: 8)\n\
  --unsafe-fixes       apply/preview unsafe fixes too (default: safe only)\n\
  --check              format: report what would change, write nothing (CI preview)\n\
  --check-elab         fix: require elaboration validation\n\
\n\
stdin options (target `-`; never writes a file or a cache entry):\n\
  --stdin-filename P   required with `-`: the buffer's identity for config/module resolution\n\
  --range START:STOP   format only this half-open normalized byte range (format only)\n\
  --range-lines R      format only L:C-L:C (1-based line, 1-based codepoint column)"

private def parseFileArgs (mode : RunMode) (args : List String) : Except String FileCommand :=
  let rec loop (remaining : List String) (command : FileCommand) :=
    match remaining with
    | [] => .ok command
    | "--root" :: root :: rest =>
      loop rest { command with run := { command.run with root } }
    | "--json" :: rest => loop rest { command with outputFormat := .json }
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
    | "--check-elab" :: rest =>
      if mode == .fix then
        loop rest { command with run := { command.run with validationLevel := .elaboration } }
      else
        .error "--check-elab is valid only for fix"
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

Each rejection is a frozen clause of `notes/01-stream-range.md` §2, and the reason each is an error
rather than a fallback is that the quiet alternative is worse: a `-` with no identity would format
against built-in defaults and silently disagree with the same bytes on disk, and a `--range` without
`-` would have to mean a partial in-place write, which is a write surface this stack deliberately does
not build. -/
private def validateStdin (command : FileCommand) : Except String Unit := do
  if command.stdin then
    if command.stdinFilename?.isNone then
      .error "stdin requires --stdin-filename to establish project identity"
    else if !command.run.files.isEmpty then
      .error "- must be the only target"
    else .ok ()
  else if command.stdinFilename?.isSome then
    .error "--stdin-filename is valid only with the - stdin target"
  else if command.range?.isSome then
    .error s!"{command.rangeFlag} is valid only with the - stdin target"
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

private def renderText (report : RunReport) : IO Unit := do
  match report.mode with
  | "organize" =>
    for file in report.files do
      unless file.status == "clean" do IO.println s!"{file.path}: {file.status}"
      for diagnostic in file.diagnostics do IO.println s!"  {diagnostic}"
  | "format" =>
    -- `format` publishes in place by default (`ruff-11d`): a concise per-file summary, never the file
    -- body. `formatted` means written; `would-format` is the `--check` preview of a file that would
    -- change. A clean file is silent. The full canonical text still rides `--json` (`file.formatted`).
    for file in report.files do
      unless file.status == "clean" do IO.println s!"{file.path}: {file.status}"
      for diagnostic in file.diagnostics do
        IO.println s!"  {diagnostic}"
  | "diff" =>
    for file in report.files do
      if let some diff := file.diff then IO.print diff
      for diagnostic in file.diagnostics do
        IO.println s!"{file.path}: {file.status}: {diagnostic}"
  | "fix" =>
    for file in report.files do
      unless file.status == "clean" do IO.println s!"{file.path}: {file.status}"
      for diagnostic in file.diagnostics do IO.println s!"  {diagnostic}"
      if file.withheldUnsafe > 0 then
        IO.println s!"  {file.withheldUnsafe} unsafe fix(es) withheld; rerun with --unsafe-fixes to apply"
  | _ =>
    for file in report.files do
      for finding in file.findings do
        -- A fix's applicability is shown next to the finding so a reader knows whether `fix` would
        -- apply it by default (safe), only under `--unsafe-fixes` (unsafe), or never (display-only).
        let fixTag := match finding.fix? with
          | some fix => s!" [{fix.applicability}]"
          | none => ""
        IO.println s!"{file.path}:{finding.range.start}-{finding.range.stop}: \
          {finding.code} {finding.message}{fixTag}"
      for diagnostic in file.diagnostics do
        IO.println s!"{file.path}: {file.status}: {diagnostic}"
  IO.println s!"mode={report.mode} files={report.files.size} findings={report.findings} \
    changed={report.changed} written={report.written} broken={report.broken} \
    rejected={report.rejected} withheld_unsafe={report.withheldUnsafe} \
    suppressed={report.suppressed} infrastructure_failures={report.infrastructureFailures.size}"

private def renderReport (format : ReportFormat) (report : RunReport) : IO Unit :=
  match format with
  | .text => renderText report
  | .json => IO.println (Lean.toJson report).compress

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
  | .text =>
    for info in allRuleInfos do
      let fix := if info.fixable then "fixable" else "report-only"
      let enabled := if info.defaultEnabled then "default" else "optional"
      IO.println s!"{info.code}\t{info.category}\t{info.lifecycle.toWire}\t{fix}\t{enabled}\t{info.summary}"

/-- `explain RULE` — one rule's full description, sourced entirely from the registry. A live rule prints
its `explainText`/`ruleInfoJson`; a retired code prints its disposition and exits 0 (`explain` is
discovery); an unknown token errors (exit 2). -/
private def renderExplain (format : ReportFormat) (code : String) : IO UInt32 := do
  match ruleInfoByCode? code with
  | some info =>
    match format with
    | .json => IO.println (ruleInfoJson info (tierWireOf info.code)).compress
    | .text => IO.print (explainText info)
    return 0
  | none =>
    match reservedDisposition? code with
    | some disposition =>
      match format with
      | .json => IO.println (Lean.Json.mkObj
          [("code", .str code), ("lifecycle", .str "retired"), ("disposition", .str disposition)]).compress
      | .text => IO.println s!"{code}  [retired]\n  {disposition}"
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
  | .text =>
    let cache := FilePath.mk report.root / ".lean-fmt-cache"
    if report.removed then IO.println s!"removed {cache}"
    else IO.println s!"cache already absent: {cache}"

private def renderCompilerSetup (format : ReportFormat) : IO Unit := do
  let report := compilerSetupReport
  match format with
  | .json => IO.println (Lean.toJson report).compress
  | .text => do
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
  | .text => do
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
padding: the output is meant to be diffed and grepped between runs, and column padding makes an
unrelated key's length change every other line. -/
private def renderConfigShow (format : ReportFormat) (report : ConfigReport) : IO Unit :=
  match format with
  | .json => IO.println (Lean.toJson report).compress
  | .text => do
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

/-- Render one stream answer.

**stdout carries the result and nothing else** — bytes for `format`/`fix`, a unified diff for `diff`,
nothing for `check`/`format --check`. Findings and the range report go to stderr in text mode so a
pipe consumer needs no framing (`notes/01-stream-range.md` §5.1). `--json` puts the whole answer,
source map included, on stdout instead, because a machine consumer asked for structure.

The reported actual range is printed even when it is wider than the request: that widening is the one
thing a caller cannot infer for itself, and hiding it would make the "outside this range is untouched"
promise unverifiable. -/
private def renderStream (format : ReportFormat) (report : StreamReport) : IO Unit := do
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

/-- Exit code for a stream answer.

The file-target rule (`reportExitCode`) with one substitution: a stdin mode that **emits** its result
is the writer, so `format -` and `fix -` exit 0 having streamed, exactly as their file-target twins
exit 0 having published. `check`, `diff`, and `format --check` stay previews and keep the CI code. -/
private def streamExitCode (writer : Bool) (report : StreamReport) : UInt32 :=
  if report.status == "broken" || report.status == "rejected" then 1
  else if !writer && report.changed then 1 else 0

private unsafe def runStreamCommand (mode : RunMode) (command : FileCommand)
    (filename : String) : IO UInt32 := do
  -- Read bytes and decode here rather than through `IO.FS.Stream.readToEnd`, which throws its own
  -- wording ("Tried to read from stream containing non UTF-8 data"). §6 names the message a caller
  -- sees, and a diagnostic the contract fixes must not be the runtime's incidental phrasing.
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
  renderStream command.outputFormat report
  return streamExitCode (mode == .fix || command.run.writesFormat) report

private unsafe def runFileCommand (mode : RunMode) (args : List String) : IO UInt32 := do
  let command ← match parseFileArgs mode args with
    | .ok command => pure command
    | .error message => IO.eprintln message; return 2
  if let .error message := validateStdin command then
    IO.eprintln message
    return 2
  if let some filename := command.stdinFilename? then
    try
      return ← runStreamCommand mode command filename
    catch error =>
      IO.eprintln s!"lean-fmt: {error}"
      return 2
  try
    let report ← execute command.run
    renderReport command.outputFormat report
    if command.statistics then renderStatistics report
    return reportExitCode (mode == .fix || command.run.writesFormat) report
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
    if #["check", "format", "diff", "fix", "organize", "serve", "rules", "explain", "docs", "clean", "compiler", "config"].contains command then
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
  | "serve" :: rest =>
    let options ← match parseServeArgs rest with
      | .ok options => pure options
      | .error message => IO.eprintln message; return 2
    try
      serve options
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
