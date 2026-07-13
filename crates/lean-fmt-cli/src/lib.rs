//! `lean-fmt` command-line surface and dispatch.
//!
//! This crate is the Lean-free parent: it parses arguments, discovers the Lake
//! workspace and config, and produces a [`Report`] describing what each mode would do.
//! Actual formatting/linting behavior is added in later prompts; today the modes report
//! the resolved file set and an honest "no rules implemented yet" note.

use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};
use serde::Serialize;
use thiserror::Error;

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
pub fn plan(command: &CliCommand) -> Result<Report> {
    match command {
        CliCommand::Rules { .. } => Ok(Report {
            mode: command.mode(),
            root: None,
            files: Vec::new(),
            note: "no rules registered yet (rule registry lands in a later prompt)".to_owned(),
        }),
        CliCommand::Check(args) | CliCommand::Format(args) | CliCommand::Fix(args) | CliCommand::Diff(args) => {
            plan_files(command.mode(), args)
        }
    }
}

fn plan_files(mode: &'static str, args: &CommonArgs) -> Result<Report> {
    if args.paths.is_empty() {
        let config = match &args.config {
            Some(path) => FormatterConfig::load_from(path)?,
            None => FormatterConfig::discover(&args.root)?,
        };
        let workspace = lean_fmt_project::resolve(&args.root, args.module_root.as_deref(), &config)?;
        let note = mode_note(mode, workspace.source_files.len());
        Ok(Report {
            mode,
            root: Some(workspace.root),
            files: workspace.source_files,
            note,
        })
    } else {
        let files = lean_fmt_project::resolve_files(&args.paths)?;
        let note = mode_note(mode, files.len());
        Ok(Report {
            mode,
            root: None,
            files,
            note,
        })
    }
}

fn mode_note(mode: &str, count: usize) -> String {
    format!("resolved {count} file(s); {mode} found no changes (no rules implemented yet)")
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

/// The output format selected by a command.
#[must_use]
pub fn command_format(command: &CliCommand) -> OutputFormat {
    match command {
        CliCommand::Check(args) | CliCommand::Format(args) | CliCommand::Fix(args) | CliCommand::Diff(args) => {
            args.format
        }
        CliCommand::Rules { format } => *format,
    }
}

/// Parse arguments, run the planning phase, and print the report. Returns a process
/// exit code: success, or failure with the error written to stderr.
#[must_use]
pub fn run() -> std::process::ExitCode {
    let cli = Cli::parse();
    let format = command_format(&cli.command);
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

    use super::{CliCommand, CommonArgs, OutputFormat, plan, render};

    fn common(root: &std::path::Path) -> CommonArgs {
        CommonArgs {
            paths: Vec::new(),
            root: root.to_path_buf(),
            module_root: None,
            config: None,
            format: OutputFormat::Text,
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
    fn rules_mode_lists_no_rules_yet() {
        let report = plan(&CliCommand::Rules {
            format: OutputFormat::Text,
        })
        .unwrap();
        assert_eq!(report.mode, "rules");
        assert!(report.files.is_empty());
        assert!(report.note.contains("no rules"));
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
