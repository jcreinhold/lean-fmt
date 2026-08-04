/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

namespace LeanFmt.Internal.CliHelp

/-! # Per-command `--help`

The help *text* is the volatile half of the CLI — it churns every time a flag changes — and the
*renderer* is the stable half. Both live here, behind a two-function surface (`overviewHelp` and
`commandHelp?`), so `Cli.lean` owns dispatch and never formats a row.

One data table, `commandHelps`, names every command, says what it does and what it writes, and
lists only the options its parser accepts and that mean something for it. The root help's command
table is generated from the same array, so a command cannot be documented in one place and not the
other. -/

/-- One `--help` entry: the left column (flags with metavars) and its description. -/
private structure HelpEntry where
  flags : String
  desc : String

/-- Everything one command's `--help` says, as data. `usage` lines carry no `usage:` prefix;
`sections` are rendered in order with their titles; `notes` are wrapped paragraphs at the foot. -/
private structure CommandHelp where
  command : String
  summary : String
  description : String
  usage : Array String
  sections : Array (String × Array HelpEntry)
  notes : Array String := #[]

/-- Wrap `text` at `width` columns on word boundaries; words longer than `width` go on their own
line unbroken. -/
private def wrapHelp (width : Nat) (text : String) : List String :=
  let rec go (words : List String) (line : String) (lines : List String) : List String :=
    match words with
    | [] => (line :: lines).reverse
    | word :: rest =>
      if line.isEmpty then go rest word lines
      else
        if line.length + 1 + word.length <= width then go rest (line ++ " " ++ word) lines
        else go rest word (line :: lines)
  go (text.splitOn " ") "" []

/-- Cargo's help palette, as captured from `cargo help`: bold bright green section headers. -/
private def paintHeader (color : Bool) (s : String) : String :=
  if color then s!"\x1b[92m\x1b[1m{s}\x1b[39m\x1b[22m" else s

/-- Cargo's help palette: bold bright cyan literals (flags, command names, the binary). -/
private def paintLiteral (color : Bool) (s : String) : String :=
  if color then s!"\x1b[1m\x1b[96m{s}\x1b[0m" else s

/-- Cargo's help palette: cyan metavars and usage tails. -/
private def paintMeta (color : Bool) (s : String) : String :=
  if color then s!"\x1b[36m{s}\x1b[0m" else s

/-- One entry row: flags green, metavars plain, description wrapped into the remaining width
with continuation lines aligned under its start, cargo-style. `pad` is the visible column at
which descriptions start. -/
private def renderHelpEntry (color : Bool) (width pad : Nat) (entry : HelpEntry) : String :=
  let parts := entry.flags.splitOn " "
  let flag := parts.headD ""
  let metavars :=
    match parts with
    | [_] => ""
    | _ :: metas => " " ++ String.intercalate " " metas
    | [] => ""
  let left := "  " ++ paintLiteral color flag ++ paintMeta color metavars
  let leftLen := 2 + entry.flags.length
  let descWidth := max 30 (width - pad)
  let lines := wrapHelp descWidth entry.desc
  let rows :=
    lines.mapIdx fun i line =>
      if i == 0 then left ++ ("".pushn ' ' (pad - leftLen)) ++ line else ("".pushn ' ' pad) ++ line
  String.intercalate "\n" rows

private def renderHelpSection (color : Bool) (width : Nat) (title : String)
    (entries : Array HelpEntry) : String :=
  let natural := entries.foldl (fun m e => max m (2 + e.flags.length + 2)) 0
  let pad := min natural 30
  let body := entries.map (renderHelpEntry color width pad)
  paintHeader color title ++ "\n" ++ String.intercalate "\n" body.toList

/-- The `usage:` block: the binary literal, the rest metavariable, continuation lines aligned. -/
private def renderUsageBlock (color : Bool) (lines : Array String) : String :=
  String.intercalate "\n"
    (lines.mapIdx fun i line =>
        let styled :=
          if line.startsWith "lean-fmt " then
            paintLiteral color "lean-fmt" ++ paintMeta color (line.drop "lean-fmt".length).toString
          else paintMeta color line.trimAsciiStart.toString
        (if i == 0 then paintHeader color "usage:" ++ " " else "       ") ++ styled).toList

/-- The foot of a help text: each note a wrapped paragraph, indented two. -/
private def renderNotesBlock (color : Bool) (width : Nat) (notes : Array String) : String :=
  if notes.isEmpty then ""
  else
    let body :=
      notes.map fun note => String.intercalate "\n" ((wrapHelp (width - 2) note).map ("  " ++ ·))
    "\n\n" ++ paintHeader color "notes:" ++ "\n" ++ String.intercalate "\n" body.toList

/-! ## The option vocabulary

Each flag's text has exactly one home here; a command's sections name the constants its parser
honors. A flag that changes meaning per command (`--check`, `--unsafe-fixes`) gets one constant
per meaning, so no description lies about the command it sits under. -/

private def optRoot : HelpEntry :=
  ⟨"--root PATH", "Lake project root (default: .)"⟩

private def optConfig : HelpEntry :=
  ⟨"--config PATH", "explicit lean-fmt.toml"⟩

private def optChanged : HelpEntry :=
  ⟨"--changed", "select only files differing from HEAD, plus untracked"⟩

private def optChangedSince : HelpEntry :=
  ⟨"--changed-since REV", "select only files this branch changed since REV"⟩

private def optStaged : HelpEntry :=
  ⟨"--staged", "select only files staged for commit"⟩

private def optSelect : HelpEntry :=
  ⟨"--select SELECTOR", "set the active rules: a code/category/all (repeatable)"⟩

private def optExtendSelect : HelpEntry :=
  ⟨"--extend-select SEL", "add to the active rules without replacing (repeatable)"⟩

private def optIgnore : HelpEntry :=
  ⟨"--ignore SELECTOR", "deactivate a rule/category/all (repeatable)"⟩

private def optPreview : HelpEntry :=
  ⟨"--preview", "unlock preview (experimental) rules"⟩

private def optFixable : HelpEntry :=
  ⟨"--fixable SELECTOR", "restrict which rules' fixes apply (repeatable)"⟩

private def optUnfixable : HelpEntry :=
  ⟨"--unfixable SELECTOR", "withhold a rule's fix (repeatable)"⟩

private def optExtendFixable : HelpEntry :=
  ⟨"--extend-fixable SEL", "add to the fixable set without replacing (repeatable)"⟩

private def optUnsafeFixes : HelpEntry :=
  ⟨"--unsafe-fixes", "apply unsafe fixes too (default: safe only)"⟩

private def optUnsafeFixesPreview : HelpEntry :=
  ⟨"--unsafe-fixes", "preview unsafe fixes too (default: safe only)"⟩

private def optJson : HelpEntry :=
  ⟨"--json", "deterministic JSON output"⟩

private def optJsonAlias : HelpEntry :=
  ⟨"--json", "deterministic JSON output (alias for --output-format json)"⟩

private def optOutputFormat : HelpEntry :=
  ⟨"--output-format FMT", "text|concise|json|github|sarif|junit (default: text)"⟩

private def optOutputFormatDiff : HelpEntry :=
  ⟨"--output-format FMT",
    "text|json (default: text); concise/github/sarif/junit describe findings, and a patch carries none"⟩

private def optOutputFile : HelpEntry :=
  ⟨"--output-file PATH", "write the report to PATH atomically instead of stdout"⟩

private def optStatistics : HelpEntry :=
  ⟨"--statistics", "write aggregate statistics to stderr"⟩

private def optNoCache : HelpEntry :=
  ⟨"--no-cache", "neither read nor write result cache entries"⟩

private def optWorkers : HelpEntry :=
  ⟨"--workers N",
    "run up to N frontend children in parallel (default: LEAN_NUM_THREADS, else the machine's core count); the report is byte-identical at any N"⟩

private def optWatch : HelpEntry :=
  ⟨"--watch",
    "re-run on every change until interrupted (previews only); json/sarif/junit require --output-file under --watch"⟩

private def optPollInterval : HelpEntry :=
  ⟨"--poll-interval MS", "how often --watch looks for changes (default: 200)"⟩

private def optStdinFilename : HelpEntry :=
  ⟨"--stdin-filename P", "required with `-`: the buffer's identity for config/module resolution"⟩

private def optRange : HelpEntry :=
  ⟨"--range START:STOP", "format only this half-open normalized byte range"⟩

private def optRangeLines : HelpEntry :=
  ⟨"--range-lines R", "format only L:C-L:C (1-based line, 1-based codepoint column)"⟩

private def optCheckFormat : HelpEntry :=
  ⟨"--check", "report what would change, write nothing (CI preview)"⟩

private def optCheckOrganize : HelpEntry :=
  ⟨"--check", "report what would be reorganized, write nothing"⟩

private def optCheckDocs : HelpEntry :=
  ⟨"--check", "verify the committed docs match the registry, write nothing"⟩

private def optDebounceMs : HelpEntry :=
  ⟨"--debounce-ms MS", "how long an edit may settle before diagnostics re-run (milliseconds)"⟩

/-! ## Section assembly -/

private def targetSection : String × Array HelpEntry :=
  ("target options:", #[optRoot, optConfig, optChanged, optChangedSince, optStaged])

private def ruleSelectionSection : String × Array HelpEntry :=
  ("rule selection:", #[optSelect, optExtendSelect, optIgnore, optPreview])

private def fixSelectionSection (unsafeFixes : HelpEntry) : String × Array HelpEntry :=
  ("fix selection:", #[optFixable, optUnfixable, optExtendFixable, unsafeFixes])

private def outputSection (format : HelpEntry) : String × Array HelpEntry :=
  ("output options:", #[optJsonAlias, format, optOutputFile, optStatistics])

private def executionSection (watchable : Bool) : String × Array HelpEntry :=
  ("execution options:",
    #[optNoCache, optWorkers] ++ (if watchable then #[optWatch, optPollInterval] else #[]))

private def stdinSection (ranged : Bool) : String × Array HelpEntry :=
  ("stdin options (target `-`; never writes a file or a cache entry):",
    #[optStdinFilename] ++ (if ranged then #[optRange, optRangeLines] else #[]))

/-! ## The command table -/

private def commandHelps : Array CommandHelp :=
  #[{
      command := "check"
      summary := "report rule findings; write nothing"
      description :=
        "Report the selected rules' findings for each file, and nothing else: a \
      badly-laid-out but lint-clean file is clean — layout is `format`'s product, not a finding. \
      Never writes. Exit 0 clean, 1 findings or files that failed to analyze, 2 infrastructure \
      failure."
      usage := #["lean-fmt check [OPTIONS] [FILE...]", "lean-fmt check - --stdin-filename PATH"]
      sections :=
        #[targetSection, ruleSelectionSection, fixSelectionSection optUnsafeFixesPreview,
          outputSection optOutputFormat, executionSection true, stdinSection false]
      notes :=
        #["`check` previews the fixes `fix` would apply; the fix-selection flags shape that preview."] },
    {
      command := "format"
      summary := "format files to the canonical layout"
      description :=
        "Render each file's canonical layout and publish it in place, atomically. \
      `--check` renders but writes nothing and reports would-format/clean — the CI preview. With \
      the `-` target the one source comes from stdin and the formatted text goes to stdout. Exit \
      0 clean (or published), 1 differences under `--check` or files that failed to analyze, 2 \
      infrastructure failure."
      usage :=
        #["lean-fmt format [OPTIONS] [FILE...]",
          "lean-fmt format - --stdin-filename PATH [--range S:E | --range-lines L:C-L:C]"]
      sections :=
        #[targetSection, ruleSelectionSection, ("format options:", #[optCheckFormat]),
          outputSection optOutputFormat, executionSection true, stdinSection true]
      notes :=
        #["`--range`/`--range-lines` are valid only with the `-` stdin target.",
          "format publishes only layout — no rule fix applies — so `--unsafe-fixes` changes only the \
        reported withheld count, never the bytes.",
          "`--watch` requires `--check`: a writing mode retriggers itself."] },
    {
      command := "diff"
      summary := "preview formatting changes as a patch"
      description :=
        "Print the patch `format` would publish, file by file. Never writes. Exit 0 no \
      differences, 1 differences or files that failed to analyze, 2 infrastructure failure."
      usage := #["lean-fmt diff [OPTIONS] [FILE...]", "lean-fmt diff - --stdin-filename PATH"]
      sections :=
        #[targetSection, ruleSelectionSection, outputSection optOutputFormatDiff,
          executionSection true, stdinSection false]
      notes :=
        #["no rule fix applies to a patch, so `--unsafe-fixes` changes only the reported withheld count."] },
    {
      command := "fix"
      summary := "apply rule fixes in place"
      description :=
        "Apply the admitted rules' fixes in place, atomically, at each file's original \
      coordinates — like `ruff check --fix`. A fixed file keeps its layout until `format` runs, so \
      run `fix` then `format` for both. Safe fixes only unless `--unsafe-fixes`. Exit 0 clean (or \
      applied), 1 files that failed to analyze or fixes rejected, 2 infrastructure failure."
      usage := #["lean-fmt fix [OPTIONS] [FILE...]", "lean-fmt fix - --stdin-filename PATH"]
      sections :=
        #[targetSection, ruleSelectionSection, fixSelectionSection optUnsafeFixes,
          outputSection optOutputFormat, executionSection false, stdinSection false]
      notes :=
        #["`--watch` is unavailable: a writing mode retriggers itself.",
          "`--check` is a `format` flag; `fix` ignores it."] },
    {
      command := "lsp"
      summary := "serve the language server on stdio"
      description :=
        "Speak LSP on stdio — document formatting, range formatting, code actions, and \
      diagnostics — alongside Lean's own server. Editor setup: docs/editor-setup.md."
      usage :=
        #["lean-fmt lsp [--root PATH] [--config PATH] [--select SELECTOR]",
          "             [--ignore SELECTOR] [--preview] [--unsafe-fixes]",
          "             [--debounce-ms MS]"]
      sections :=
        #[("server options:",
            #[optRoot, optConfig, optSelect, optIgnore, optPreview, optUnsafeFixes,
              optDebounceMs])] },
    {
      command := "organize"
      summary := "canonicalize import headers"
      description :=
        "Rewrite each file's import header into the canonical form, validate every \
      changed file through the frontend, and publish it atomically — unchanged files skip the \
      frontend, and a candidate whose validation verdict is already cached skips it too. Exit 0 \
      clean, 1 would-change under `--check` or rejected rewrites, 2 infrastructure failure."
      usage :=
        #["lean-fmt organize [--root PATH] [--config PATH] [--check] [--json] [--workers N] \
      [--no-cache] [FILE...]"]
      sections :=
        #[("target options:", #[optRoot, optConfig]),
          ("organize options:", #[optCheckOrganize, optJson]),
          ("execution options:", #[optWorkers, optNoCache])] },
    {
      command := "rules"
      summary := "list the rule registry"
      description :=
        "Print every rule in the registry, one row each: code, category, lifecycle, \
      fixable, default-enabled, summary. `--json` prints the array instead. Exit 0."
      usage := #["lean-fmt rules [--json]"]
      sections := #[("output options:", #[optJson])] },
    {
      command := "explain"
      summary := "describe one rule"
      description :=
        "Print one rule's full description. A retired code prints its disposition; a \
      meta self-diagnostic (FMT900, FMT901) prints its description — all three are answers, so \
      all exit 0. Only a token the product could never have emitted exits 2."
      usage := #["lean-fmt explain RULE [--json]"]
      sections := #[("output options:", #[optJson])] },
    {
      command := "docs"
      summary := "regenerate the rule documentation"
      description :=
        "Write docs/rules/{index,FMT###}.md fresh from the rule registry. `--check` \
      instead verifies the committed tree matches — the drift gate that keeps every rule \
      documented. Exit 0 in sync, 1 drifted, 2 failure."
      usage := #["lean-fmt docs [--root PATH] [--check]"]
      sections := #[("target options:", #[optRoot]), ("docs options:", #[optCheckDocs])] },
    {
      command := "clean"
      summary := "remove the result cache"
      description :=
        "Remove .lean-fmt-cache/ under the root. Exit 0 whether or not it existed, 2 \
      failure."
      usage := #["lean-fmt clean [--root PATH] [--json]"]
      sections := #[("target options:", #[optRoot]), ("output options:", #[optJson])] },
    {
      command := "compiler"
      summary := "audit and build the compiler plugin's artifact"
      description :=
        "Install and build the compiler plugin's per-module syntax artifact. The \
      plugin is optional: without it a syntax-tier rule runs the exact frontend and reports the \
      same finding; with it, that work is reused from the build."
      usage := #["lean-fmt compiler setup [--json]", "lean-fmt compiler build [--root PATH]"]
      sections :=
        #[("subcommands:",
            #[⟨"setup", "print the plugin's installation guidance for this toolchain"⟩,
              ⟨"build", "extract every workspace module's artifact in one Lake invocation"⟩]),
          ("compiler options:", #[optRoot, optJson])]
      notes := #["`build` prints Lake's own progress, so `--json` does not apply to it."] },
    {
      command := "config"
      summary := "inspect the effective configuration for a file"
      description :=
        "`config show PATH` prints the settings in force for one file and where each \
      came from. The config file closest to the source governs it — closest wins, and configs do \
      not merge. Exit 0, or 2 when no file is given."
      usage := #["lean-fmt config show PATH [--root PATH] [--config PATH] [--json]"]
      sections := #[("target options:", #[optRoot, optConfig]), ("output options:", #[optJson])] }]

/-! ## Rendering -/

private def renderCommandHelp (spec : CommandHelp) (color : Bool) (width : Nat) : String :=
  renderUsageBlock color spec.usage ++ "\n\n" ++
          String.intercalate "\n" (wrapHelp width spec.description) ++
        "\n\n" ++
      String.intercalate "\n\n"
        ((spec.sections.map fun (title, entries) =>
            renderHelpSection color width title entries).toList) ++
    renderNotesBlock color width spec.notes

/-- The root `--help`: what the product is, the commands table (generated from `commandHelps`, so
a command cannot be documented in one place and missing from the other), and the global notes. -/
def overviewHelp (color : Bool) (width : Nat) : String :=
  renderUsageBlock color
                  #["lean-fmt <command> [OPTIONS] [FILE...]",
                    "lean-fmt {check|format|diff|fix} - --stdin-filename PATH [--range S:E]"] ++
                "\n\n" ++
              String.intercalate "\n"
                (wrapHelp width
                  "Format, lint, and fix Lean 4 source. Batch runs cache results in .lean-fmt-cache/; a warm \
      run where nothing changed skips the frontend.") ++
            "\n\n" ++
          renderHelpSection color width "commands:"
            (commandHelps.map fun spec => ⟨spec.command, spec.summary⟩) ++
        "\n\n" ++
      "Run `lean-fmt <command> --help` for that command's options, `lean-fmt --version` for the \
    version." ++
    renderNotesBlock color width
      #["exit 0 clean, 1 findings or drift, 2 failure.",
        "color follows the terminal: NO_COLOR or TERM=dumb disables it, and COLUMNS sets the wrap width."]

/-- One command's help renderer, when the token names a known command. -/
def commandHelp? (command : String) : Option (Bool → Nat → String) :=
  (commandHelps.find? (·.command == command)).map fun spec => renderCommandHelp spec

end LeanFmt.Internal.CliHelp
