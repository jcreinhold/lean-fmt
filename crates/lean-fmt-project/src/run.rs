//! Project-scale orchestration: drive [`analyze_file`] across a discovered workspace.
//!
//! This is the project layer on top of prompt 26's single-file engine. It takes the resolved
//! source files and runs each one through the *same* warm [`SourceParser`] session, in a
//! deterministic (path-sorted) order, collecting a [`FileReport`] per file. The design
//! mirrors `lean-dup`'s "one warm worker session per audited workspace serves every command":
//! [`FormatterWorker`](lean_fmt_worker::FormatterWorker) wraps a one-worker pool and its
//! parse/validate take `&mut self`, so analysis is **serialized** — which makes the output
//! order deterministic by construction, with no cross-file scheduling to reason about.
//!
//! Three properties are load-bearing and tested:
//!
//! - **Deterministic order** — files are sorted by path before processing, so two runs over
//!   the same workspace produce byte-identical output.
//! - **Partial-failure survival** — a per-file failure (an unreadable file, a worker
//!   transport error, a failed write) is captured as [`FileReport::Failed`] and the run
//!   continues; one bad file never aborts the whole project.
//! - **No hidden writes** — only [`RunMode::Fix`] writes, and only the formatted text
//!   [`analyze_file`] already validated through the safe-write gate.
//!
//! Rendering (text/JSON) and progress/statistics routing live in the CLI; this engine only
//! produces the structured result and never prints. Keeping progress out of the engine is
//! what lets the CLI keep JSON stdout clean (progress goes to stderr).

use std::path::{Path, PathBuf};

use lean_fmt_diagnostics::RuleSelection;

use crate::analyze::{AnalysisOutcome, FileAnalysis, SourceParser, analyze_file};
use crate::cache::{CacheKey, FormatCache, config_fingerprint, source_digest};
use crate::config::FormatterConfig;
use crate::validate::ValidationLevel;
use crate::workspace::SourceFile;

/// Which project mode a run performs. Only [`Fix`](RunMode::Fix) writes to disk; the analysis
/// itself is identical across modes, so `Check`/`Diff` differ only in rendering (CLI-side).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunMode {
    /// Report findings without modifying files.
    Check,
    /// Report the diff formatting would produce, without modifying files.
    Diff,
    /// Apply the formatted output back to each file.
    Fix,
}

/// The result of processing one file: either it was analyzed (possibly written), or it hit a
/// per-file infrastructure failure that did not stop the run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FileReport {
    /// The file was analyzed. `wrote` is true only in [`RunMode::Fix`] when formatted output
    /// was written back to disk.
    Analyzed {
        /// The single-file analysis (findings, formatted text, diff, cache provenance).
        analysis: FileAnalysis,
        /// Whether formatted output was written to disk (fix mode only).
        wrote: bool,
    },
    /// A per-file failure — the file could not be read, the worker failed, or the write
    /// failed. Captured, not propagated: the run continues with the next file.
    Failed {
        /// The file path the failure is attributed to.
        path: String,
        /// A human-readable failure message.
        message: String,
    },
}

impl FileReport {
    /// The path this report is about.
    #[must_use]
    pub fn path(&self) -> &str {
        match self {
            Self::Analyzed { analysis, .. } => &analysis.path,
            Self::Failed { path, .. } => path,
        }
    }
}

/// Aggregate counts across a whole [`ProjectRun`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RunSummary {
    /// Total files processed.
    pub total: usize,
    /// Files that were clean (analyzed, no formatting change).
    pub clean: usize,
    /// Files that would change (analyzed with formatted output) — or did change, in fix mode.
    pub changed: usize,
    /// Files that did not parse cleanly and so were reported, never formatted.
    pub broken: usize,
    /// Files that hit a per-file failure.
    pub failed: usize,
    /// Files whose analysis was served from the cache.
    pub from_cache: usize,
    /// Files written to disk (fix mode).
    pub wrote: usize,
}

/// The full result of a project run: the mode and one [`FileReport`] per file, in
/// deterministic (path-sorted) order.
#[derive(Clone, Debug)]
pub struct ProjectRun {
    /// The mode that produced this run.
    pub mode: RunMode,
    /// Per-file reports, in path-sorted order.
    pub reports: Vec<FileReport>,
}

impl ProjectRun {
    /// Aggregate the per-file reports into a [`RunSummary`].
    #[must_use]
    pub fn summary(&self) -> RunSummary {
        let mut summary = RunSummary {
            total: self.reports.len(),
            ..RunSummary::default()
        };
        for report in &self.reports {
            match report {
                FileReport::Failed { .. } => summary.failed = summary.failed.saturating_add(1),
                FileReport::Analyzed { analysis, wrote } => {
                    if *wrote {
                        summary.wrote = summary.wrote.saturating_add(1);
                    }
                    if analysis.from_cache {
                        summary.from_cache = summary.from_cache.saturating_add(1);
                    }
                    match &analysis.outcome {
                        AnalysisOutcome::Broken { .. } => summary.broken = summary.broken.saturating_add(1),
                        AnalysisOutcome::Analyzed { formatted, .. } => {
                            if formatted.is_some() {
                                summary.changed = summary.changed.saturating_add(1);
                            } else {
                                summary.clean = summary.clean.saturating_add(1);
                            }
                        }
                    }
                }
            }
        }
        summary
    }

    /// The process exit code for this run.
    ///
    /// `2` if any file failed (an infrastructure error). Otherwise, for check/diff, `1` when
    /// any file would change or is broken, else `0`; for fix, `1` only when a broken file
    /// could not be formatted (changes were written), else `0`.
    #[must_use]
    pub fn exit_code(&self) -> u8 {
        let summary = self.summary();
        if summary.failed > 0 {
            return 2;
        }
        match self.mode {
            RunMode::Check | RunMode::Diff => u8::from(summary.changed > 0 || summary.broken > 0),
            RunMode::Fix => u8::from(summary.broken > 0),
        }
    }
}

/// Builds the per-file [`CacheKey`] for a run.
///
/// The run-wide inputs (formatter version, config fingerprint, toolchain, runtime digest,
/// validation mode) are fixed once; only the source digest and the file's import set vary
/// per file.
#[derive(Clone, Debug)]
pub struct CacheKeyBuilder {
    formatter_version: String,
    config_fingerprint: String,
    toolchain_label: String,
    runtime_source_digest: String,
    validation_mode: String,
    superset_id: Option<String>,
}

impl CacheKeyBuilder {
    /// Build the run-wide key ingredients. `config` is fingerprinted to just its
    /// output-affecting fields; `level` fixes the validation mode; `superset_id` is `Some`
    /// only for a pinned run (see [`FormatterWorker::setup_pinned_env`]) and keys every file's
    /// result to that superset, so pinned and per-file results never satisfy each other.
    ///
    /// [`FormatterWorker::setup_pinned_env`]: lean_fmt_worker::FormatterWorker::setup_pinned_env
    #[must_use]
    pub fn new(
        config: &FormatterConfig,
        formatter_version: impl Into<String>,
        toolchain_label: impl Into<String>,
        runtime_source_digest: impl Into<String>,
        level: ValidationLevel,
        superset_id: Option<String>,
    ) -> Self {
        Self {
            formatter_version: formatter_version.into(),
            config_fingerprint: config_fingerprint(config),
            toolchain_label: toolchain_label.into(),
            runtime_source_digest: runtime_source_digest.into(),
            validation_mode: validation_mode_label(level).to_owned(),
            superset_id,
        }
    }

    /// The cache key for one file's `source`.
    #[must_use]
    pub fn key_for(&self, source: &str) -> CacheKey {
        CacheKey::new(
            self.formatter_version.as_str(),
            self.config_fingerprint.as_str(),
            self.toolchain_label.as_str(),
            source_digest(source),
            scan_imports(source),
            self.runtime_source_digest.as_str(),
            self.validation_mode.as_str(),
            self.superset_id.clone(),
        )
    }
}

/// The whole-project import superset: the sorted, de-duplicated union of every file's `import`
/// lines.
///
/// This is the raw list handed to [`FormatterWorker::setup_pinned_env`], which builds the
/// pinned environment once and reuses it across every file.
///
/// Reads each file in turn and unions its imports via the same cheap, worker-free
/// [`scan_imports`] used for the cache key, so it needs no Lean and never holds every source
/// in memory at once. An unreadable file is skipped (its imports simply do not join the union);
/// the pin probe then either resolves what was gathered or falls back to per-file, so a missed
/// file degrades gracefully rather than corrupting the run.
///
/// [`FormatterWorker::setup_pinned_env`]: lean_fmt_worker::FormatterWorker::setup_pinned_env
#[must_use]
pub fn superset_union(files: &[SourceFile]) -> Vec<String> {
    let mut union: Vec<String> = Vec::new();
    for file in files {
        if let Ok(source) = std::fs::read_to_string(&file.path) {
            union.extend(scan_imports(&source));
        }
    }
    union.sort();
    union.dedup();
    union
}

/// The stable label for a validation level, used in the cache key so a result cached under
/// one level never satisfies a request at another.
fn validation_mode_label(level: ValidationLevel) -> &'static str {
    match level {
        ValidationLevel::None => "None",
        ValidationLevel::Syntax => "Syntax",
        ValidationLevel::Elab => "Elab",
    }
}

/// A cheap, deterministic, worker-free scan of a file's header imports. Two callers rely on it:
/// the cache key (where it need only be a stable function of the source, since the source digest
/// already invalidates on any content change) and [`superset_union`] (where completeness
/// matters, because a missed import leaves the pinned superset without that module's notation and
/// makes the file parse differently — the divergence the pin is meant to avoid).
///
/// It therefore understands the Lean module system, not just the legacy `import Foo` form: the
/// header may open with a bare `module` line, and each import may carry visibility or meta
/// modifiers (`public import Foo`, `private import Foo`, `meta import Foo`) and an optional `all`
/// (`import all Foo`). Block comments (including nested ones and the `/-! -/` doc block) and `--`
/// line comments are skipped so prose that mentions "import" is never mistaken for one, and the
/// scan stops at the first command — imports are contiguous at the top of the file, so no later
/// line (a string literal, say) can masquerade as an import.
fn scan_imports(source: &str) -> Vec<String> {
    let mut imports = Vec::new();
    let mut comment_depth: usize = 0;
    for raw in source.lines() {
        let line = raw.trim();
        if comment_depth > 0 {
            comment_depth = adjust_comment_depth(line, comment_depth);
            continue;
        }
        if line.is_empty() || line.starts_with("--") || line == "module" {
            continue;
        }
        if line.starts_with("/-") {
            comment_depth = adjust_comment_depth(line, 0);
            continue;
        }
        match import_module_name(line) {
            Some(module) => imports.push(module),
            // The first non-blank, non-comment, non-import line ends the header.
            None => break,
        }
    }
    imports
}

/// Update the block-comment nesting depth across one line by netting `/-` opens against `-/`
/// closes. Ordering within the line is ignored (headers do not close and reopen on one line),
/// so this is a count, not a parse — enough to skip the license and doc blocks reliably.
fn adjust_comment_depth(line: &str, depth: usize) -> usize {
    let opens = line.matches("/-").count();
    let closes = line.matches("-/").count();
    depth.saturating_add(opens).saturating_sub(closes)
}

/// The module name of one header import line, or `None` if the line is not an import. Strips any
/// leading `public`/`private`/`meta` modifiers, the `import` keyword, and an optional `all`.
fn import_module_name(line: &str) -> Option<String> {
    let mut rest = line;
    while let Some(next) = ["public ", "private ", "meta "]
        .into_iter()
        .find_map(|m| rest.strip_prefix(m))
    {
        rest = next.trim_start();
    }
    let after = rest.strip_prefix("import ")?;
    let after = after.strip_prefix("all ").unwrap_or(after);
    after.split_whitespace().next().map(ToOwned::to_owned)
}

/// Drive [`analyze_file`] across `files` through one warm `parser`, in deterministic order.
///
/// Files are sorted by path first, then each is read, keyed, and analyzed. In
/// [`RunMode::Fix`], a file whose analysis produced formatted output is written back (the text
/// already passed the safe-write gate inside [`analyze_file`]). Any per-file failure — an
/// unreadable file, a worker transport error, or a failed write — becomes a
/// [`FileReport::Failed`] and the run continues. `progress` is called once per file *before*
/// it is processed (the CLI routes it to stderr so JSON stdout stays clean).
pub fn run_project<P: SourceParser>(
    parser: &mut P,
    mode: RunMode,
    files: &[SourceFile],
    selection: &RuleSelection,
    keys: &CacheKeyBuilder,
    level: ValidationLevel,
    search_path: &[PathBuf],
    cache: &FormatCache,
    mut progress: impl FnMut(&str),
) -> ProjectRun {
    let mut ordered: Vec<&SourceFile> = files.iter().collect();
    ordered.sort_by(|left, right| left.path.cmp(&right.path));
    let total = ordered.len();

    let mut reports = Vec::with_capacity(total);
    for (index, file) in ordered.iter().enumerate() {
        let path = file.path.display().to_string();
        let position = index.saturating_add(1);
        progress(&format!("[{position}/{total}] {path}"));

        let source = match std::fs::read_to_string(&file.path) {
            Ok(source) => source,
            Err(error) => {
                reports.push(FileReport::Failed {
                    path,
                    message: format!("could not read file: {error}"),
                });
                continue;
            }
        };

        let key = keys.key_for(&source);
        match analyze_file(parser, selection, &path, &source, level, search_path, cache, &key) {
            Ok(analysis) => {
                let wrote = if mode == RunMode::Fix {
                    match write_if_formatted(&file.path, &analysis) {
                        Ok(wrote) => wrote,
                        Err(message) => {
                            reports.push(FileReport::Failed { path, message });
                            continue;
                        }
                    }
                } else {
                    false
                };
                reports.push(FileReport::Analyzed { analysis, wrote });
            }
            Err(error) => {
                reports.push(FileReport::Failed {
                    path,
                    message: error.to_string(),
                });
            }
        }
    }

    ProjectRun { mode, reports }
}

/// Write the formatted output back to `path`, if the analysis produced any. Returns whether a
/// write happened. A broken file or a file with no formatting change is left untouched.
fn write_if_formatted(path: &Path, analysis: &FileAnalysis) -> Result<bool, String> {
    match &analysis.outcome {
        AnalysisOutcome::Analyzed {
            formatted: Some(text), ..
        } => {
            std::fs::write(path, text).map_err(|error| format!("could not write file: {error}"))?;
            Ok(true)
        }
        AnalysisOutcome::Analyzed { formatted: None, .. } | AnalysisOutcome::Broken { .. } => Ok(false),
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use std::collections::BTreeMap;
    use std::path::PathBuf;

    use lean_fmt_diagnostics::RuleSelection;
    use lean_fmt_edit::TextRange;
    use lean_fmt_worker::{
        ModuleHeader, ParseDiagnostic, ParseFileResponse, ParseStatus, SourceModel, SyntaxSummary, ValidateResponse,
        WorkerError,
    };
    use tempfile::TempDir;

    use super::{
        AnalysisOutcome, CacheKeyBuilder, FileReport, RunMode, SourceFile, SourceParser, run_project, superset_union,
    };
    use crate::cache::FormatCache;
    use crate::config::FormatterConfig;
    use crate::validate::ValidationLevel;

    fn empty_header() -> ModuleHeader {
        ModuleHeader {
            imports: Vec::new(),
            is_module: false,
            import_spans: Vec::new(),
        }
    }

    fn empty_summary() -> SyntaxSummary {
        SyntaxSummary {
            command_count: 0,
            command_kinds: Vec::new(),
            command_regions: Vec::new(),
            declaration_headers: Vec::new(),
            tactic_blocks: Vec::new(),
        }
    }

    /// A stub worker returning one fixed parse response for every file.
    struct StubWorker {
        response: ParseFileResponse,
    }

    impl StubWorker {
        fn clean() -> Self {
            Self {
                response: Self::ok(Vec::new()),
            }
        }

        fn dirty(trivia: Vec<TextRange>) -> Self {
            Self {
                response: Self::ok(trivia),
            }
        }

        fn ok(trivia: Vec<TextRange>) -> ParseFileResponse {
            ParseFileResponse {
                status: ParseStatus::Ok,
                diagnostics: Vec::new(),
                diagnostics_truncated: false,
                module_header: empty_header(),
                syntax_summary: empty_summary(),
                source_model: SourceModel {
                    trivia_runs: trivia,
                    docstrings: Vec::new(),
                },
                fell_back: false,
            }
        }

        fn broken() -> Self {
            Self {
                response: ParseFileResponse {
                    status: ParseStatus::Error,
                    diagnostics: vec![ParseDiagnostic {
                        severity: "error".to_owned(),
                        message: "unexpected token".to_owned(),
                        file: "<snapshot>".to_owned(),
                        line: 1,
                        column: 0,
                        end_line: None,
                        end_column: None,
                    }],
                    diagnostics_truncated: false,
                    module_header: empty_header(),
                    syntax_summary: empty_summary(),
                    source_model: SourceModel::default(),
                    fell_back: false,
                },
            }
        }
    }

    impl SourceParser for StubWorker {
        fn parse_source(
            &mut self,
            _file: &str,
            _source: &str,
            _search_path: &[PathBuf],
        ) -> Result<ParseFileResponse, WorkerError> {
            Ok(self.response.clone())
        }

        fn validate_source(
            &mut self,
            _file: &str,
            _source: &str,
            _search_path: &[PathBuf],
        ) -> Result<ValidateResponse, WorkerError> {
            Ok(ValidateResponse {
                valid: true,
                diagnostics: Vec::new(),
                diagnostics_truncated: false,
            })
        }
    }

    fn selection(rule: &str) -> RuleSelection {
        RuleSelection::new(
            vec![rule.to_owned()],
            Vec::new(),
            Vec::new(),
            Vec::new(),
            BTreeMap::new(),
        )
    }

    fn keys() -> CacheKeyBuilder {
        CacheKeyBuilder::new(
            &FormatterConfig::default(),
            "0.1.0",
            "tc",
            "rt",
            ValidationLevel::Syntax,
            None,
        )
    }

    fn source_file(dir: &std::path::Path, name: &str, contents: &str) -> SourceFile {
        let path = dir.join(name);
        std::fs::write(&path, contents).unwrap();
        SourceFile {
            module: name.trim_end_matches(".lean").to_owned(),
            path,
        }
    }

    fn run(worker: &mut StubWorker, mode: RunMode, files: &[SourceFile], cache: &FormatCache) -> super::ProjectRun {
        run_project(
            worker,
            mode,
            files,
            &selection("text/trailing-whitespace"),
            &keys(),
            ValidationLevel::Syntax,
            &[],
            cache,
            |_message| {},
        )
    }

    #[test]
    fn superset_union_covers_every_file_sorted_deduped_and_skips_unreadable() {
        let dir = TempDir::new().unwrap();
        let a = source_file(
            dir.path(),
            "A.lean",
            "import Init\nimport Mathlib.Data.Nat.Basic\ndef a := 1\n",
        );
        // A repeated import (across files) and a reordered pair: the union sorts and dedups.
        let b = source_file(
            dir.path(),
            "B.lean",
            "  import Mathlib.Data.Nat.Basic\nimport Algebra\ndef b := 1\n",
        );
        let missing = SourceFile {
            module: "Missing".to_owned(),
            path: dir.path().join("Missing.lean"),
        };

        let union = superset_union(&[a, b, missing]);
        assert_eq!(
            union,
            vec![
                "Algebra".to_owned(),
                "Init".to_owned(),
                "Mathlib.Data.Nat.Basic".to_owned(),
            ],
            "the union is sorted, de-duplicated, and unaffected by the unreadable file",
        );
    }

    #[test]
    fn scan_imports_handles_the_module_system_and_skips_comment_prose() {
        let source = "\
/-
Copyright (c) 2018. All rights reserved.
Authors: Someone
-/
module

public import Mathlib.Algebra.Algebra.Hom
private import Mathlib.Tactic.Common
public meta import Mathlib.Meta.Foo
import all Mathlib.Data.Set.Basic
import Init

/-!
# Title
Do not treat this public import Fake.Module as a real import.
-/

namespace Foo
public import ShouldNotAppear.AfterACommand
";
        assert_eq!(
            super::scan_imports(source),
            vec![
                "Mathlib.Algebra.Algebra.Hom".to_owned(),
                "Mathlib.Tactic.Common".to_owned(),
                "Mathlib.Meta.Foo".to_owned(),
                "Mathlib.Data.Set.Basic".to_owned(),
                "Init".to_owned(),
            ],
            "module-system modifiers and `import all` are recognized; the `module` line, the \
             license and doc blocks (prose mentioning import included), and anything after the \
             first command are all excluded",
        );
    }

    #[test]
    fn files_are_processed_in_deterministic_path_order() {
        let dir = TempDir::new().unwrap();
        let cache = FormatCache::disabled(dir.path().join("cache"));
        // Create files out of alphabetical order; the run must sort them.
        let c = source_file(dir.path(), "C.lean", "def c := 1\n");
        let a = source_file(dir.path(), "A.lean", "def a := 1\n");
        let b = source_file(dir.path(), "B.lean", "def b := 1\n");
        let mut worker = StubWorker::clean();

        let result = run(&mut worker, RunMode::Check, &[c, a, b], &cache);
        let paths: Vec<&str> = result.reports.iter().map(FileReport::path).collect();
        let mut sorted = paths.clone();
        sorted.sort_unstable();
        assert_eq!(paths, sorted, "reports are emitted in path-sorted order");
        assert_eq!(result.summary().total, 3);
        assert_eq!(result.summary().clean, 3);
        assert_eq!(result.exit_code(), 0, "all clean");
    }

    #[test]
    fn a_per_file_failure_does_not_abort_the_run() {
        let dir = TempDir::new().unwrap();
        let cache = FormatCache::disabled(dir.path().join("cache"));
        let present = source_file(dir.path(), "Present.lean", "def a := 1\n");
        // A file that does not exist on disk: reading it fails, but the run must continue.
        let missing = SourceFile {
            module: "Missing".to_owned(),
            path: dir.path().join("Missing.lean"),
        };
        let mut worker = StubWorker::clean();

        let result = run(&mut worker, RunMode::Check, &[present, missing], &cache);
        assert_eq!(result.reports.len(), 2, "both files reported; the run did not abort");
        let failures = result
            .reports
            .iter()
            .filter(|report| matches!(report, FileReport::Failed { .. }))
            .count();
        assert_eq!(failures, 1, "exactly the missing file failed");
        assert_eq!(result.summary().failed, 1);
        assert_eq!(result.exit_code(), 2, "a per-file failure is a nonzero (error) exit");
    }

    #[test]
    fn a_broken_file_is_reported_and_the_run_continues() {
        let dir = TempDir::new().unwrap();
        let cache = FormatCache::disabled(dir.path().join("cache"));
        let file = source_file(dir.path(), "Broken.lean", "def a := \n");
        let mut worker = StubWorker::broken();

        let result = run(&mut worker, RunMode::Check, &[file], &cache);
        assert_eq!(result.summary().broken, 1);
        assert_eq!(result.exit_code(), 1, "a broken file is a nonzero exit");
        assert!(matches!(
            result.reports[0],
            FileReport::Analyzed {
                analysis: super::FileAnalysis {
                    outcome: AnalysisOutcome::Broken { .. },
                    ..
                },
                ..
            }
        ));
    }

    #[test]
    fn fix_mode_writes_formatted_output_to_disk() {
        let dir = TempDir::new().unwrap();
        let cache = FormatCache::disabled(dir.path().join("cache"));
        // Trailing whitespace at bytes 10..12 lives in the trivia run 10..13.
        let file = source_file(dir.path(), "Dirty.lean", "def a := 1  \n");
        let path = file.path.clone();
        let mut worker = StubWorker::dirty(vec![TextRange::new(10, 13)]);

        let result = run(&mut worker, RunMode::Fix, &[file], &cache);
        assert_eq!(result.summary().wrote, 1, "the dirty file was written");
        assert!(matches!(result.reports[0], FileReport::Analyzed { wrote: true, .. }));
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert_eq!(on_disk, "def a := 1\n", "the trailing spaces were stripped on disk");
        assert_eq!(result.exit_code(), 0, "fix succeeded with nothing broken");
    }

    #[test]
    fn check_mode_reports_changes_without_writing() {
        let dir = TempDir::new().unwrap();
        let cache = FormatCache::disabled(dir.path().join("cache"));
        let file = source_file(dir.path(), "Dirty.lean", "def a := 1  \n");
        let path = file.path.clone();
        let mut worker = StubWorker::dirty(vec![TextRange::new(10, 13)]);

        let result = run(&mut worker, RunMode::Check, &[file], &cache);
        assert_eq!(result.summary().changed, 1, "the file would change");
        assert_eq!(result.summary().wrote, 0, "check never writes");
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert_eq!(on_disk, "def a := 1  \n", "the file on disk is untouched by check");
        assert_eq!(result.exit_code(), 1, "pending changes are a nonzero exit");
    }
}
