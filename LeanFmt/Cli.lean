module

import all LeanFmt.Service

open System

namespace LeanFmt.Internal.Cli

open LeanFmt.Internal LeanFmt.Internal.Application LeanFmt.Internal.Service

private inductive ReportFormat where
  | text
  | json

private structure FileCommand where
  run : RunRequest
  outputFormat : ReportFormat := .text
  statistics : Bool := false

private structure RootCommand where
  root : FilePath := "."
  outputFormat : ReportFormat := .text

private structure StatusCommand where
  request : CompilerStatusRequest := {}
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
    | "--max-memory" :: value :: rest =>
      match value.toNat? with
      | some amount => loop rest { options with maxMemoryGiB := amount }
      | none => .error "--max-memory expects a whole number of GiB"
    | option :: _ => .error s!"unknown serve option: {option}"
  loop args {}

private def usage : String := "\
usage: lean-fmt {check|format|diff|fix} [OPTIONS] [FILE...]\n\
       lean-fmt serve [--root PATH] [--config PATH] [--select SELECTOR]\n\
                      [--ignore SELECTOR] [--max-memory GIB]\n\
       lean-fmt rules [--json]\n\
       lean-fmt clean [--root PATH] [--json]\n\
       lean-fmt compiler {setup|status} [--root PATH] [--json]\n\
\n\
file options:\n\
  --root PATH          Lake project root (default: .)\n\
  --config PATH        explicit lean-fmt.toml\n\
  --select SELECTOR    activate a rule/category/all (repeatable)\n\
  --ignore SELECTOR    deactivate a rule/category/all (repeatable)\n\
  --json               deterministic JSON output\n\
  --statistics         write aggregate statistics to stderr\n\
  --no-cache           neither read nor write result cache entries\n\
  --max-memory GIB     aggregate operating envelope (default: 8)\n\
  --unsafe-fixes       apply/preview unsafe fixes too (default: safe only)\n\
  --check-elab         fix: require elaboration validation"

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
    | "--ignore" :: selector :: rest =>
      loop rest { command with run := {
        command.run with ignore := command.run.ignore.push selector } }
    | "--statistics" :: rest => loop rest { command with statistics := true }
    | "--check-elab" :: rest =>
      if mode == .fix then
        loop rest { command with run := { command.run with validationLevel := .elaboration } }
      else
        .error "--check-elab is valid only for fix"
    | "--unsafe-fixes" :: rest =>
      loop rest { command with run := { command.run with unsafeFixes := true } }
    | "--max-memory" :: value :: rest =>
      match value.toNat? with
      | some amount =>
        loop rest { command with run := { command.run with maxMemoryGiB := amount } }
      | none => .error "--max-memory expects a whole number of GiB"
    | option :: rest =>
      if option.startsWith "-" then .error s!"unknown option: {option}"
      else loop rest { command with run := { command.run with files := command.run.files.push option } }
  loop args { run := { mode, root := ".", files := #[] } }

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

private def renderText (report : RunReport) : IO Unit := do
  match report.mode with
  | "format" =>
    for file in report.files do
      if let some formatted := file.formatted then
        IO.println s!"=== {file.path} ({formatted.utf8ByteSize} bytes) ==="
        IO.print formatted
        unless formatted.endsWith "\n" do IO.println ""
        IO.println s!"=== end {file.path} ==="
      for diagnostic in file.diagnostics do
        IO.println s!"{file.path}: {file.status}: {diagnostic}"
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

private def reportExitCode (mode : RunMode) (report : RunReport) : UInt32 :=
  if !report.infrastructureFailures.isEmpty then 2
  else if report.broken > 0 || report.rejected > 0 then 1
  else if mode != .fix && report.changed > 0 then 1 else 0

private def renderRules (format : ReportFormat) : IO Unit :=
  match format with
  | .json => IO.println (Lean.toJson ruleRegistry).compress
  | .text =>
    for rule in ruleRegistry do
      let fix := if rule.info.fixable then "fixable" else "report-only"
      let enabled := if rule.info.defaultEnabled then "default" else "optional"
      IO.println s!"{rule.info.code}\t{rule.info.category}\t{fix}\t{enabled}\t{rule.info.summary}"

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

private unsafe def runFileCommand (mode : RunMode) (args : List String) : IO UInt32 := do
  let command ← match parseFileArgs mode args with
    | .ok command => pure command
    | .error message => IO.eprintln message; return 2
  try
    let report ← execute command.run
    renderReport command.outputFormat report
    if command.statistics then renderStatistics report
    return reportExitCode mode report
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
    if #["check", "format", "diff", "fix", "serve", "rules", "clean", "compiler"].contains command then
      IO.println usage
      return 0
    IO.eprintln usage
    return 2
  | "check" :: rest => runFileCommand .check rest
  | "format" :: rest => runFileCommand .format rest
  | "diff" :: rest => runFileCommand .diff rest
  | "fix" :: rest => runFileCommand .fix rest
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
