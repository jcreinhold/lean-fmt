//! `lean-fmt` command-line surface and dispatch.
//!
//! This crate is the Lean-free parent: it parses arguments, discovers the Lake
//! workspace and config, and produces a [`Report`] describing what each mode would do.
//! Actual formatting/linting behavior is added in later prompts; today the modes report
//! the resolved file set and an honest "no rules implemented yet" note.

mod install_worker;

use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};
use serde::Serialize;
use thiserror::Error;

use lean_fmt_diagnostics::{RuleInfo, RuleSelection, registry};
use lean_fmt_project::{FormatterConfig, SourceFile};

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
}

/// The formatter subcommands.
#[derive(Debug, Subcommand)]
pub enum CliCommand {
    /// Report formatting/lint findings without modifying files.
    Check(CommonArgs),
    /// Format files, reporting what would change.
    Format(CommonArgs),
    /// Apply safe fixes to files.
    Fix(CommonArgs),
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
        CliCommand::Check(args) | CliCommand::Format(args) | CliCommand::Fix(args) | CliCommand::Diff(args) => {
            plan_files(command.mode(), args)
        }
        CliCommand::Rules { .. } | CliCommand::InstallWorker(_) => Err(Error::NotReportable),
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

fn plan_files(mode: &'static str, args: &CommonArgs) -> Result<Report> {
    let config = load_config(args)?;
    let selection = selection_for(args, &config);
    // Project-level active rule count: per-file ignores keyed by real prefixes do not
    // apply to the empty path, so this is the baseline the selection would use.
    let active = selection.active_rule_ids("").len();
    if args.paths.is_empty() {
        let workspace = lean_fmt_project::resolve(&args.root, args.module_root.as_deref(), &config)?;
        let note = mode_note(mode, workspace.source_files.len(), active);
        Ok(Report {
            mode,
            root: Some(workspace.root),
            files: workspace.source_files,
            note,
        })
    } else {
        let files = lean_fmt_project::resolve_files(&args.paths)?;
        let note = mode_note(mode, files.len(), active);
        Ok(Report {
            mode,
            root: None,
            files,
            note,
        })
    }
}

fn mode_note(mode: &str, count: usize, active_rules: usize) -> String {
    format!(
        "resolved {count} file(s); {active_rules} rule(s) active; {mode} found no changes (no rules implemented yet)"
    )
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
        CliCommand::Check(args) | CliCommand::Format(args) | CliCommand::Fix(args) | CliCommand::Diff(args) => {
            args.format
        }
        CliCommand::Rules { format } => *format,
        CliCommand::InstallWorker(_) => OutputFormat::Text,
    }
}

/// Parse arguments, run the planning phase, and print the report. Returns a process
/// exit code: success, or failure with the error written to stderr.
#[must_use]
pub fn run() -> std::process::ExitCode {
    let cli = Cli::parse();
    // install-worker is effectful (builds + installs + smoke-tests); it is dispatched
    // directly rather than through the pure plan/render report path.
    if let CliCommand::InstallWorker(args) = &cli.command {
        return install_worker::run(args);
    }
    let format = command_format(&cli.command);
    if let CliCommand::Rules { .. } = &cli.command {
        return match render_rules(&plan_rules(), format) {
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
    match plan(&cli.command).and_then(|report| render(&report, format)) {
        Ok(rendered) => {
            print!("{rendered}");
            std::process::ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("lean-fmt: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use std::fs;

    use tempfile::TempDir;

    use super::{CliCommand, CommonArgs, OutputFormat, plan, plan_rules, render, render_rules};

    fn common(root: &std::path::Path) -> CommonArgs {
        CommonArgs {
            paths: Vec::new(),
            root: root.to_path_buf(),
            module_root: None,
            config: None,
            format: OutputFormat::Text,
            select: Vec::new(),
            ignore: Vec::new(),
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
}
