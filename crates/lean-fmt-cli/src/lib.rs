//! `lean-fmt` command-line surface and dispatch.
//!
//! This crate is the Lean-free parent: it parses arguments, discovers the Lake
//! workspace and config, and produces a [`Report`] describing what each mode would do.
//! Actual formatting/linting behavior is added in later prompts; today the modes report
//! the resolved file set and an honest "no rules implemented yet" note.

mod install_worker;
mod serve;

use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand, ValueEnum};
use serde::Serialize;
use thiserror::Error;

use lean_fmt_diagnostics::{RuleInfo, RuleSelection, registry};
use lean_fmt_project::{
    AnalysisOutcome, CacheKeyBuilder, FileReport, FormatCache, FormatterConfig, ProjectRun, RunMode, RunSummary,
    SourceFile, ValidationLevel, run_project,
};
use lean_fmt_worker::FormatterWorker;
use lean_fmt_worker::toolchain::resolve_installed_worker;

/// Top-level CLI parser.
#[derive(Debug, Parser)]
#[command(name = "lean-fmt", version, about, long_about = None)]
pub struct Cli {
    /// The formatter subcommand to run.
    #[command(subcommand)]
    pub command: CliCommand,
}

/// Output rendering format.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum OutputFormat {
    /// Human-readable text.
    Text,
    /// Machine-readable JSON.
    Json,
}

/// Options shared by the file-processing modes.
#[derive(Debug, Clone, clap::Args)]
pub struct CommonArgs {
    /// Explicit `.lean` files to process. When given, workspace discovery is skipped.
    #[arg(value_name = "FILE")]
    pub paths: Vec<PathBuf>,

    /// The Lake project root to discover (ignored when explicit files are given).
    #[arg(long, default_value = ".", value_name = "DIR")]
    pub root: PathBuf,

    /// Restrict discovery to a single module root.
    #[arg(long, value_name = "MODULE")]
    pub module_root: Option<String>,

    /// Explicit config file path (defaults to `lean-fmt.toml` at the root).
    #[arg(long, value_name = "FILE")]
    pub config: Option<PathBuf>,

    /// Output format.
    #[arg(long, value_enum, default_value_t = OutputFormat::Text)]
    pub format: OutputFormat,

    /// Activate a rule, category, or `all` (repeatable). Overrides config selection.
    #[arg(long, value_name = "SELECTOR")]
    pub select: Vec<String>,

    /// Deactivate a rule, category, or `all` (repeatable). Beats a matching `--select`.
    #[arg(long, value_name = "SELECTOR")]
    pub ignore: Vec<String>,

    /// Ignore the incremental result cache: never reuse a cached result and never write
    /// one. Every file is analyzed from scratch. The cache is otherwise keyed by semantic
    /// inputs (config, toolchain, source, imports, runtime digest, validation mode), so it
    /// is already sound; this is a diagnostic escape hatch.
    #[arg(long)]
    pub no_cache: bool,

    /// Print run statistics (per-mode counts, cache hits, files written) to stderr after
    /// the report. Kept off stdout so a `--format json` run stays a single clean object.
    #[arg(long)]
    pub statistics: bool,
}

/// Options for `lean-fmt fix`: the shared file options plus write-validation control.
///
/// The validation flags govern the safe-apply gate ([`lean_fmt_project::safe_apply`]) the
/// write path routes through: after edits are patched in memory, the edited text is re-parsed
/// and the file is written only if it still parses. The flags resolve to a
/// [`ValidationLevel`] via [`validation_level`]; the disk write itself is wired in
/// `LFMT-PROJECT-MODES`.
#[derive(Debug, Clone, clap::Args)]
pub struct FixArgs {
    /// The shared file-processing options.
    #[command(flatten)]
    pub common: CommonArgs,

    /// Re-parse each edited file and refuse to write it if it no longer parses. On by
    /// default; pass explicitly to be unambiguous. Conflicts with the other level flags.
    #[arg(long, conflicts_with_all = ["unsafe_no_validate", "check_elab"])]
    pub check_syntax: bool,

    /// Re-parse *and elaborate* each edited file, refusing to write it unless elaboration
    /// also succeeds (stricter and slower than the default syntax check). Opt-in.
    #[arg(long, conflicts_with_all = ["unsafe_no_validate", "check_syntax"])]
    pub check_elab: bool,

    /// Skip the re-check gate before writing (developer escape hatch). The patch conflict
    /// check still runs; only the re-parse/elaborate step is bypassed.
    #[arg(long)]
    pub unsafe_no_validate: bool,
}

/// The formatter subcommands.
#[derive(Debug, Subcommand)]
pub enum CliCommand {
    /// Report formatting/lint findings without modifying files.
    Check(CommonArgs),
    /// Format files, reporting what would change.
    Format(CommonArgs),
    /// Apply safe fixes to files.
    Fix(FixArgs),
    /// Show the diff formatting would produce.
    Diff(CommonArgs),
    /// List the available rules.
    Rules {
        /// Output format.
        #[arg(long, value_enum, default_value_t = OutputFormat::Text)]
        format: OutputFormat,
    },
    /// Build and install the Lean-linked worker for a toolchain (needed before any
    /// mode that parses Lean; the CLI itself stays Lean-free).
    InstallWorker(InstallWorkerArgs),
    /// Run a long-lived format server for editor integration (stdio, line-delimited JSON).
    Serve(ServeArgs),
}

/// Options for `lean-fmt serve`.
#[derive(Debug, Clone, clap::Args)]
pub struct ServeArgs {
    /// The Lake project root to serve (determines the worker, cache, and import search path).
    #[arg(long, default_value = ".", value_name = "DIR")]
    pub root: PathBuf,

    /// Restrict discovery to a single module root.
    #[arg(long, value_name = "MODULE")]
    pub module_root: Option<String>,

    /// Explicit config file path (defaults to `lean-fmt.toml` at the root).
    #[arg(long, value_name = "FILE")]
    pub config: Option<PathBuf>,

    /// Activate a rule, category, or `all` (repeatable). Overrides config selection.
    #[arg(long, value_name = "SELECTOR")]
    pub select: Vec<String>,

    /// Deactivate a rule, category, or `all` (repeatable). Beats a matching `--select`.
    #[arg(long, value_name = "SELECTOR")]
    pub ignore: Vec<String>,

    /// Re-parse *and elaborate* each edited file before returning formatted text (stricter and
    /// slower than the default syntax-only safe-write gate).
    #[arg(long)]
    pub check_elab: bool,

    /// Ignore the incremental result cache: never reuse or write a cached result.
    #[arg(long)]
    pub no_cache: bool,
}

/// Options for `lean-fmt install-worker`.
#[derive(Debug, Clone, clap::Args)]
pub struct InstallWorkerArgs {
    /// Toolchain to build for (`leanprover/lean4:v4.32.0-rc1` or the bare `v4.32.0-rc1`).
    /// Defaults to the current directory's `lean-toolchain`, else the pinned default.
    #[arg(long, value_name = "TOOLCHAIN")]
    pub toolchain: Option<String>,

    /// Explicit Lean sysroot to build and link against. Defaults to the elan directory
    /// for the resolved toolchain.
    #[arg(long, value_name = "DIR")]
    pub sysroot: Option<PathBuf>,

    /// Install directly into this directory instead of the per-toolchain path under the
    /// user data dir (dev/CI redirect; also honored via `LEAN_FMT_WORKERS_DIR`).
    #[arg(long, value_name = "DIR")]
    pub install_dir: Option<PathBuf>,

    /// Use this prebuilt `lean-fmt-worker-child` binary instead of building one with cargo.
    #[arg(long, value_name = "FILE")]
    pub worker_child: Option<PathBuf>,

    /// Checkout to build `lean-fmt-worker-child` from when `--worker-child` is not given.
    #[arg(long, value_name = "DIR")]
    pub source_dir: Option<PathBuf>,

    /// Rebuild even if a current, smoke-passing install already exists.
    #[arg(long)]
    pub force: bool,
}

impl CliCommand {
    /// The stable lowercase name of this mode.
    #[must_use]
    pub fn mode(&self) -> &'static str {
        match self {
            Self::Check(_) => "check",
            Self::Format(_) => "format",
            Self::Fix(_) => "fix",
            Self::Diff(_) => "diff",
            Self::Rules { .. } => "rules",
            Self::InstallWorker(_) => "install-worker",
            Self::Serve(_) => "serve",
        }
    }
}

/// Errors surfaced by the CLI.
#[derive(Debug, Error)]
pub enum Error {
    /// A project discovery or config error.
    #[error(transparent)]
    Project(#[from] lean_fmt_project::Error),

    /// A JSON rendering error.
    #[error("could not render JSON output: {0}")]
    Json(#[from] serde_json::Error),

    /// No usable Lean-linked worker could be resolved for the workspace's toolchain.
    #[error("{0}")]
    Worker(String),

    /// `install-worker` is effectful and is dispatched directly by [`run`], not planned.
    #[error("install-worker does not produce a report; it is dispatched directly")]
    NotReportable,
}

/// Convenience alias for CLI results.
pub type Result<T> = std::result::Result<T, Error>;

/// A description of what a mode resolved and would do. Rendered as text or JSON.
#[derive(Debug, Serialize)]
pub struct Report {
    /// The mode that produced this report.
    pub mode: &'static str,
    /// The resolved Lake root, when discovery ran.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root: Option<PathBuf>,
    /// The source files selected for processing.
    pub files: Vec<SourceFile>,
    /// A human-readable note about mode status.
    pub note: String,
}

/// Build the report for a parsed command without performing any file mutation.
///
/// # Errors
/// Returns an error if workspace discovery, config loading, or file resolution fails.
/// Returns [`Error::NotReportable`] for `rules` and `install-worker`, which are
/// dispatched through their own paths ([`plan_rules`] and [`install_worker`]).
pub fn plan(command: &CliCommand) -> Result<Report> {
    match command {
        CliCommand::Check(args) | CliCommand::Format(args) | CliCommand::Diff(args) => plan_files(command.mode(), args),
        CliCommand::Fix(args) => plan_files(command.mode(), &args.common),
        CliCommand::Rules { .. } | CliCommand::InstallWorker(_) | CliCommand::Serve(_) => Err(Error::NotReportable),
    }
}

/// Resolve the write-validation level for a `fix` invocation.
///
/// `--unsafe-no-validate` disables the re-check gate (but never the patch conflict check,
/// which [`lean_fmt_project::safe_apply`] always runs); `--check-elab` selects the stricter
/// parse-and-elaborate level; otherwise the default [`ValidationLevel::Syntax`] applies.
/// `--check-syntax` is the explicit affirmation of that default. The three level flags are
/// mutually exclusive, and clap rejects passing more than one together.
#[must_use]
pub fn validation_level(args: &FixArgs) -> ValidationLevel {
    if args.unsafe_no_validate {
        ValidationLevel::None
    } else if args.check_elab {
        ValidationLevel::Elab
    } else {
        ValidationLevel::Syntax
    }
}

/// Build the incremental result cache for a file-processing command, honoring `--no-cache`.
///
/// Rooted at `cache_root`; `--no-cache` yields a [`FormatCache::disabled`] cache whose
/// lookups always miss and whose stores are no-ops, so the pipeline (wired in
/// `LFMT-PROJECT-MODES`) runs exactly as if no cache existed. The cache is otherwise sound
/// by construction — it is keyed on every semantic input — so this flag is a diagnostic
/// escape hatch, not a correctness control.
#[must_use]
pub fn cache_for(args: &CommonArgs, cache_root: PathBuf) -> FormatCache {
    if args.no_cache {
        FormatCache::disabled(cache_root)
    } else {
        FormatCache::new(cache_root)
    }
}

/// Resolve config for a file-processing command, honoring an explicit `--config`.
fn load_config(args: &CommonArgs) -> Result<FormatterConfig> {
    match &args.config {
        Some(path) => Ok(FormatterConfig::load_from(path)?),
        None => Ok(FormatterConfig::discover(&args.root)?),
    }
}

/// Build the rule selection from CLI flags (highest precedence) and config.
fn selection_for(args: &CommonArgs, config: &FormatterConfig) -> RuleSelection {
    RuleSelection::new(
        args.select.clone(),
        args.ignore.clone(),
        config.select.clone(),
        config.ignore.clone(),
        config.per_file_ignores.clone(),
    )
}

/// Resolve the files a file-processing command will operate on, plus the discovered Lake
/// root (when discovery ran). Explicit `paths` skip discovery and yield no root.
///
/// # Errors
/// Returns an error if workspace discovery or file resolution fails.
fn resolve_targets(args: &CommonArgs, config: &FormatterConfig) -> Result<(Option<PathBuf>, Vec<SourceFile>)> {
    if args.paths.is_empty() {
        let workspace = lean_fmt_project::resolve(&args.root, args.module_root.as_deref(), config)?;
        Ok((Some(workspace.root), workspace.source_files))
    } else {
        let files = lean_fmt_project::resolve_files(&args.paths)?;
        Ok((None, files))
    }
}

fn plan_files(mode: &'static str, args: &CommonArgs) -> Result<Report> {
    let config = load_config(args)?;
    let selection = selection_for(args, &config);
    // Project-level active rule count: per-file ignores keyed by real prefixes do not
    // apply to the empty path, so this is the baseline the selection would use.
    let active = selection.active_rule_ids("").len();
    let (root, files) = resolve_targets(args, &config)?;
    let note = mode_note(mode, files.len(), active);
    Ok(Report {
        mode,
        root,
        files,
        note,
    })
}

fn mode_note(mode: &str, count: usize, active_rules: usize) -> String {
    format!("resolved {count} file(s); {active_rules} rule(s) active; ready to {mode}")
}

/// A machine-readable listing of the rule registry, filtered by an optional selection.
#[derive(Debug, Serialize)]
pub struct RulesReport {
    /// Every registry rule with its metadata.
    pub rules: Vec<RuleInfo>,
}

/// Build the rule registry listing for `lean-fmt rules`.
#[must_use]
pub fn plan_rules() -> RulesReport {
    RulesReport {
        rules: registry().iter().map(RuleInfo::from).collect(),
    }
}

/// Render a rules listing as text or JSON.
///
/// # Errors
/// Returns [`Error::Json`] if JSON serialization fails.
pub fn render_rules(report: &RulesReport, format: OutputFormat) -> Result<String> {
    match format {
        OutputFormat::Json => Ok(serde_json::to_string_pretty(report)?),
        OutputFormat::Text => Ok(render_rules_text(report)),
    }
}

fn render_rules_text(report: &RulesReport) -> String {
    let mut lines = Vec::with_capacity(report.rules.len().strict_add(1));
    for rule in &report.rules {
        let state = if rule.default_enabled { "on" } else { "off" };
        lines.push(format!("{}\t[{state}]\t{}", rule.id, rule.summary));
    }
    lines.push(format!("{} rule(s)", report.rules.len()));
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

/// Render a report in the requested format.
///
/// # Errors
/// Returns [`Error::Json`] if JSON serialization fails.
pub fn render(report: &Report, format: OutputFormat) -> Result<String> {
    match format {
        OutputFormat::Json => Ok(serde_json::to_string_pretty(report)?),
        OutputFormat::Text => Ok(render_text(report)),
    }
}

fn render_text(report: &Report) -> String {
    let mut lines = Vec::with_capacity(report.files.len().strict_add(2));
    if let Some(root) = &report.root {
        lines.push(format!("root: {}", root.display()));
    }
    for file in &report.files {
        lines.push(format!("{}\t{}", file.module, file.path.display()));
    }
    lines.push(report.note.clone());
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

/// Programmatic `install-worker` entrypoint, returning the install directory.
///
/// Builds the capability, installs the worker child, writes provenance, and smoke-tests
/// the installed worker. Used by [`run`] and by integration tests that drive install
/// without argv.
///
/// # Errors
///
/// Returns a human-readable error string if toolchain resolution, the capability build,
/// worker-child placement, sidecar writing, or the smoke test fails.
pub fn install_worker_command(args: &InstallWorkerArgs) -> std::result::Result<PathBuf, String> {
    install_worker::install(args)
}

/// The output format selected by a command.
#[must_use]
pub fn command_format(command: &CliCommand) -> OutputFormat {
    match command {
        CliCommand::Check(args) | CliCommand::Format(args) | CliCommand::Diff(args) => args.format,
        CliCommand::Fix(args) => args.common.format,
        CliCommand::Rules { format } => *format,
        CliCommand::InstallWorker(_) | CliCommand::Serve(_) => OutputFormat::Text,
    }
}

/// The mode string and [`RunMode`] a file-processing command runs as. `format` reports what
/// would change like `check` (no writes); `diff` shows the diffs; `fix` writes.
fn run_mode(command: &CliCommand) -> Option<(&'static str, RunMode, &CommonArgs, ValidationLevel)> {
    match command {
        CliCommand::Check(args) => Some(("check", RunMode::Check, args, ValidationLevel::Syntax)),
        CliCommand::Format(args) => Some(("format", RunMode::Check, args, ValidationLevel::Syntax)),
        CliCommand::Diff(args) => Some(("diff", RunMode::Diff, args, ValidationLevel::Syntax)),
        CliCommand::Fix(args) => Some(("fix", RunMode::Fix, &args.common, validation_level(args))),
        CliCommand::Rules { .. } | CliCommand::InstallWorker(_) | CliCommand::Serve(_) => None,
    }
}

/// The per-project cache root: a hidden directory beside the workspace (like `.ruff_cache`).
fn cache_root_for(root: &Path) -> PathBuf {
    root.join(".lean-fmt-cache")
}

/// The import search path handed to the worker: the project's built module directory, when
/// it exists. Absent when the project is unbuilt (project-internal imports then Degrade to a
/// reported broken file rather than being silently formatted against a stale model).
fn project_search_path(root: &Path) -> Vec<PathBuf> {
    let lib = root.join(".lake").join("build").join("lib");
    if lib.is_dir() { vec![lib] } else { Vec::new() }
}

/// Resolve the workspace and worker, drive [`run_project`] across every file through one warm
/// session, print the report to stdout and statistics to stderr, and return the exit code.
///
/// # Errors
/// Returns an error if config/discovery fails, no usable worker is installed, or rendering
/// fails. A per-file failure is *not* an error here — it is reported and reflected in the
/// exit code, not propagated.
fn execute(mode_label: &'static str, mode: RunMode, args: &CommonArgs, level: ValidationLevel) -> Result<u8> {
    let config = load_config(args)?;
    let selection = selection_for(args, &config);
    let (root, files) = resolve_targets(args, &config)?;

    // One warm worker per workspace, resolved for the pinned toolchain.
    let worker_root = root.clone().unwrap_or_else(|| args.root.clone());
    let installed = resolve_installed_worker(&worker_root).map_err(|error| Error::Worker(error.to_string()))?;
    let mut worker = FormatterWorker::from_installed(&installed);

    let keys = CacheKeyBuilder::new(
        &config,
        env!("CARGO_PKG_VERSION"),
        installed.toolchain_label.as_str(),
        installed.runtime_source_digest.as_str(),
        level,
    );
    let cache = cache_for(args, cache_root_for(&worker_root));
    let search_path = project_search_path(&worker_root);

    // Progress goes to stderr so stdout carries only the report (clean JSON when requested).
    let run = run_project(
        &mut worker,
        mode,
        &files,
        &selection,
        &keys,
        level,
        &search_path,
        &cache,
        |message| eprintln!("{message}"),
    );

    print!("{}", render_run(&run, mode_label, root.as_deref(), args.format)?);
    if args.statistics {
        eprint!("{}", render_statistics(&run));
    }
    Ok(run.exit_code())
}

/// Parse arguments, dispatch the command, and return a process exit code.
#[must_use]
pub fn run() -> std::process::ExitCode {
    let cli = Cli::parse();
    // install-worker is effectful (builds + installs + smoke-tests); it is dispatched
    // directly rather than through the report path.
    if let CliCommand::InstallWorker(args) = &cli.command {
        return install_worker::run(args);
    }
    // serve is a long-lived loop, not a report; it is dispatched directly.
    if let CliCommand::Serve(args) = &cli.command {
        return match serve::serve(args) {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("lean-fmt: {error}");
                std::process::ExitCode::FAILURE
            }
        };
    }
    if let CliCommand::Rules { format } = &cli.command {
        return match render_rules(&plan_rules(), *format) {
            Ok(rendered) => {
                print!("{rendered}");
                std::process::ExitCode::SUCCESS
            }
            Err(error) => {
                eprintln!("lean-fmt: {error}");
                std::process::ExitCode::FAILURE
            }
        };
    }
    let Some((mode_label, mode, args, level)) = run_mode(&cli.command) else {
        eprintln!("lean-fmt: {}", Error::NotReportable);
        return std::process::ExitCode::FAILURE;
    };
    match execute(mode_label, mode, args, level) {
        Ok(code) => std::process::ExitCode::from(code),
        Err(error) => {
            eprintln!("lean-fmt: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

/// Render a [`ProjectRun`] as the stdout report — text, or a single clean JSON object.
///
/// # Errors
/// Returns [`Error::Json`] if JSON serialization fails.
pub fn render_run(run: &ProjectRun, mode_label: &str, root: Option<&Path>, format: OutputFormat) -> Result<String> {
    match format {
        OutputFormat::Json => render_run_json(run, mode_label, root),
        OutputFormat::Text => Ok(render_run_text(run, mode_label, root)),
    }
}

/// The path shown for a report: relative to the discovered root when possible, else as-is.
fn display_path(path: &str, root: Option<&Path>) -> String {
    if let Some(root) = root
        && let Ok(relative) = Path::new(path).strip_prefix(root)
    {
        return relative.display().to_string();
    }
    path.to_owned()
}

/// The stable per-file status word.
fn status_of(report: &FileReport) -> &'static str {
    match report {
        FileReport::Failed { .. } => "failed",
        FileReport::Analyzed { analysis, wrote } => match &analysis.outcome {
            AnalysisOutcome::Broken { .. } => "broken",
            AnalysisOutcome::Analyzed { formatted, .. } => {
                if formatted.is_none() {
                    "clean"
                } else if *wrote {
                    "reformatted"
                } else {
                    "would-reformat"
                }
            }
        },
    }
}

/// The number of findings on a report, if it was analyzed at all.
fn findings_of(report: &FileReport) -> Option<usize> {
    match report {
        FileReport::Failed { .. } => None,
        FileReport::Analyzed { analysis, .. } => match &analysis.outcome {
            AnalysisOutcome::Analyzed { diagnostics, .. } => Some(diagnostics.len()),
            AnalysisOutcome::Broken { diagnostics, .. } => Some(diagnostics.len()),
        },
    }
}

/// The unified diff for a report, if one was produced.
fn diff_of(report: &FileReport) -> Option<&str> {
    match report {
        FileReport::Failed { .. } => None,
        FileReport::Analyzed { analysis, .. } => match &analysis.outcome {
            AnalysisOutcome::Analyzed { diff, .. } => diff.as_deref(),
            AnalysisOutcome::Broken { .. } => None,
        },
    }
}

/// The failure message on a failed report.
fn message_of(report: &FileReport) -> Option<&str> {
    match report {
        FileReport::Failed { message, .. } => Some(message),
        FileReport::Analyzed { .. } => None,
    }
}

/// One JSON object per file in a run.
#[derive(Serialize)]
struct FileJson {
    path: String,
    status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    findings: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    diff: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

/// The JSON summary block.
#[derive(Serialize)]
struct SummaryJson {
    total: usize,
    clean: usize,
    changed: usize,
    broken: usize,
    failed: usize,
    from_cache: usize,
    wrote: usize,
}

impl From<RunSummary> for SummaryJson {
    fn from(summary: RunSummary) -> Self {
        Self {
            total: summary.total,
            clean: summary.clean,
            changed: summary.changed,
            broken: summary.broken,
            failed: summary.failed,
            from_cache: summary.from_cache,
            wrote: summary.wrote,
        }
    }
}

/// The whole-run JSON object printed to stdout in `--format json`.
#[derive(Serialize)]
struct RunJson {
    mode: String,
    files: Vec<FileJson>,
    summary: SummaryJson,
}

fn render_run_json(run: &ProjectRun, mode_label: &str, root: Option<&Path>) -> Result<String> {
    let files = run
        .reports
        .iter()
        .map(|report| FileJson {
            path: display_path(report.path(), root),
            status: status_of(report),
            findings: findings_of(report),
            diff: diff_of(report).map(ToOwned::to_owned),
            message: message_of(report).map(ToOwned::to_owned),
        })
        .collect();
    let json = RunJson {
        mode: mode_label.to_owned(),
        files,
        summary: SummaryJson::from(run.summary()),
    };
    Ok(serde_json::to_string_pretty(&json)?)
}

fn render_run_text(run: &ProjectRun, mode_label: &str, root: Option<&Path>) -> String {
    let mut lines = Vec::new();
    for report in &run.reports {
        let path = display_path(report.path(), root);
        let status = status_of(report);
        if mode_label == "diff" {
            match diff_of(report) {
                Some(diff) => lines.push(diff.to_owned()),
                None => {
                    if status != "clean" {
                        lines.push(format!("{path}: {status}"));
                    }
                }
            }
            continue;
        }
        match status {
            // Clean files are not listed in text mode; the summary counts them.
            "clean" => {}
            "failed" => lines.push(format!("{path}: {}", message_of(report).unwrap_or("failed"))),
            other => lines.push(format!("{path}: {other}")),
        }
    }
    lines.push(summary_line(mode_label, &run.summary()));
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

fn summary_line(mode_label: &str, summary: &RunSummary) -> String {
    format!(
        "{mode_label}: {} file(s); {} clean, {} to change, {} broken, {} failed",
        summary.total, summary.clean, summary.changed, summary.broken, summary.failed
    )
}

/// The `--statistics` block (stderr): the full per-mode counts including cache hits and writes.
fn render_statistics(run: &ProjectRun) -> String {
    let summary = run.summary();
    format!(
        "statistics: total={} clean={} changed={} broken={} failed={} from_cache={} wrote={}\n",
        summary.total,
        summary.clean,
        summary.changed,
        summary.broken,
        summary.failed,
        summary.from_cache,
        summary.wrote,
    )
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use std::fs;

    use tempfile::TempDir;

    use clap::Parser;

    use lean_fmt_project::ValidationLevel;

    use super::{
        Cli, CliCommand, CommonArgs, FixArgs, OutputFormat, plan, plan_rules, render, render_rules, validation_level,
    };

    fn common(root: &std::path::Path) -> CommonArgs {
        CommonArgs {
            paths: Vec::new(),
            root: root.to_path_buf(),
            module_root: None,
            config: None,
            format: OutputFormat::Text,
            select: Vec::new(),
            ignore: Vec::new(),
            no_cache: false,
            statistics: false,
        }
    }

    fn write(dir: &std::path::Path, rel: &str, contents: &str) {
        let path = dir.join(rel);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, contents).unwrap();
    }

    #[test]
    fn check_reports_discovered_files() {
        let temp = TempDir::new().unwrap();
        write(temp.path(), "lakefile.toml", "[[lean_lib]]\nname = \"Pkg\"\n");
        write(temp.path(), "Pkg/A.lean", "def a := 1\n");
        let report = plan(&CliCommand::Check(common(temp.path()))).unwrap();
        assert_eq!(report.mode, "check");
        assert_eq!(report.files.len(), 1);
        assert_eq!(report.files[0].module, "Pkg.A");
    }

    #[test]
    fn rules_mode_lists_the_registry() {
        let report = plan_rules();
        assert_eq!(report.rules.len(), lean_fmt_diagnostics::registry().len());
        // Every rule id is category-prefixed and appears in the text rendering.
        let text = render_rules(&report, OutputFormat::Text).unwrap();
        assert!(text.contains("imports/sorted"));
        assert!(text.contains("performance/large-file\t[off]"));
        // JSON is machine-readable and lists the same count.
        let json = render_rules(&report, OutputFormat::Json).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            parsed["rules"].as_array().unwrap().len(),
            lean_fmt_diagnostics::registry().len()
        );
    }

    #[test]
    fn selection_flags_change_active_rule_count() {
        let temp = TempDir::new().unwrap();
        write(temp.path(), "lakefile.toml", "[[lean_lib]]\nname = \"Pkg\"\n");
        write(temp.path(), "Pkg/A.lean", "def a := 1\n");

        let baseline = plan(&CliCommand::Check(common(temp.path()))).unwrap();

        let mut args = common(temp.path());
        args.ignore = vec!["all".to_owned()];
        let none_active = plan(&CliCommand::Check(args)).unwrap();

        assert!(baseline.note.contains("rule(s) active"));
        assert!(none_active.note.contains("0 rule(s) active"));
        assert_ne!(baseline.note, none_active.note);
    }

    #[test]
    fn json_render_is_valid_json() {
        let temp = TempDir::new().unwrap();
        write(temp.path(), "lakefile.toml", "[[lean_lib]]\nname = \"Pkg\"\n");
        write(temp.path(), "Pkg/A.lean", "def a := 1\n");
        let report = plan(&CliCommand::Format(common(temp.path()))).unwrap();
        let json = render(&report, OutputFormat::Json).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["mode"], "format");
        assert_eq!(parsed["files"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn non_lake_root_errors() {
        let temp = TempDir::new().unwrap();
        write(temp.path(), "notes.txt", "x\n");
        assert!(plan(&CliCommand::Check(common(temp.path()))).is_err());
    }

    #[test]
    fn fix_mode_plans_like_the_other_file_modes() {
        let temp = TempDir::new().unwrap();
        write(temp.path(), "lakefile.toml", "[[lean_lib]]\nname = \"Pkg\"\n");
        write(temp.path(), "Pkg/A.lean", "def a := 1\n");
        let args = FixArgs {
            common: common(temp.path()),
            check_syntax: false,
            check_elab: false,
            unsafe_no_validate: false,
        };
        let report = plan(&CliCommand::Fix(args)).unwrap();
        assert_eq!(report.mode, "fix");
        assert_eq!(report.files.len(), 1);
    }

    fn fix_level(argv: &[&str]) -> ValidationLevel {
        let cli = Cli::try_parse_from(argv).unwrap();
        let CliCommand::Fix(args) = &cli.command else {
            panic!("expected fix");
        };
        validation_level(args)
    }

    #[test]
    fn validation_defaults_to_syntax_and_flags_select_the_level() {
        assert_eq!(fix_level(&["lean-fmt", "fix", "Pkg/A.lean"]), ValidationLevel::Syntax);
        assert_eq!(
            fix_level(&["lean-fmt", "fix", "--check-syntax", "Pkg/A.lean"]),
            ValidationLevel::Syntax
        );
        assert_eq!(
            fix_level(&["lean-fmt", "fix", "--check-elab", "Pkg/A.lean"]),
            ValidationLevel::Elab
        );
        assert_eq!(
            fix_level(&["lean-fmt", "fix", "--unsafe-no-validate", "Pkg/A.lean"]),
            ValidationLevel::None
        );
    }

    #[test]
    fn no_cache_flag_disables_the_cache() {
        use super::cache_for;
        let temp = TempDir::new().unwrap();
        let cache_root = temp.path().join("cache");

        // Default: caching is enabled.
        let cli = Cli::try_parse_from(["lean-fmt", "check", "Pkg/A.lean"]).unwrap();
        let CliCommand::Check(args) = &cli.command else {
            panic!("expected check");
        };
        assert!(!args.no_cache);
        assert!(cache_for(args, cache_root.clone()).is_enabled());

        // `--no-cache` disables it.
        let cli = Cli::try_parse_from(["lean-fmt", "check", "--no-cache", "Pkg/A.lean"]).unwrap();
        let CliCommand::Check(args) = &cli.command else {
            panic!("expected check");
        };
        assert!(args.no_cache);
        assert!(!cache_for(args, cache_root).is_enabled());
    }

    fn mixed_reports() -> Vec<lean_fmt_project::FileReport> {
        use lean_fmt_project::{AnalysisOutcome, FileAnalysis, FileReport};
        use lean_fmt_worker::ParseStatus;
        vec![
            FileReport::Analyzed {
                analysis: FileAnalysis {
                    path: "/w/A.lean".to_owned(),
                    outcome: AnalysisOutcome::Analyzed {
                        diagnostics: Vec::new(),
                        formatted: None,
                        diff: None,
                    },
                    from_cache: false,
                },
                wrote: false,
            },
            FileReport::Analyzed {
                analysis: FileAnalysis {
                    path: "/w/B.lean".to_owned(),
                    outcome: AnalysisOutcome::Analyzed {
                        diagnostics: Vec::new(),
                        formatted: Some("def b := 1\n".to_owned()),
                        diff: Some("--- a/B.lean\n+++ b/B.lean\n".to_owned()),
                    },
                    from_cache: false,
                },
                wrote: false,
            },
            FileReport::Analyzed {
                analysis: FileAnalysis {
                    path: "/w/C.lean".to_owned(),
                    outcome: AnalysisOutcome::Broken {
                        status: ParseStatus::Error,
                        diagnostics: Vec::new(),
                    },
                    from_cache: false,
                },
                wrote: false,
            },
            FileReport::Failed {
                path: "/w/D.lean".to_owned(),
                message: "could not read file".to_owned(),
            },
        ]
    }

    #[test]
    fn render_run_json_is_a_single_clean_object() {
        use lean_fmt_project::{ProjectRun, RunMode};
        use std::path::Path;

        let run = ProjectRun {
            mode: RunMode::Check,
            reports: mixed_reports(),
        };
        let json = super::render_run(&run, "check", Some(Path::new("/w")), OutputFormat::Json).unwrap();

        // Stdout is a single JSON object — no leaked progress text.
        assert!(json.trim_start().starts_with('{'), "stdout JSON starts clean: {json}");
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["mode"], "check");
        let files = parsed["files"].as_array().unwrap();
        assert_eq!(files.len(), 4);
        // Paths are relativized against the root.
        assert_eq!(files[0]["path"], "A.lean");
        assert_eq!(files[0]["status"], "clean");
        assert_eq!(files[1]["status"], "would-reformat");
        assert_eq!(files[2]["status"], "broken");
        assert_eq!(files[3]["status"], "failed");
        assert_eq!(parsed["summary"]["total"], 4);
        assert_eq!(parsed["summary"]["broken"], 1);
        assert_eq!(parsed["summary"]["failed"], 1);
        assert_eq!(parsed["summary"]["changed"], 1);
        // A per-file failure makes the run a nonzero (error) exit.
        assert_eq!(run.exit_code(), 2);
    }

    #[test]
    fn diff_mode_text_prints_the_diff_and_summary() {
        use lean_fmt_project::{ProjectRun, RunMode};
        use std::path::Path;

        let run = ProjectRun {
            mode: RunMode::Diff,
            reports: mixed_reports(),
        };
        let text = super::render_run(&run, "diff", Some(Path::new("/w")), OutputFormat::Text).unwrap();
        assert!(text.contains("--- a/B.lean"), "the diff is printed: {text}");
        assert!(text.contains("C.lean: broken"), "a broken file is noted");
        assert!(
            text.contains("diff: 4 file(s); 1 clean, 1 to change, 1 broken, 1 failed"),
            "the summary line is present: {text}"
        );
    }

    #[test]
    fn level_flags_are_mutually_exclusive() {
        for pair in [
            ["--check-syntax", "--unsafe-no-validate"],
            ["--check-elab", "--unsafe-no-validate"],
            ["--check-syntax", "--check-elab"],
        ] {
            let result = Cli::try_parse_from(["lean-fmt", "fix", pair[0], pair[1], "Pkg/A.lean"]);
            assert!(result.is_err(), "clap must reject {pair:?} together");
        }
    }
}
